//
//  ToolCallingStationService.swift
//  Curate
//
//  Integrates the tool-calling orchestrator into the existing station system.
//  Provides the same output format (ProviderTrack array) so it plugs into
//  LLMStationViewModel's existing queue management.
//

import Foundation
import MusicKit

// MARK: - Tool-Calling Station Service

final class ToolCallingStationService {
    private let orchestrator: ToolCallingOrchestrator
    private let filterTool: FilterRecentlyPlayedTool

    /// Progress updates from the orchestrator
    var onProgress: ((String) -> Void)? {
        didSet { orchestrator.onProgress = onProgress }
    }

    init(
        feedbackRepository: FeedbackRepositoryProtocol? = nil,
        userId: UUID? = nil,
        llmBackend: ToolCallingLLMBackend = SupabaseToolCallingBackend(),
        config: OrchestratorConfig = OrchestratorConfig()
    ) {
        // Build the filter tool with session state
        let filterTool = FilterRecentlyPlayedTool(
            feedbackRepository: feedbackRepository,
            userId: userId
        )
        self.filterTool = filterTool

        let feedbackTool = SummarizeFeedbackTool(
            feedbackRepository: feedbackRepository,
            userId: userId
        )

        // Build registry with all tools
        let registry = MusicToolRegistry()

        // Low-level MusicKit tools (flat layer)
        registry.register([
            SearchCatalogTool(),
            GetArtistTopSongsTool(),
            GetSimilarArtistsTool(),
            GetPlaylistTracksTool(),
            GetRecommendationsTool(),
            GetHeavyRotationTool(),
            GetRecentlyPlayedTool(),
            GetGenreChartsTool(),
            GetRelatedAlbumsTool(),
            GetSongRadioSeedTool(),
        ])

        // Custom logic tools
        registry.register([
            filterTool,
            EnforceDiversityTool(),
            GenerateSearchQueriesTool(),
            ScoreTrackFitTool(),
            RankCandidatesTool(),
            feedbackTool,
            GetUserPreferencesTool(),
        ])

        // High-level approach tools (layered — LLM can call these for one-shot station building)
        registry.register([
            BuildArtistGraphTool(),
            BuildPlaylistMiningTool(),
            BuildSongSeededTool(),
            BuildPersonalizedTool(),
            BuildGenreChartTool(),
        ])

        // Build cache with per-tool TTLs
        let cache = ToolResultCache(defaultTTL: 300)
        cache.setTTL(86400, for: "get_artist_top_songs")    // 24h — top songs change slowly
        cache.setTTL(86400, for: "get_similar_artists")      // 24h — similarity graph is stable
        cache.setTTL(3600, for: "get_playlist_tracks")       // 1h — playlists update occasionally
        cache.setTTL(600, for: "search_catalog")             // 10min — searches are context-sensitive
        cache.setTTL(3600, for: "get_recommendations")       // 1h — personalization updates slowly
        cache.setTTL(3600, for: "get_heavy_rotation")        // 1h
        cache.setTTL(600, for: "get_recently_played")        // 10min — changes with each listen
        cache.setTTL(3600, for: "get_genre_charts")          // 1h — charts update daily
        cache.setTTL(86400, for: "get_related_albums")       // 24h — stable
        cache.setTTL(86400, for: "get_user_preferences")     // 24h — user changes rarely
        cache.setTTL(1800, for: "summarize_feedback")        // 30min
        // Approach tools: cache their full results
        cache.setTTL(1800, for: "build_artist_graph_station")    // 30min
        cache.setTTL(1800, for: "build_playlist_mining_station") // 30min
        cache.setTTL(1800, for: "build_song_seeded_station")     // 30min
        cache.setTTL(1800, for: "build_personalized_station")    // 30min
        cache.setTTL(1800, for: "build_genre_chart_station")     // 30min

        self.orchestrator = ToolCallingOrchestrator(
            registry: registry,
            cache: cache,
            llmBackend: llmBackend,
            config: config
        )
    }

    /// Build a station from a user prompt. Returns tracks ready for playback.
    func buildStation(
        prompt: String,
        preferences: UserPreferences? = nil
    ) async throws -> ToolCallingStationResult {
        let result = try await orchestrator.buildStation(
            prompt: prompt,
            userPreferences: preferences
        )

        // Resolve selected track IDs to full ProviderTrack objects
        let trackIds = result.tracks.map(\.id)
        let providerTracks = try await resolveToProviderTracks(
            selectedTracks: result.tracks,
            trackIds: trackIds
        )

        return ToolCallingStationResult(
            tracks: providerTracks,
            approachUsed: result.approachUsed,
            reasoning: result.reasoning,
            turnsUsed: result.turnsUsed
        )
    }

    /// Add an ISRC to session history (called when a track plays)
    func markPlayed(isrc: String) {
        filterTool.sessionHistory.insert(isrc)
    }

    /// Clear session history (called when starting a new station)
    func resetSession() {
        filterTool.sessionHistory.removeAll()
    }

    // MARK: - Track Resolution

    private func resolveToProviderTracks(
        selectedTracks: [SelectedTrack],
        trackIds: [String]
    ) async throws -> [ProviderTrack] {
        var resolved: [ProviderTrack] = []

        // Batch fetch by ID
        let batchSize = 25
        for batchStart in stride(from: 0, to: trackIds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, trackIds.count)
            let batch = Array(trackIds[batchStart..<batchEnd])

            for (index, id) in batch.enumerated() {
                let musicId = MusicItemID(rawValue: id)

                // Rate limit between requests
                if index > 0 {
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }

                do {
                    let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicId)
                    let response = try await request.response()

                    if let song = response.items.first {
                        resolved.append(ProviderTrack(
                            id: song.id.rawValue,
                            isrc: song.isrc,
                            title: song.title,
                            artistName: song.artistName,
                            artistId: song.artistName,
                            albumName: song.albumTitle,
                            durationMs: song.duration.map { Int($0 * 1000) },
                            releaseDate: song.releaseDate?.ISO8601Format(),
                            providerType: .appleMusic,
                            artworkURL: song.artwork?.url(width: 300, height: 300),
                            isExplicit: song.contentRating == .explicit
                        ))
                    }
                } catch {
                    // Skip tracks that fail to resolve — don't break the whole station
                    continue
                }
            }
        }

        return resolved
    }
}

// MARK: - Result Type

struct ToolCallingStationResult {
    let tracks: [ProviderTrack]
    let approachUsed: String
    let reasoning: String
    let turnsUsed: Int
}

