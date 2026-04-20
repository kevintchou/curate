//
//  BackendStationService.swift
//  Curate
//
//  LLM Station Service that calls Supabase Edge Functions instead of
//  Firebase AI directly. This moves LLM calls to the backend for:
//  - Security (API keys not in client)
//  - Prompt protection (prompts not exposed)
//  - Easy provider switching without app updates
//

import Foundation
import Supabase

// MARK: - Backend Service Errors

enum BackendServiceError: LocalizedError {
    case invalidRequest(String)
    case unauthorized
    case unprocessableResponse(String)
    case rateLimited
    case serverError(String)
    case networkError(Error)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .unauthorized:
            return "Unauthorized. Please sign in."
        case .unprocessableResponse(let message):
            return "Could not process response: \(message)"
        case .rateLimited:
            return "Too many requests. Please try again later."
        case .serverError(let message):
            return "Server error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let message):
            return "Failed to decode response: \(message)"
        }
    }
}

// MARK: - Backend Response Types

/// Error response from Edge Functions
private struct BackendErrorResponse: Decodable {
    let error: BackendError

    struct BackendError: Decodable {
        let code: String
        let message: String
        let details: String?
    }
}

/// Config response (matches Edge Function output)
private struct ConfigResponse: Decodable {
    let name: String
    let description: String
    let contextDescription: String
    let valenceRange: FeatureRangeResponse?
    let energyRange: FeatureRangeResponse?
    let danceabilityRange: FeatureRangeResponse?
    let bpmRange: FeatureRangeResponse?
    let acousticnessRange: FeatureRangeResponse?
    let instrumentalnessRange: FeatureRangeResponse?
    let valenceWeight: Double
    let energyWeight: Double
    let danceabilityWeight: Double
    let bpmWeight: Double
    let acousticnessWeight: Double
    let instrumentalnessWeight: Double
    let suggestedGenres: [String]
    let suggestedDecades: [Int]?
    let moodKeywords: [String]

    func toLLMStationConfig(originalPrompt: String) -> LLMStationConfig {
        LLMStationConfig(
            name: name,
            description: description,
            originalPrompt: originalPrompt,
            valenceRange: valenceRange?.toFeatureRange(),
            energyRange: energyRange?.toFeatureRange(),
            danceabilityRange: danceabilityRange?.toFeatureRange(),
            bpmRange: bpmRange?.toFeatureRange(),
            acousticnessRange: acousticnessRange?.toFeatureRange(),
            instrumentalnessRange: instrumentalnessRange?.toFeatureRange(),
            valenceWeight: Float(valenceWeight),
            energyWeight: Float(energyWeight),
            danceabilityWeight: Float(danceabilityWeight),
            bpmWeight: Float(bpmWeight),
            acousticnessWeight: Float(acousticnessWeight),
            instrumentalnessWeight: Float(instrumentalnessWeight),
            suggestedGenres: suggestedGenres,
            suggestedDecades: suggestedDecades,
            moodKeywords: moodKeywords,
            contextDescription: contextDescription
        )
    }
}

private struct FeatureRangeResponse: Decodable {
    let min: Double
    let max: Double

    func toFeatureRange() -> FeatureRangeLLM {
        FeatureRangeLLM(min: Float(min), max: Float(max))
    }
}

/// Songs response
private struct SongsResponse: Decodable {
    let songs: [SongResponse]
}

private struct SongResponse: Decodable {
    let title: String
    let artist: String
    let album: String?
    let year: Int?
    let reason: String
    let estimatedBpm: Double?
    let estimatedEnergy: Double?
    let estimatedValence: Double?
    let estimatedDanceability: Double?
    let estimatedAcousticness: Double?
    let estimatedInstrumentalness: Double?

