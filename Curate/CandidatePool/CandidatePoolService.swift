//
//  CandidatePoolService.swift
//  Curate
//
//  Main orchestrator for the hybrid candidate pool system.
//  Coordinates search plan generation, pool building, and recommendations.
//

import Foundation

// MARK: - Protocol

protocol CandidatePoolServiceProtocol {
    /// Get or create a candidate pool for the given prompt
    func getPool(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool

    /// Get recommended tracks from a pool
    func getRecommendedTracks(
        pool: CandidatePool,
        userId: UUID,
        stationId: UUID,
        policy: StationPolicy,
        count: Int
    ) async throws -> [PoolTrack]

    /// Trigger pool refresh if needed
    func refreshPoolIfNeeded(pool: CandidatePool) async throws

    /// Record track play
    func recordPlay(
        track: PoolTrack,
        userId: UUID,
        stationId: UUID
    ) async throws

    /// Record track skip
    func recordSkip(
        track: PoolTrack,
        userId: UUID,
        stationId: UUID,
        policy: StationPolicy
    ) async throws

    /// Convert pool tracks to provider tracks for playback
    func resolveProviderTracks(
        poolTracks: [PoolTrack]
    ) async throws -> [ProviderTrack]
}

// MARK: - Errors

enum CandidatePoolError: LocalizedError {
    case poolNotFound
    case poolExpired
    case poolTooSmall(available: Int, required: Int)
    case apiFailure(Error)
    case refreshInProgress
    case noTracksAvailable
    case providerNotAvailable

    var errorDescription: String? {
        switch self {
        case .poolNotFound:
            return "Candidate pool not found"
        case .poolExpired:
            return "Candidate pool has expired"
        case .poolTooSmall(let available, let required):
            return "Pool too small: \(available) tracks available, \(required) required"
        case .apiFailure(let error):
            return "API failure: \(error.localizedDescription)"
        case .refreshInProgress:
            return "Pool refresh already in progress"
        case .noTracksAvailable:
            return "No tracks available for this station"
        case .providerNotAvailable:
            return "Music provider not available"
        }
    }
}

// MARK: - Implementation

final class CandidatePoolService: CandidatePoolServiceProtocol {

    // MARK: - Dependencies

    private let searchPlanService: SearchPlanServiceProtocol
    private let poolRepository: CandidatePoolRepositoryProtocol
    private let overlayManager: UserOverlayManagerProtocol
    private let recommender: HybridRecommenderProtocol
    private let musicProvider: (any PlaylistDiscoveryProtocol)?
    private let artistSeedService: ArtistSeedServiceProtocol?
    private let feedbackRepository: FeedbackRepositoryProtocol?

    // MARK: - Configuration

    private let targetPoolSize = 500
    private let maxPoolSize = 1000
    private let minPoolSizeForPrimary = 100

    // MARK: - Initialization

    init(
        searchPlanService: SearchPlanServiceProtocol,
        poolRepository: CandidatePoolRepositoryProtocol,
        overlayManager: UserOverlayManagerProtocol,
        recommender: HybridRecommenderProtocol,
        musicProvider: (any PlaylistDiscoveryProtocol)?,
        artistSeedService: ArtistSeedServiceProtocol?,
        feedbackRepository: FeedbackRepositoryProtocol?
    ) {
        self.searchPlanService = searchPlanService
        self.poolRepository = poolRepository
        self.overlayManager = overlayManager
        self.recommender = recommender
        self.musicProvider = musicProvider
        self.artistSeedService = artistSeedService
        self.feedbackRepository = feedbackRepository
    }

    // MARK: - Get Pool

