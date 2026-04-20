//
//  HybridPoolIntegration.swift
//  Curate
//
//  Integration layer between the hybrid candidate pool system
//  and the existing LLMStationViewModel.
//
//  This provides a unified interface that:
//  1. Uses hybrid pools when available
//  2. Falls back to artist seeds when pools are insufficient
//  3. Converts PoolTracks to ProviderTracks for playback
//

import Foundation
import Supabase

// MARK: - Hybrid Pool Integration Service

/// Unified recommendation service that combines hybrid pools with artist seed fallback
@MainActor
final class HybridPoolIntegrationService {

    // MARK: - Dependencies

    private let candidatePoolService: CandidatePoolServiceProtocol
    private let artistSeedService: ArtistSeedServiceProtocol?
    private let musicProvider: MusicProviderProtocol?

    // MARK: - State

    private var currentPool: CandidatePool?
    private var currentOverlay: UserStationOverlay?
    private var currentPolicy: StationPolicy = .default

    // MARK: - Initialization

    init(
        candidatePoolService: CandidatePoolServiceProtocol,
        artistSeedService: ArtistSeedServiceProtocol?,
        musicProvider: MusicProviderProtocol?
    ) {
        self.candidatePoolService = candidatePoolService
        self.artistSeedService = artistSeedService
        self.musicProvider = musicProvider
    }

    /// Convenience initializer with Supabase client
    convenience init(
        supabaseClient: SupabaseClient,
        musicProvider: (any PlaylistDiscoveryProtocol)?,
        artistSeedService: ArtistSeedServiceProtocol?
    ) {
        let poolService = CandidatePoolService.create(
            supabaseClient: supabaseClient,
            musicProvider: musicProvider,
            artistSeedService: artistSeedService,
            feedbackRepository: nil  // TODO: Pass actual repository
        )

        self.init(
            candidatePoolService: poolService,
            artistSeedService: artistSeedService,
            musicProvider: musicProvider
        )
    }

    // MARK: - Get Recommended Tracks

    /// Get recommended tracks for a station prompt
    /// Uses hybrid pool system with artist seed fallback
    func getRecommendedTracks(
        prompt: String,
        config: LLMStationConfig?,
        userId: UUID,
        stationId: UUID,
        count: Int,
        preferences: UserPreferences
    ) async throws -> [ProviderTrack] {
        // Enhance prompt with user's preferred genres if any
        let enhancedPrompt: String
        if !preferences.preferredGenres.isEmpty {
            let genreList = preferences.preferredGenres.joined(separator: ", ")
            enhancedPrompt = "\(prompt) with focus on \(genreList) music"
            print("🏊 Enhanced prompt with user genre preferences: \(enhancedPrompt)")
        } else {
            enhancedPrompt = prompt
        }

        // Try hybrid pool first
        do {
            let pool = try await candidatePoolService.getPool(
                for: enhancedPrompt,
                platform: .appleMusic
            )

            currentPool = pool

            // Update policy from search plan
            let policy = currentPolicy

            // Get pool tracks
            let poolTracks = try await candidatePoolService.getRecommendedTracks(
                pool: pool,
                userId: userId,
                stationId: stationId,
                policy: policy,
                count: count
            )

            // Check if we have enough tracks
            if poolTracks.count >= count / 2 {
                // Resolve to provider tracks
                let providerTracks = try await candidatePoolService.resolveProviderTracks(
                    poolTracks: poolTracks
                )

                if providerTracks.count >= count / 2 {
                    return providerTracks
                }
            }

            // Fall through to artist seed fallback
        } catch {
            print("Hybrid pool failed, falling back to artist seeds: \(error)")
        }

        // Fallback to artist seeds
        return try await fallbackToArtistSeeds(
            config: config,
            userId: userId,
            count: count,
            preferences: preferences
        )
    }

    // MARK: - Fallback

    private func fallbackToArtistSeeds(
        config: LLMStationConfig?,
        userId: UUID,
        count: Int,
        preferences: UserPreferences
    ) async throws -> [ProviderTrack] {
        guard let artistService = artistSeedService,
              let config = config else {
            throw CandidatePoolError.providerNotAvailable
        }

        return try await artistService.getRecommendedTracks(
            config: config,
            userId: userId,
            count: count,
            preferences: preferences
        )
    }

    // MARK: - Feedback Recording

    /// Record track play (call when a track starts playing)
    func recordPlay(
        track: ProviderTrack,
        userId: UUID,
        stationId: UUID
    ) async {
        // Find matching pool track
        guard let pool = currentPool,
              let poolTrack = pool.tracks.first(where: { $0.trackId == track.id }) else {
            return
        }

        do {
            try await candidatePoolService.recordPlay(
                track: poolTrack,
                userId: userId,
                stationId: stationId
            )
        } catch {
            print("Failed to record play: \(error)")
        }
    }