    func toLLMSongSuggestion() -> LLMSongSuggestion {
        LLMSongSuggestion(
            title: title,
            artist: artist,
            album: album,
            year: year,
            reason: reason,
            estimatedBpm: estimatedBpm.map { Float($0) },
            estimatedEnergy: estimatedEnergy.map { Float($0) },
            estimatedValence: estimatedValence.map { Float($0) },
            estimatedDanceability: estimatedDanceability.map { Float($0) },
            estimatedAcousticness: estimatedAcousticness.map { Float($0) },
            estimatedInstrumentalness: estimatedInstrumentalness.map { Float($0) },
            verificationStatus: .pending,
            appleMusicId: nil,
            isrc: nil,
            artworkURL: nil
        )
    }
}

/// Taste profile response
private struct TasteResponse: Decodable {
    let preferredGenres: [String]
    let avoidedGenres: [String]
    let preferredArtists: [String]
    let avoidedArtists: [String]
    let preferredDecades: [Int]
    let energyPreference: String
    let moodPreference: String
    let notablePatterns: [String]

    func toLLMTasteProfile(feedbackCount: Int) -> LLMTasteProfile {
        LLMTasteProfile(
            preferredGenres: preferredGenres,
            avoidedGenres: avoidedGenres,
            preferredArtists: preferredArtists,
            avoidedArtists: avoidedArtists,
            preferredDecades: preferredDecades,
            energyPreference: energyPreference,
            moodPreference: moodPreference,
            notablePatterns: notablePatterns,
            lastUpdatedAt: Date(),
            feedbackCountAtUpdate: feedbackCount
        )
    }
}

// MARK: - Request Types

private struct GenerateConfigRequestBody: Encodable {
    let prompt: String
    let tasteProfile: TasteProfileRequestBody?
}

private struct TasteProfileRequestBody: Encodable {
    let preferredGenres: [String]
    let avoidedGenres: [String]
    let preferredArtists: [String]
    let avoidedArtists: [String]
    let preferredDecades: [Int]
    let energyPreference: String
    let moodPreference: String
    let notablePatterns: [String]

    init(from profile: LLMTasteProfile) {
        self.preferredGenres = profile.preferredGenres
        self.avoidedGenres = profile.avoidedGenres
        self.preferredArtists = profile.preferredArtists
        self.avoidedArtists = profile.avoidedArtists
        self.preferredDecades = profile.preferredDecades
        self.energyPreference = profile.energyPreference
        self.moodPreference = profile.moodPreference
        self.notablePatterns = profile.notablePatterns
    }
}

private struct SuggestSongsRequestBody: Encodable {
    let config: StationConfigRequestBody
    let likedSongs: [SongInfoRequestBody]
    let dislikedSongs: [SongInfoRequestBody]
    let recentlyPlayed: [String]
    let count: Int
}

private struct StationConfigRequestBody: Encodable {
    let name: String
    let description: String
    let originalPrompt: String
    let contextDescription: String
    let valenceRange: FeatureRangeRequestBody?
    let energyRange: FeatureRangeRequestBody?
    let danceabilityRange: FeatureRangeRequestBody?
    let bpmRange: FeatureRangeRequestBody?
    let acousticnessRange: FeatureRangeRequestBody?
    let instrumentalnessRange: FeatureRangeRequestBody?
    let valenceWeight: Float
    let energyWeight: Float
    let danceabilityWeight: Float
    let bpmWeight: Float
    let acousticnessWeight: Float
    let instrumentalnessWeight: Float
    let suggestedGenres: [String]
    let suggestedDecades: [Int]?
    let moodKeywords: [String]