    func getPool(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool {
        // Step 1: Get search plan (handles intent canonicalization + caching)
        let searchPlan = try await searchPlanService.getSearchPlan(
            for: prompt,
            platform: platform
        )

        let intentHash = searchPlan.intentHash

        // Step 2: Check for existing pool
        let (existingTracks, metadata) = try await poolRepository.getPoolTracks(
            intentHash: intentHash,
            platform: platform,
            limit: maxPoolSize,
            excludeTrackIds: []
        )

        if let metadata = metadata, !existingTracks.isEmpty {
            // Pool exists - check if usable
            let pool = CandidatePool(
                canonicalIntentHash: intentHash,
                canonicalIntent: searchPlan.canonicalIntent,
                platform: platform,
                tracks: existingTracks,
                softTTLAt: metadata.isStale ? Date().addingTimeInterval(-1) : Date().addingTimeInterval(6 * 3600),
                hardTTLAt: Date().addingTimeInterval(24 * 3600),
                strategiesExhausted: metadata.strategiesExhausted
            )

            // Trigger background refresh if stale
            if metadata.needsRefresh {
                Task {
                    try? await refreshPoolIfNeeded(pool: pool)
                }
            }

            return pool
        }

        // Step 3: Build new pool
        return try await buildPool(searchPlan: searchPlan, platform: platform)
    }

    // MARK: - Build Pool

    private func buildPool(
        searchPlan: SearchPlan,
        platform: MusicPlatform
    ) async throws -> CandidatePool {
        guard let provider = musicProvider else {
            throw CandidatePoolError.providerNotAvailable
        }

        var allTracks: [PoolTrack] = []
        var strategiesUsed: [String] = []

        // Priority 1: Playlist searches
        for playlistSearch in searchPlan.sortedPlaylistSearches {
            guard allTracks.count < targetPoolSize else { break }

            do {
                let tracks = try await provider.buildPoolTracksFromPlaylists(
                    searchTerm: playlistSearch.term,
                    maxPlaylists: 5,
                    tracksPerPlaylist: 30
                )
                allTracks.append(contentsOf: tracks)
                strategiesUsed.append("playlist:\(playlistSearch.term)")
            } catch {
                // Continue with next strategy
                print("Warning: Playlist search failed for '\(playlistSearch.term)': \(error)")
            }
        }

        // Priority 2: Catalog searches (if needed)
        if allTracks.count < targetPoolSize {
            for catalogSearch in searchPlan.catalogSearches {
                guard allTracks.count < targetPoolSize else { break }

                do {
                    let tracks = try await provider.buildPoolTracksFromSearch(
                        term: catalogSearch.term,
                        genres: catalogSearch.genres,
                        limit: 50
                    )
                    allTracks.append(contentsOf: tracks)
                    strategiesUsed.append("search:\(catalogSearch.term)")
                } catch {
                    print("Warning: Catalog search failed for '\(catalogSearch.term)': \(error)")
                }
            }
        }

        // Priority 3: Artist seed fallback (if pool too small or low confidence)
        if allTracks.count < minPoolSizeForPrimary || searchPlan.shouldUseArtistSeedFallback {
            let artistTracks = try await fetchArtistSeedTracks(
                searchPlan: searchPlan,
                currentCount: allTracks.count
            )
            allTracks.append(contentsOf: artistTracks)
            if !artistTracks.isEmpty {
                strategiesUsed.append("artist_seed")
            }
        }

        // Deduplicate by ISRC
        allTracks = deduplicateByISRC(allTracks)

        // Cap at max
        if allTracks.count > maxPoolSize {
            allTracks = Array(allTracks.prefix(maxPoolSize))
        }

        // Create pool
        let pool = CandidatePool(
            canonicalIntentHash: searchPlan.intentHash,
            canonicalIntent: searchPlan.canonicalIntent,
            platform: platform,
            tracks: allTracks,
            strategiesUsed: strategiesUsed
        )

        // Persist to repository via Edge Function
        _ = try await poolRepository.refreshPool(
            intentHash: pool.canonicalIntentHash,
            platform: platform,
            newTracks: allTracks,
            refreshPercentage: 1.0  // Full pool creation
        )

        return pool
    }

    // MARK: - Artist Seed Fallback

    private func fetchArtistSeedTracks(
        searchPlan: SearchPlan,
        currentCount: Int
    ) async throws -> [PoolTrack] {
        // Calculate how many tracks to add from artist seeds
        let policy = searchPlan.effectivePolicy()
        let totalTarget = max(minPoolSizeForPrimary, currentCount + 100)
        let maxFromSeeds = Int(Double(totalTarget) * policy.maxArtistSeedContribution)
        let tracksToAdd = min(maxFromSeeds, targetPoolSize - currentCount)

        guard tracksToAdd > 0, let provider = musicProvider else {
            return []
        }

        // If we have artist seed config, use it; otherwise use defaults
        let seedConfig = searchPlan.artistSeedConfig ?? ArtistSeedFallbackConfig(
            seedCount: 5,
            similarityRatios: ArtistSeedFallbackConfig.SimilarityRatios(
                direct: 0.5,
                adjacent: 0.35,
                discovery: 0.15
            )
        )

        // Generate LLM station config for artist seeds
        let stationConfig = LLMStationConfig(
            name: searchPlan.canonicalIntent,
            description: searchPlan.moodCategories.joined(separator: ", "),
            originalPrompt: searchPlan.canonicalIntent,
            valenceRange: nil,
            energyRange: nil,
            danceabilityRange: nil,
            bpmRange: nil,
            acousticnessRange: nil,
            instrumentalnessRange: nil,
            valenceWeight: 1.0,
            energyWeight: 1.0,
            danceabilityWeight: 0.8,
            bpmWeight: 0.8,
            acousticnessWeight: 0.5,
            instrumentalnessWeight: 0.5,
            suggestedGenres: [],
            suggestedDecades: nil,
            moodKeywords: searchPlan.moodCategories,
            contextDescription: searchPlan.flavorTags.joined(separator: ", ")
        )

        // Use existing artist seed service if available
        if let artistSeedService = artistSeedService {
            do {
                // Generate a mock user ID for global pool (not user-specific)
                let globalUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

                let tracks = try await artistSeedService.getRecommendedTracks(
                    config: stationConfig,
                    userId: globalUserId,
                    count: tracksToAdd,
                    preferences: .default
                )

                return tracks.map { track in
                    PoolTrack(
                        trackId: track.id,
                        artistId: track.artistId ?? "",
                        isrc: track.isrc,
                        source: .artistSeed,
                        sourceDetail: "artist_seed:fallback"
                    )
                }
            } catch {
                print("Warning: Artist seed fallback failed: \(error)")
            }
        }

        return []
    }

    // MARK: - Get Recommended Tracks

    func getRecommendedTracks(
        pool: CandidatePool,
        userId: UUID,
        stationId: UUID,
        policy: StationPolicy,
        count: Int
    ) async throws -> [PoolTrack] {
        // Get user overlay
        var overlay = try await overlayManager.getOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: pool.canonicalIntent,
            policy: policy
        )

        // Reset session if stale
        if overlay.isSessionStale() {
            overlayManager.resetSession(overlay: &overlay, policy: policy)
        }

        // Get disliked artists from feedback
        let dislikedArtistIds = await getDislikedArtistIds(userId: userId)

        // Select tracks using recommender
        let result = recommender.selectTracksWithResult(
            from: pool,
            userOverlay: overlay,
            policy: policy,
            dislikedArtistIds: dislikedArtistIds,
            count: count
        )

        // Check if we need more tracks
        if result.needsMoreTracks && pool.tracks.count < minPoolSizeForPrimary {
            // Trigger pool refresh
            Task {
                try? await refreshPoolIfNeeded(pool: pool)
            }
        }

        // Update pool track serve counts
        if !result.tracks.isEmpty {
            try? await poolRepository.recordTrackServed(
                poolId: pool.id,
                trackIds: result.tracks.map { $0.trackId }
            )
        }

        return result.tracks
    }