    /// Record track skip (call when user skips a track)
    func recordSkip(
        track: ProviderTrack,
        userId: UUID,
        stationId: UUID
    ) async {
        guard let pool = currentPool,
              let poolTrack = pool.tracks.first(where: { $0.trackId == track.id }) else {
            return
        }

        do {
            try await candidatePoolService.recordSkip(
                track: poolTrack,
                userId: userId,
                stationId: stationId,
                policy: currentPolicy
            )
        } catch {
            print("Failed to record skip: \(error)")
        }
    }

    // MARK: - Pool Management

    /// Refresh the current pool if stale
    func refreshPoolIfNeeded() async {
        guard let pool = currentPool, pool.needsRefresh else { return }

        do {
            try await candidatePoolService.refreshPoolIfNeeded(pool: pool)
        } catch {
            print("Failed to refresh pool: \(error)")
        }
    }

    /// Clear the current pool (e.g., when station changes)
    func clearCurrentPool() {
        currentPool = nil
        currentOverlay = nil
    }

    /// Get pool status for debugging
    var poolStatus: String {
        guard let pool = currentPool else {
            return "No pool loaded"
        }

        let status = pool.isStale ? "stale" : "fresh"
        return "Pool: \(pool.canonicalIntent) (\(pool.tracks.count) tracks, \(status))"
    }
}

// MARK: - Provider Track Extension

extension ProviderTrack {
    /// Create from PoolTrack (requires fetching from provider)
    static func from(poolTrack: PoolTrack, provider: MusicProviderProtocol) async throws -> ProviderTrack? {
        let tracks = try await provider.fetchTracks(byIds: [poolTrack.trackId])
        return tracks.first
    }
}

// MARK: - LLMStationViewModel Extension

extension LLMStationViewModel {

    /// Use hybrid pool for recommendations (integration point)
    /// Call this instead of fetchArtistSeededSuggestions when using hybrid pools
    func fetchHybridPoolSuggestions(
        prompt: String,
        config: LLMStationConfig,
        userId: UUID,
        service: HybridPoolIntegrationService
    ) async throws {
        let preferences = UserPreferences.loadFromStorage()

        let tracks = try await service.getRecommendedTracks(
            prompt: prompt,
            config: config,
            userId: userId,
            stationId: station?.id ?? UUID(),
            count: 15,
            preferences: preferences
        )

        // Convert to queue items (same as artist-seeded flow)
        for track in tracks {
            if queue.contains(where: { $0.appleMusicId == track.id }) {
                continue
            }

            var suggestion = LLMSongSuggestion(
                title: track.title,
                artist: track.artistName,
                album: track.albumName,
                year: track.releaseDate.flatMap { Int($0.prefix(4)) },
                reason: "From hybrid pool recommendations",
                estimatedBpm: nil,
                estimatedEnergy: nil,
                estimatedValence: nil,
                estimatedDanceability: nil,
                estimatedAcousticness: nil,
                estimatedInstrumentalness: nil
            )
            suggestion.verificationStatus = .verified
            suggestion.appleMusicId = track.id
            suggestion.isrc = track.isrc
            suggestion.artworkURL = track.artworkURL?.absoluteString

            var queueItem = LLMQueueItem(suggestion: suggestion)
            queueItem.appleMusicId = track.id
            queueItem.isrc = track.isrc
            queueItem.artworkURL = track.artworkURL
            queueItem.status = LLMQueueItem.PlayStatus.queued
            queue.append(queueItem)
        }
    }
}

// MARK: - Feature Flag

/// Feature flag for hybrid pool system
enum HybridPoolFeatureFlag {

    /// Whether the hybrid pool system is enabled
    /// Set to true to use hybrid pools, false for legacy artist seeds
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "hybridPoolEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hybridPoolEnabled")
        }
    }

    /// Enable hybrid pools for testing
    static func enable() {
        isEnabled = true
    }

    /// Disable hybrid pools (use legacy artist seeds)
    static func disable() {
        isEnabled = false
    }
}

// MARK: - Debug Utilities

extension HybridPoolIntegrationService {

    /// Get detailed pool information for debugging
    func debugInfo() -> [String: Any] {
        var info: [String: Any] = [
            "hasPool": currentPool != nil,
            "policy": [
                "playlistRatio": currentPolicy.playlistSourceRatio,
                "searchRatio": currentPolicy.searchSourceRatio,
                "artistSeedRatio": currentPolicy.artistSeedSourceRatio,
                "explorationWeight": currentPolicy.baseExplorationWeight
            ]
        ]

        if let pool = currentPool {
            info["pool"] = [
                "intent": pool.canonicalIntent,
                "trackCount": pool.tracks.count,
                "isStale": pool.isStale,
                "isExpired": pool.isExpired,
                "needsRefresh": pool.needsRefresh,
                "strategiesUsed": pool.strategiesUsed
            ]

            // Source distribution
            let sources = Dictionary(grouping: pool.tracks, by: \.source)
            info["sourceDistribution"] = sources.mapValues { $0.count }
        }

        return info
    }
}
