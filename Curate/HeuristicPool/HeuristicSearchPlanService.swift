//
//  HeuristicSearchPlanService.swift
//  Curate
//
//  Search plan service that uses on-device heuristic parsing
//  instead of LLM calls. Conforms to SearchPlanServiceProtocol
//  for compatibility with existing pool building infrastructure.
//

import Foundation

// MARK: - Implementation

/// Heuristic-based search plan service using on-device parsing
final class HeuristicSearchPlanService: SearchPlanServiceProtocol {

    // MARK: - Dependencies

    private let vibeParser: VibeParserProtocol
    private let searchExpander: SearchExpanderProtocol

    // MARK: - Initialization

    init(
        vibeParser: VibeParserProtocol = RuleBasedVibeParser(),
        searchExpander: SearchExpanderProtocol = SearchExpander()
    ) {
        self.vibeParser = vibeParser
        self.searchExpander = searchExpander
    }

    // MARK: - SearchPlanServiceProtocol

    func getSearchPlan(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> SearchPlan {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPrompt.isEmpty else {
            throw SearchPlanError.emptyPrompt
        }

        // Load user's genre preferences
        let genres = loadGenrePreferences()

        print("🧠 HeuristicSearchPlanService: Parsing \"\(trimmedPrompt)\" with genres: \(genres)")

        // 1. Parse the vibe (on-device, ~1-5ms)
        let parsedVibe = vibeParser.parse(input: trimmedPrompt)

        // 2. Expand to search queries
        let queries = searchExpander.expand(vibe: parsedVibe, genres: genres)

        // 3. Convert to SearchPlan format
        let searchPlan = buildSearchPlan(
            from: parsedVibe,
            queries: queries,
            platform: platform
        )

        print("✅ HeuristicSearchPlanService: Generated plan with " +
              "\(searchPlan.playlistSearches.count) playlist searches, " +
              "confidence: \(String(format: "%.2f", searchPlan.intentConfidence))")

        return searchPlan
    }

    // MARK: - Private Helpers

    /// Load genre preferences from UserDefaults
    private func loadGenrePreferences() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "selectedGenres"),
              let genres = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return genres
    }

    /// Build a SearchPlan from parsed components
    private func buildSearchPlan(
        from vibe: ParsedVibe,
        queries: [HeuristicSearchQuery],
        platform: MusicPlatform
    ) -> SearchPlan {
        // Convert queries to PlaylistSearch
        let playlistSearches = queries.map { $0.toPlaylistSearch() }

        // Build catalog searches as fallback (using genre-free queries)
        let catalogSearches = queries
            .filter { !$0.hasGenre }
            .prefix(3)
            .map { CatalogSearch(term: $0.term, genres: nil) }

        // Determine station policy based on parse confidence
        let stationPolicy = buildStationPolicy(confidence: vibe.confidence)

        return SearchPlan(
            canonicalIntent: vibe.canonicalIntent,
            moodCategories: vibe.moods.map { $0.rawValue },
            flavorTags: buildFlavorTags(from: vibe),
            intentConfidence: Double(vibe.confidence),
            playlistSearches: playlistSearches,
            catalogSearches: Array(catalogSearches),
            artistSeedConfig: vibe.needsFallback ? buildArtistSeedFallback() : nil,
            stationPolicy: stationPolicy,
            isCached: false
        )
    }

    /// Build flavor tags from parsed vibe
    private func buildFlavorTags(from vibe: ParsedVibe) -> [String] {
        var tags: [String] = []

        if let activity = vibe.activity {
            tags.append(activity.rawValue)
        }

        if let time = vibe.timeContext {
            tags.append(time.rawValue)
        }

        return tags
    }

    /// Build station policy based on confidence
    private func buildStationPolicy(confidence: Float) -> SuggestedStationPolicy {
        // Higher confidence = more playlist-focused
        // Lower confidence = more artist seed fallback
        let playlistRatio: Double
        let artistSeedRatio: Double

        if confidence > 0.7 {
            playlistRatio = 0.75
            artistSeedRatio = 0.05
        } else if confidence > 0.4 {
            playlistRatio = 0.60
            artistSeedRatio = 0.20
        } else {
            playlistRatio = 0.40
            artistSeedRatio = 0.40
        }

        return SuggestedStationPolicy(
            playlistSourceRatio: playlistRatio,
            searchSourceRatio: 1.0 - playlistRatio - artistSeedRatio,
            artistSeedSourceRatio: artistSeedRatio,
            explorationWeight: 0.25,
            artistRepeatWindow: 10
        )
    }

    /// Build artist seed fallback config for low-confidence parses
    private func buildArtistSeedFallback() -> ArtistSeedFallbackConfig {
        ArtistSeedFallbackConfig(
            seedCount: 5,
            similarityRatios: ArtistSeedFallbackConfig.SimilarityRatios(
                direct: 0.5,
                adjacent: 0.35,
                discovery: 0.15
            )
        )
    }
}

// MARK: - Mock Implementation for Testing

final class MockHeuristicSearchPlanService: SearchPlanServiceProtocol {
    var mockPlan: SearchPlan?
    var getSearchPlanCallCount = 0
    var lastPrompt: String?
    var lastPlatform: MusicPlatform?
    var shouldFail = false
    var failureError: Error = SearchPlanError.generationFailed("Mock failure")

    func getSearchPlan(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> SearchPlan {
        getSearchPlanCallCount += 1
        lastPrompt = prompt
        lastPlatform = platform

        if shouldFail {
            throw failureError
        }

        if let mock = mockPlan {
            return mock
        }

        // Return a default mock
        return SearchPlan(
            canonicalIntent: "mock-\(prompt.prefix(10))",
            moodCategories: ["chill"],
            flavorTags: [],
            intentConfidence: 0.7,
            playlistSearches: [
                PlaylistSearch(term: prompt, priority: 1)
            ],
            catalogSearches: [],
            artistSeedConfig: nil,
            stationPolicy: SuggestedStationPolicy(
                playlistSourceRatio: 0.7,
                searchSourceRatio: 0.2,
                artistSeedSourceRatio: 0.1,
                explorationWeight: 0.25,
                artistRepeatWindow: 10
            ),
            isCached: false
        )
    }
}