    // MARK: - Refresh Pool

    func refreshPoolIfNeeded(pool: CandidatePool) async throws {
        guard pool.needsRefresh else { return }
        guard let provider = musicProvider else { return }

        // Get search plan for refresh
        let searchPlan = try await searchPlanService.getSearchPlan(
            for: pool.canonicalIntent,
            platform: pool.platform
        )

        // Find unused strategies
        let usedStrategies = Set(pool.strategiesUsed)
        let exhaustedStrategies = Set(pool.strategiesExhausted)

        var newTracks: [PoolTrack] = []
        let refreshTarget = pool.tracks.count / 4  // 25%

        // Try playlist strategies not yet exhausted
        for playlistSearch in searchPlan.sortedPlaylistSearches {
            let strategyKey = "playlist:\(playlistSearch.term)"
            if exhaustedStrategies.contains(strategyKey) { continue }

            do {
                let tracks = try await provider.buildPoolTracksFromPlaylists(
                    searchTerm: playlistSearch.term,
                    maxPlaylists: 3,
                    tracksPerPlaylist: 15
                )
                newTracks.append(contentsOf: tracks)

                if newTracks.count >= refreshTarget { break }
            } catch {
                continue
            }
        }

        // Try catalog searches if needed
        if newTracks.count < refreshTarget {
            for catalogSearch in searchPlan.catalogSearches {
                let strategyKey = "search:\(catalogSearch.term)"
                if exhaustedStrategies.contains(strategyKey) { continue }

                do {
                    let tracks = try await provider.buildPoolTracksFromSearch(
                        term: catalogSearch.term,
                        genres: catalogSearch.genres,
                        limit: 30
                    )
                    newTracks.append(contentsOf: tracks)

                    if newTracks.count >= refreshTarget { break }
                } catch {
                    continue
                }
            }
        }

        // Deduplicate
        newTracks = deduplicateByISRC(newTracks)

        // Filter out tracks already in pool
        let existingTrackIds = Set(pool.tracks.map { $0.trackId })
        newTracks = newTracks.filter { !existingTrackIds.contains($0.trackId) }

        // Submit to Edge Function
        if !newTracks.isEmpty {
            _ = try await poolRepository.refreshPool(
                intentHash: pool.canonicalIntentHash,
                platform: pool.platform,
                newTracks: newTracks,
                refreshPercentage: 0.25
            )
        }
    }

