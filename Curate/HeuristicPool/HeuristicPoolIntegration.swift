//
//  HeuristicPoolIntegration.swift
//  Curate
//
//  Integration layer between the heuristic pool system
//  and the existing LLMStationViewModel.
//
//  Key differences from HybridPoolIntegration:
//  1. Uses on-device VibeParser instead of LLM Edge Function
//  2. Scores playlists using PlaylistMoodMatcher
//  3. Genre preferences are first-class citizens
//

import Foundation
import Supabase

// MARK: - Heuristic Pool Integration Service

/// Recommendation service using on-device heuristic parsing
@MainActor
final class HeuristicPoolIntegrationService {

    // MARK: - Dependencies

    private let vibeParser: VibeParserProtocol
    private let searchExpander: SearchExpanderProtocol
    private let playlistMatcher: PlaylistMoodMatcherProtocol
    private let musicProvider: (any PlaylistDiscoveryProtocol)?
    private let recommender: HybridRecommenderProtocol
    private let artistSeedService: ArtistSeedServiceProtocol?

    // MARK: - State

    private var currentVibe: ParsedVibe?
    private var currentPool: CandidatePool?
    private var currentOverlay: UserStationOverlay?

    // MARK: - Configuration

    private let maxPlaylistsPerQuery = 8
    private let tracksPerPlaylist = 25
    private let maxTotalPlaylists = 15
    private let targetPoolSize = 400

    // MARK: - Initialization

    init(
        vibeParser: VibeParserProtocol = RuleBasedVibeParser(),
        searchExpander: SearchExpanderProtocol = SearchExpander(),
        playlistMatcher: PlaylistMoodMatcherProtocol = PlaylistMoodMatcher(),
        musicProvider: (any PlaylistDiscoveryProtocol)?,
        recommender: HybridRecommenderProtocol = HybridRecommender(),
        artistSeedService: ArtistSeedServiceProtocol?
    ) {
        self.vibeParser = vibeParser
        self.searchExpander = searchExpander
        self.playlistMatcher = playlistMatcher
        self.musicProvider = musicProvider
        self.recommender = recommender
        self.artistSeedService = artistSeedService
    }

    /// Convenience initializer
    convenience init(
        musicProvider: (any PlaylistDiscoveryProtocol)?,
        artistSeedService: ArtistSeedServiceProtocol?
    ) {
        self.init(
            vibeParser: RuleBasedVibeParser(),
            searchExpander: SearchExpander(),
            playlistMatcher: PlaylistMoodMatcher(),
            musicProvider: musicProvider,
            recommender: HybridRecommender(),
            artistSeedService: artistSeedService
        )
    }

    // MARK: - Get Recommended Tracks

    /// Get recommended tracks for a station prompt using heuristic parsing
    func getRecommendedTracks(
        prompt: String,
        config: LLMStationConfig?,
        userId: UUID,
        stationId: UUID,
        count: Int
    ) async throws -> [ProviderTrack] {
        guard let provider = musicProvider else {
            throw CandidatePoolError.providerNotAvailable
        }

        // Load user preferences
        let genres = loadGenrePreferences()
        let preferences = UserPreferences.loadFromStorage()

        print("🧠 HeuristicPool: Processing \"\(prompt)\" with genres: \(genres)")

        // 1. Parse the vibe (on-device)
        let vibe = vibeParser.parse(input: prompt)
        currentVibe = vibe

        // 2. Check confidence - fall back to artist seeds if too low
        if vibe.needsFallback {
            print("⚠️ HeuristicPool: Low confidence (\(vibe.confidence)), falling back to artist seeds")
            return try await fallbackToArtistSeeds(
                config: config,
                userId: userId,
                count: count,
                preferences: preferences
            )
        }

        // 3. Expand vibe to search queries
        let queries = searchExpander.expand(vibe: vibe, genres: genres)

        // 4. Execute playlist searches and score results
        let scoredPlaylists = try await searchAndScorePlaylists(
            queries: queries,
            vibe: vibe,
            genres: genres,
            provider: provider
        )

        // 5. Build pool from top playlists
        let poolTracks = try await buildPoolFromPlaylists(
            scoredPlaylists: scoredPlaylists,
            provider: provider
        )

        guard !poolTracks.isEmpty else {
            print("⚠️ HeuristicPool: No tracks found, falling back to artist seeds")
            return try await fallbackToArtistSeeds(
                config: config,
                userId: userId,
                count: count,
                preferences: preferences
            )
        }

        // 6. Create candidate pool
        let pool = CandidatePool(
            canonicalIntentHash: vibe.intentHash,
            canonicalIntent: vibe.canonicalIntent,
            platform: .appleMusic,
            tracks: poolTracks,
            strategiesUsed: ["heuristic_playlist_search"]
        )
        currentPool = pool

        print("🏊 HeuristicPool: Built pool with \(pool.tracks.count) tracks")

        // 7. Create or load user overlay
        let overlay = getOrCreateOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: vibe.canonicalIntent
        )