    init(from config: LLMStationConfig) {
        self.name = config.name
        self.description = config.description
        self.originalPrompt = config.originalPrompt
        self.contextDescription = config.contextDescription
        self.valenceRange = config.valenceRange.map { FeatureRangeRequestBody(min: $0.min, max: $0.max) }
        self.energyRange = config.energyRange.map { FeatureRangeRequestBody(min: $0.min, max: $0.max) }
        self.danceabilityRange = config.danceabilityRange.map { FeatureRangeRequestBody(min: $0.min, max: $0.max) }
        self.bpmRange = config.bpmRange.map { FeatureRangeRequestBody(min: $0.min, max: $0.max) }
        self.acousticnessRange = config.acousticnessRange.map { FeatureRangeRequestBody(min: $0.min, max: $0.max) }
        self.instrumentalnessRange = config.instrumentalnessRange.map { FeatureRangeRequestBody(min: $0.min, max: $0.max) }
        self.valenceWeight = config.valenceWeight
        self.energyWeight = config.energyWeight
        self.danceabilityWeight = config.danceabilityWeight
        self.bpmWeight = config.bpmWeight
        self.acousticnessWeight = config.acousticnessWeight
        self.instrumentalnessWeight = config.instrumentalnessWeight
        self.suggestedGenres = config.suggestedGenres
        self.suggestedDecades = config.suggestedDecades
        self.moodKeywords = config.moodKeywords
    }
}

private struct FeatureRangeRequestBody: Encodable {
    let min: Float
    let max: Float
}

private struct SongInfoRequestBody: Encodable {
    let title: String
    let artist: String
}

private struct AnalyzeTasteRequestBody: Encodable {
    let originalPrompt: String
    let currentProfile: TasteProfileRequestBody?
    let feedbackSummary: FeedbackSummaryRequestBody
}

private struct FeedbackSummaryRequestBody: Encodable {
    let totalLikes: Int
    let totalDislikes: Int
    let totalSkips: Int
    let likedSongs: [SongInfoWithGenreRequestBody]
    let dislikedSongs: [SongInfoWithGenreRequestBody]
}

private struct SongInfoWithGenreRequestBody: Encodable {
    let title: String
    let artist: String
    let genre: String?
}

// MARK: - Artist Seeds Request/Response Types

private struct GenerateArtistSeedsRequestBody: Encodable {
    let config: StationConfigRequestBody
    let tasteSummary: String?
    let avoidArtists: [String]?
    let count: Int
    let temperature: Double
    let preferredGenres: [String]?
    let nonPreferredGenres: [String]?
}

private struct ArtistSeedsResponse: Decodable {
    let seeds: [ArtistSeedResponse]
}

private struct ArtistSeedResponse: Decodable {
    let name: String
    let reason: String
    let similarityType: String
    let expectedGenres: [String]?
}

// MARK: - Backend Station Service

/// LLM Station Service that uses Supabase Edge Functions
final class BackendStationService: LLMStationServiceProtocol {

    // MARK: - Properties

    private let supabaseClient: SupabaseClient

    // MARK: - Initialization

    init(supabaseClient: SupabaseClient = SupabaseConfig.client) {
        self.supabaseClient = supabaseClient
        print("✅ BackendStationService initialized")
    }

    // MARK: - LLMStationServiceProtocol

    func generateConfig(from prompt: String, tasteProfile: LLMTasteProfile?) async throws -> LLMStationConfig {
        let requestBody = GenerateConfigRequestBody(
            prompt: prompt,
            tasteProfile: tasteProfile.map { TasteProfileRequestBody(from: $0) }
        )

        let response: ConfigResponse = try await invokeFunction(
            name: "generate-config",
            body: requestBody
        )

        return response.toLLMStationConfig(originalPrompt: prompt)
    }

    func suggestSongs(request: LLMSongRequest) async throws -> [LLMSongSuggestion] {
        let requestBody = SuggestSongsRequestBody(
            config: StationConfigRequestBody(from: request.config),
            likedSongs: request.likedSongs.map { SongInfoRequestBody(title: $0.title, artist: $0.artist) },
            dislikedSongs: request.dislikedSongs.map { SongInfoRequestBody(title: $0.title, artist: $0.artist) },
            recentlyPlayed: request.recentlyPlayed,
            count: request.count
        )

        let response: SongsResponse = try await invokeFunction(
            name: "suggest-songs",
            body: requestBody
        )

        return response.songs.map { $0.toLLMSongSuggestion() }
    }