    // MARK: - Record Feedback

    func recordPlay(
        track: PoolTrack,
        userId: UUID,
        stationId: UUID
    ) async throws {
        var overlay = try await overlayManager.getOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: "",  // Will be ignored if overlay exists
            policy: .default
        )

        try await overlayManager.recordPlay(track: track, overlay: &overlay)
    }

    func recordSkip(
        track: PoolTrack,
        userId: UUID,
        stationId: UUID,
        policy: StationPolicy
    ) async throws {
        var overlay = try await overlayManager.getOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: "",
            policy: policy
        )

        try await overlayManager.recordSkip(track: track, overlay: &overlay, policy: policy)
    }

    // MARK: - Resolve Provider Tracks

    func resolveProviderTracks(poolTracks: [PoolTrack]) async throws -> [ProviderTrack] {
        guard let provider = musicProvider else {
            throw CandidatePoolError.providerNotAvailable
        }

        let trackIds = poolTracks.map { $0.trackId }
        return try await provider.fetchTracks(byIds: trackIds)
    }

    // MARK: - Helpers

    private func deduplicateByISRC(_ tracks: [PoolTrack]) -> [PoolTrack] {
        var seen = Set<String>()
        var seenIds = Set<String>()
        var result: [PoolTrack] = []

        for track in tracks {
            // Dedupe by ISRC if available
            if let isrc = track.isrc {
                if seen.contains(isrc) { continue }
                seen.insert(isrc)
            }

            // Also dedupe by track ID
            if seenIds.contains(track.trackId) { continue }
            seenIds.insert(track.trackId)

            result.append(track)
        }

        return result
    }

    private func getDislikedArtistIds(userId: UUID) async -> Set<String> {
        guard let feedbackRepo = feedbackRepository else {
            return []
        }

        do {
            let scores = try await feedbackRepo.getArtistScores(userId: userId)
            return Set(scores.filter { $0.shouldAvoid }.map { $0.artistName.lowercased() })
        } catch {
            return []
        }
    }
}

// MARK: - Convenience Factory

extension CandidatePoolService {
    /// Create a service instance with Supabase client
    static func create(
        supabaseClient: SupabaseClient,
        musicProvider: (any PlaylistDiscoveryProtocol)?,
        artistSeedService: ArtistSeedServiceProtocol?,
        feedbackRepository: FeedbackRepositoryProtocol?
    ) -> CandidatePoolService {
        let searchPlanService = SearchPlanService(supabaseClient: supabaseClient)
        let poolRepository = CandidatePoolRepository(supabaseClient: supabaseClient)
        let overlayRepository = UserOverlayRepository(supabaseClient: supabaseClient)
        let overlayManager = UserOverlayManager(repository: overlayRepository)
        let recommender = HybridRecommender()

        return CandidatePoolService(
            searchPlanService: searchPlanService,
            poolRepository: poolRepository,
            overlayManager: overlayManager,
            recommender: recommender,
            musicProvider: musicProvider,
            artistSeedService: artistSeedService,
            feedbackRepository: feedbackRepository
        )
    }
}

// MARK: - Mock Implementation

final class MockCandidatePoolService: CandidatePoolServiceProtocol {

    var mockPool: CandidatePool?
    var mockTracks: [PoolTrack] = []
    var getPoolCallCount = 0
    var getRecommendedTracksCallCount = 0

    func getPool(for prompt: String, platform: MusicPlatform) async throws -> CandidatePool {
        getPoolCallCount += 1

        if let mock = mockPool {
            return mock
        }

        return CandidatePool(
            canonicalIntentHash: prompt.sha256Hash,
            canonicalIntent: "mock-\(prompt)",
            platform: platform,
            tracks: mockTracks
        )
    }

    func getRecommendedTracks(
        pool: CandidatePool,
        userId: UUID,
        stationId: UUID,
        policy: StationPolicy,
        count: Int
    ) async throws -> [PoolTrack] {
        getRecommendedTracksCallCount += 1
        return Array(pool.tracks.prefix(count))
    }

    func refreshPoolIfNeeded(pool: CandidatePool) async throws {
        // No-op
    }

    func recordPlay(track: PoolTrack, userId: UUID, stationId: UUID) async throws {
        // No-op
    }

    func recordSkip(track: PoolTrack, userId: UUID, stationId: UUID, policy: StationPolicy) async throws {
        // No-op
    }

    func resolveProviderTracks(poolTracks: [PoolTrack]) async throws -> [ProviderTrack] {
        return []
    }
}

// MARK: - Supabase Import

import Supabase