        // 8. Select tracks using HybridRecommender
        let policy = StationPolicy.default
        let selectedTracks = recommender.selectTracks(
            from: pool,
            userOverlay: overlay,
            policy: policy,
            dislikedArtistIds: [],  // TODO: Load from feedback
            count: count
        )

        // 9. Resolve to ProviderTracks
        let providerTracks = try await resolveProviderTracks(
            poolTracks: selectedTracks,
            provider: provider
        )

        print("✅ HeuristicPool: Returning \(providerTracks.count) tracks")

        return providerTracks
    }

    // MARK: - Playlist Search and Scoring

    /// Execute searches and score resulting playlists
    private func searchAndScorePlaylists(
        queries: [HeuristicSearchQuery],
        vibe: ParsedVibe,
        genres: [String],
        provider: any PlaylistDiscoveryProtocol
    ) async throws -> [ScoredPlaylist] {
        var allScoredPlaylists: [ScoredPlaylist] = []
        var seenPlaylistIds = Set<String>()

        for query in queries.prefix(6) {  // Limit to top 6 queries
            do {
                let playlists = try await provider.searchPlaylists(
                    term: query.term,
                    limit: maxPlaylistsPerQuery
                )

                // Score each playlist
                for playlist in playlists {
                    // Skip duplicates
                    guard !seenPlaylistIds.contains(playlist.id) else { continue }
                    seenPlaylistIds.insert(playlist.id)

                    let scored = playlistMatcher.score(
                        playlist: playlist,
                        against: vibe,
                        genres: genres
                    )
                    allScoredPlaylists.append(scored)
                }

                // Rate limiting
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            } catch {
                print("⚠️ HeuristicPool: Query '\(query.term)' failed: \(error)")
                continue
            }
        }

        // Sort by score and return top playlists
        let sorted = allScoredPlaylists.sorted { $0.totalScore > $1.totalScore }

        print("🎯 HeuristicPool: Scored \(sorted.count) playlists")
        for playlist in sorted.prefix(5) {
            print("   \(playlist.debugDescription)")
        }

        return Array(sorted.prefix(maxTotalPlaylists))
    }

    // MARK: - Pool Building

    /// Build pool tracks from scored playlists
    private func buildPoolFromPlaylists(
        scoredPlaylists: [ScoredPlaylist],
        provider: any PlaylistDiscoveryProtocol
    ) async throws -> [PoolTrack] {
        var allTracks: [PoolTrack] = []
        var seenISRCs = Set<String>()
        var seenTrackIds = Set<String>()

        for scored in scoredPlaylists {
            guard allTracks.count < targetPoolSize else { break }

            do {
                let tracks = try await provider.getPlaylistTracks(
                    playlistId: scored.playlist.id,
                    limit: tracksPerPlaylist
                )

                for track in tracks {
                    // Deduplicate by ISRC
                    if let isrc = track.isrc {
                        guard !seenISRCs.contains(isrc) else { continue }
                        seenISRCs.insert(isrc)
                    }

                    // Deduplicate by track ID
                    guard !seenTrackIds.contains(track.id) else { continue }
                    seenTrackIds.insert(track.id)

                    let poolTrack = PoolTrack(
                        trackId: track.id,
                        artistId: track.artistId ?? track.artistName,
                        isrc: track.isrc,
                        source: .playlist,
                        sourceDetail: "heuristic:\(scored.playlist.name)"
                    )
                    allTracks.append(poolTrack)
                }

                // Rate limiting
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            } catch {
                print("⚠️ HeuristicPool: Failed to fetch tracks from '\(scored.playlist.name)': \(error)")
                continue
            }
        }

        return allTracks
    }

    // MARK: - Fallback

    /// Fall back to artist seed service when heuristic parsing fails
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

    // MARK: - User Overlay

    /// Get or create user overlay for personalization
    private func getOrCreateOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String
    ) -> UserStationOverlay {
        if let existing = currentOverlay,
           existing.userId == userId,
           existing.stationId == stationId {
            return existing
        }

        let overlay = UserStationOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: canonicalIntent
        )
        currentOverlay = overlay
        return overlay
    }

    // MARK: - Track Resolution

    /// Convert pool tracks to provider tracks
    private func resolveProviderTracks(
        poolTracks: [PoolTrack],
        provider: any PlaylistDiscoveryProtocol
    ) async throws -> [ProviderTrack] {
        let trackIds = poolTracks.map { $0.trackId }
        return try await provider.fetchTracks(byIds: trackIds)
    }

    // MARK: - Helpers

    /// Load genre preferences from UserDefaults
    private func loadGenrePreferences() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "selectedGenres"),
              let genres = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return genres
    }

    // MARK: - Feedback Recording

    /// Record track play
    func recordPlay(
        track: ProviderTrack,
        userId: UUID,
        stationId: UUID
    ) async {
        guard let pool = currentPool,
              let poolTrack = pool.tracks.first(where: { $0.trackId == track.id }),
              var overlay = currentOverlay else {
            return
        }

        recommender.recordPlay(track: poolTrack, overlay: &overlay)
        currentOverlay = overlay
    }

    /// Record track skip
    func recordSkip(
        track: ProviderTrack,
        userId: UUID,
        stationId: UUID
    ) async {
        guard let pool = currentPool,
              let poolTrack = pool.tracks.first(where: { $0.trackId == track.id }),
              var overlay = currentOverlay else {
            return
        }

        recommender.recordSkip(track: poolTrack, overlay: &overlay, policy: .default)
        currentOverlay = overlay
    }

    // MARK: - Pool Management

    /// Clear current pool (e.g., when station changes)
    func clearCurrentPool() {
        currentPool = nil
        currentOverlay = nil
        currentVibe = nil
    }

    /// Get pool status for debugging
    var poolStatus: String {
        guard let pool = currentPool else {
            return "No pool loaded"
        }

        return "Heuristic Pool: \(pool.canonicalIntent) (\(pool.tracks.count) tracks)"
    }

    /// Get debug info
    func debugInfo() -> [String: Any] {
        var info: [String: Any] = [
            "hasPool": currentPool != nil,
            "engineType": "heuristic"
        ]

        if let vibe = currentVibe {
            info["parsedVibe"] = [
                "moods": vibe.moods.map { $0.rawValue },
                "activity": vibe.activity?.rawValue as Any,
                "timeContext": vibe.timeContext?.rawValue as Any,
                "confidence": vibe.confidence
            ]
        }

        if let pool = currentPool {
            info["pool"] = [
                "intent": pool.canonicalIntent,
                "trackCount": pool.tracks.count
            ]

            // Source distribution
            let sources = Dictionary(grouping: pool.tracks, by: \.source)
            info["sourceDistribution"] = sources.mapValues { $0.count }
        }

        return info
    }
}
