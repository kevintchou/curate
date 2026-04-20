//
//  LLMStationService.swift
//  Curate
//
//  Protocol and mock implementation for LLM-based station operations.
//  Production implementation is in BackendStationService.swift (Supabase Edge Functions).
//

import Foundation

// MARK: - LLM Station Service Protocol
/// Protocol for LLM-based station operations
/// Allows for easy mocking in tests and potential provider swapping
protocol LLMStationServiceProtocol {
    /// Generate a station configuration from a natural language prompt
    func generateConfig(from prompt: String, tasteProfile: LLMTasteProfile?) async throws -> LLMStationConfig

    /// Get song suggestions for a station (legacy - prefer generateArtistSeeds)
    func suggestSongs(request: LLMSongRequest) async throws -> [LLMSongSuggestion]

    /// Analyze feedback and update taste profile
    func analyzeTaste(
        originalPrompt: String,
        currentProfile: LLMTasteProfile?,
        feedbackSummary: StationFeedbackSummary
    ) async throws -> LLMTasteProfile

    /// Generate artist seeds for a station (new artist-seeded approach)
    func generateArtistSeeds(
        config: LLMStationConfig,
        tasteSummary: String,
        avoidArtists: [String],
        count: Int,
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) async throws -> [ArtistSeed]
}

// MARK: - LLM Service Errors
enum LLMServiceError: LocalizedError {
    case notInitialized
    case invalidResponse
    case parsingFailed(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "LLM service is not initialized"
        case .invalidResponse:
            return "Received invalid response from LLM"
        case .parsingFailed(let details):
            return "Failed to parse LLM response: \(details)"
        case .apiError(let message):
            return "API error: \(message)"
        }
    }
}

// MARK: - Mock Service for Testing
#if DEBUG
final class MockLLMStationService: LLMStationServiceProtocol {
    func generateConfig(from prompt: String, tasteProfile: LLMTasteProfile?) async throws -> LLMStationConfig {
        // Simulate network delay
        try await Task.sleep(for: .seconds(1))

        return LLMStationConfig(
            name: "Sunset Vibes",
            description: "Relaxing tunes for your coastal drive",
            originalPrompt: prompt,
            valenceRange: FeatureRangeLLM(min: 0.4, max: 0.7),
            energyRange: FeatureRangeLLM(min: 0.3, max: 0.6),
            danceabilityRange: nil,
            bpmRange: FeatureRangeLLM(min: 0.2, max: 0.5),
            acousticnessRange: FeatureRangeLLM(min: 0.3, max: 0.8),
            instrumentalnessRange: nil,
            valenceWeight: 1.2,
            energyWeight: 1.0,
            danceabilityWeight: 0.6,
            bpmWeight: 0.8,
            acousticnessWeight: 1.0,
            instrumentalnessWeight: 0.4,
            suggestedGenres: ["Indie", "Soft Rock", "Dream Pop"],
            suggestedDecades: [2010, 2020],
            moodKeywords: ["relaxing", "dreamy", "coastal", "warm"],
            contextDescription: "A warm, golden-hour drive along the coast with the windows down"
        )
    }

    func suggestSongs(request: LLMSongRequest) async throws -> [LLMSongSuggestion] {
        try await Task.sleep(for: .seconds(1))

        return [
            LLMSongSuggestion(
                title: "Dreams",
                artist: "Fleetwood Mac",
                album: "Rumours",
                year: 1977,
                reason: "Classic sunset driving song with dreamy vibes",
                estimatedBpm: 120,
                estimatedEnergy: 0.5,
                estimatedValence: 0.6,
                estimatedDanceability: 0.6,
                estimatedAcousticness: 0.3,
                estimatedInstrumentalness: 0.0
            ),
            LLMSongSuggestion(
                title: "Sunset",
                artist: "The Midnight",
                album: "Days of Thunder",
                year: 2017,
                reason: "Synthwave perfection for coastal drives",
                estimatedBpm: 100,
                estimatedEnergy: 0.6,
                estimatedValence: 0.7,
                estimatedDanceability: 0.5,
                estimatedAcousticness: 0.1,
                estimatedInstrumentalness: 0.3
            )
        ]
    }

    func analyzeTaste(
        originalPrompt: String,
        currentProfile: LLMTasteProfile?,
        feedbackSummary: StationFeedbackSummary
    ) async throws -> LLMTasteProfile {
        try await Task.sleep(for: .seconds(1))

        return LLMTasteProfile(
            preferredGenres: ["Indie", "Soft Rock"],
            avoidedGenres: ["Heavy Metal"],
            preferredArtists: ["Fleetwood Mac"],
            avoidedArtists: [],
            preferredDecades: [1970, 1980, 2010],
            energyPreference: "medium",
            moodPreference: "happy",
            notablePatterns: ["Prefers melodic vocals", "Likes guitar-driven songs"],
            lastUpdatedAt: Date(),
            feedbackCountAtUpdate: feedbackSummary.totalLikes + feedbackSummary.totalDislikes
        )
    }

    func generateArtistSeeds(
        config: LLMStationConfig,
        tasteSummary: String,
        avoidArtists: [String],
        count: Int,
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) async throws -> [ArtistSeed] {
        try await Task.sleep(for: .seconds(1))

        // Vary output based on temperature for mock
        let tempLabel = temperature < 0.3 ? "conservative" : (temperature < 0.7 ? "balanced" : "adventurous")
        print("🎲 Mock generateArtistSeeds: temp=\(tempLabel), genres=\(preferredGenres)")

        return [
            ArtistSeed(
                name: "Fleetwood Mac",
                reason: "Classic soft rock with dreamy vocals",
                similarityType: .direct,
                expectedGenres: ["Soft Rock", "Classic Rock"]
            ),
            ArtistSeed(
                name: "The Midnight",
                reason: "Modern synthwave with nostalgic vibes",
                similarityType: .adjacent,
                expectedGenres: ["Synthwave", "Electronic"]
            ),
            ArtistSeed(
                name: "Tame Impala",
                reason: "Psychedelic rock with atmospheric production",
                similarityType: .discovery,
                expectedGenres: ["Psychedelic Rock", "Indie"]
            )
        ]
    }
}
#endif
