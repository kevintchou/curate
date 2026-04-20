//
//  SearchPlanService.swift
//  Curate
//
//  Service for generating and caching search plans via the LLM.
//  Handles intent canonicalization and search strategy generation.
//

import Foundation
import Supabase

// MARK: - Protocol

protocol SearchPlanServiceProtocol {
    /// Get a search plan for the given prompt and platform
    /// Handles caching and LLM generation
    func getSearchPlan(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> SearchPlan
}

// MARK: - Errors

enum SearchPlanError: LocalizedError {
    case emptyPrompt
    case generationFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "Prompt cannot be empty"
        case .generationFailed(let message):
            return "Failed to generate search plan: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Implementation

final class SearchPlanService: SearchPlanServiceProtocol {

    private let supabaseClient: SupabaseClient

    // MARK: - Initialization

    init(supabaseClient: SupabaseClient) {
        self.supabaseClient = supabaseClient
    }

    // MARK: - Get Search Plan

    func getSearchPlan(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> SearchPlan {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPrompt.isEmpty else {
            throw SearchPlanError.emptyPrompt
        }

        let request = GenerateSearchPlanRequest(
            prompt: trimmedPrompt,
            platform: platform
        )

        do {
            let response: GenerateSearchPlanResponse = try await supabaseClient.functions
                .invoke(
                    "generate-search-plan",
                    options: FunctionInvokeOptions(body: request)
                )

            return response.toSearchPlan()
        } catch let error as FunctionsError {
            throw SearchPlanError.generationFailed(error.localizedDescription)
        } catch {
            throw SearchPlanError.networkError(error)
        }
    }
}

// MARK: - Search Plan Extensions

extension SearchPlan {
    /// Get the effective station policy (LLM suggestions merged with defaults)
    func effectivePolicy(basePolicy: StationPolicy = .default) -> StationPolicy {
        basePolicy.merged(with: stationPolicy)
    }

    /// Generate the canonical intent hash for pool lookups
    var intentHash: String {
        canonicalIntent.sha256Hash
    }

    /// Get sorted playlist searches by priority
    var sortedPlaylistSearches: [PlaylistSearch] {
        playlistSearches.sorted { $0.priority < $1.priority }
    }
}

// MARK: - Mock Implementation for Testing

final class MockSearchPlanService: SearchPlanServiceProtocol {

    var mockSearchPlan: SearchPlan?
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

        if let mock = mockSearchPlan {
            return mock
        }

        // Return a default mock search plan
        return SearchPlan(
            canonicalIntent: "mock-intent-\(prompt.sha256Hash.prefix(8))",
            moodCategories: ["chill", "relaxed"],
            flavorTags: ["evening", "mellow"],
            intentConfidence: 0.85,
            playlistSearches: [
                PlaylistSearch(term: "chill vibes", priority: 1),
                PlaylistSearch(term: "relaxing music", priority: 2),
                PlaylistSearch(term: "evening mood", priority: 3)
            ],
            catalogSearches: [
                CatalogSearch(term: "chill acoustic", genres: ["acoustic", "indie"]),
                CatalogSearch(term: "relaxing instrumental", genres: nil)
            ],
            artistSeedConfig: nil,
            stationPolicy: SuggestedStationPolicy(
                playlistSourceRatio: 0.55,
                searchSourceRatio: 0.25,
                artistSeedSourceRatio: 0.20,
                explorationWeight: 0.3,
                artistRepeatWindow: 10
            ),
            isCached: false
        )
    }

    /// Create a mock search plan with low intent confidence (triggers artist seed fallback)
    static func lowConfidencePlan(for prompt: String) -> SearchPlan {
        SearchPlan(
            canonicalIntent: "ambiguous-\(prompt.sha256Hash.prefix(8))",
            moodCategories: ["varied"],
            flavorTags: [],
            intentConfidence: 0.3,
            playlistSearches: [
                PlaylistSearch(term: prompt, priority: 1)
            ],
            catalogSearches: [],
            artistSeedConfig: ArtistSeedFallbackConfig(
                seedCount: 5,
                similarityRatios: ArtistSeedFallbackConfig.SimilarityRatios(
                    direct: 0.5,
                    adjacent: 0.35,
                    discovery: 0.15
                )
            ),
            stationPolicy: SuggestedStationPolicy(
                playlistSourceRatio: 0.30,
                searchSourceRatio: 0.20,
                artistSeedSourceRatio: 0.50,
                explorationWeight: 0.4,
                artistRepeatWindow: 8
            ),
            isCached: false
        )
    }
}