    func analyzeTaste(
        originalPrompt: String,
        currentProfile: LLMTasteProfile?,
        feedbackSummary: StationFeedbackSummary
    ) async throws -> LLMTasteProfile {
        let requestBody = AnalyzeTasteRequestBody(
            originalPrompt: originalPrompt,
            currentProfile: currentProfile.map { TasteProfileRequestBody(from: $0) },
            feedbackSummary: FeedbackSummaryRequestBody(
                totalLikes: feedbackSummary.totalLikes,
                totalDislikes: feedbackSummary.totalDislikes,
                totalSkips: feedbackSummary.totalSkips,
                likedSongs: feedbackSummary.likedSongs.map {
                    SongInfoWithGenreRequestBody(title: $0.title, artist: $0.artist, genre: $0.genre)
                },
                dislikedSongs: feedbackSummary.dislikedSongs.map {
                    SongInfoWithGenreRequestBody(title: $0.title, artist: $0.artist, genre: $0.genre)
                }
            )
        )

        let response: TasteResponse = try await invokeFunction(
            name: "analyze-taste",
            body: requestBody
        )

        let feedbackCount = feedbackSummary.totalLikes + feedbackSummary.totalDislikes
        return response.toLLMTasteProfile(feedbackCount: feedbackCount)
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
        let requestBody = GenerateArtistSeedsRequestBody(
            config: StationConfigRequestBody(from: config),
            tasteSummary: tasteSummary.isEmpty ? nil : tasteSummary,
            avoidArtists: avoidArtists.isEmpty ? nil : avoidArtists,
            count: count,
            temperature: temperature,
            preferredGenres: preferredGenres.isEmpty ? nil : preferredGenres,
            nonPreferredGenres: nonPreferredGenres.isEmpty ? nil : nonPreferredGenres
        )

        let response: ArtistSeedsResponse = try await invokeFunction(
            name: "generate-artist-seeds",
            body: requestBody
        )

        return response.seeds.map { seed in
            ArtistSeed(
                name: seed.name,
                reason: seed.reason,
                similarityType: SimilarityType(rawValue: seed.similarityType) ?? .direct,
                expectedGenres: seed.expectedGenres
            )
        }
    }

    // MARK: - Private Helpers

    private func invokeFunction<Request: Encodable, Response: Decodable>(
        name: String,
        body: Request
    ) async throws -> Response {
        do {
            // Supabase Swift SDK returns the decoded response directly when using invoke with body
            let response: Response = try await supabaseClient.functions.invoke(
                name,
                options: FunctionInvokeOptions(body: body)
            )
            return response

        } catch let error as FunctionsError {
            // Handle Supabase Functions errors
            throw mapFunctionsError(error)

        } catch let error as DecodingError {
            throw BackendServiceError.decodingError(error.localizedDescription)

        } catch {
            throw BackendServiceError.networkError(error)
        }
    }

    private func mapFunctionsError(_ error: FunctionsError) -> BackendServiceError {
        switch error {
        case .httpError(let code, let data):
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
                let message = errorResponse.error.message

                switch code {
                case 400:
                    return .invalidRequest(message)
                case 401:
                    return .unauthorized
                case 422:
                    return .unprocessableResponse(message)
                case 429:
                    return .rateLimited
                case 500, 502, 503:
                    return .serverError(message)
                default:
                    return .serverError("HTTP \(code): \(message)")
                }
            }

            // Fallback for non-JSON errors
            switch code {
            case 401:
                return .unauthorized
            case 429:
                return .rateLimited
            default:
                return .serverError("HTTP error: \(code)")
            }

        case .relayError:
            return .serverError("Relay error")
        }
    }
}
