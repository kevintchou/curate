//
//  MusicProviderTypes.swift
//  Curate
//
//  Provider-agnostic types for music services.
//  Enables abstraction over Apple Music, Spotify, etc.
//

import Foundation

// MARK: - Provider Type

enum MusicProviderType: String, Codable, CaseIterable {
    case appleMusic = "apple_music"
    case spotify = "spotify"
}

// MARK: - Resolved Artist

/// An artist resolved from a provider's catalog
struct ResolvedArtist: Identifiable, Codable, Equatable {
    let id: String                    // Provider-specific ID
    let name: String
    let providerType: MusicProviderType
    let matchConfidence: Float        // 0.0 - 1.0, how well the name matched
    let genres: [String]?
    let imageURL: URL?

    static func == (lhs: ResolvedArtist, rhs: ResolvedArtist) -> Bool {
        lhs.id == rhs.id && lhs.providerType == rhs.providerType
    }
}

// MARK: - Provider Track

/// A track from a music provider's catalog
struct ProviderTrack: Identifiable, Codable, Equatable {
    let id: String                    // Provider-specific track ID
    let isrc: String?                 // International Standard Recording Code
    let title: String
    let artistName: String
    let artistId: String
    let albumName: String?
    let durationMs: Int?
    let releaseDate: String?          // ISO date string
    let providerType: MusicProviderType
    let artworkURL: URL?
    let isExplicit: Bool?

    static func == (lhs: ProviderTrack, rhs: ProviderTrack) -> Bool {
        lhs.id == rhs.id && lhs.providerType == rhs.providerType
    }
}

// MARK: - Similarity Type

/// How an artist relates to the station's mood/theme
enum SimilarityType: String, Codable, CaseIterable {
    case direct        // Directly matches the mood/genre
    case adjacent      // Related but slightly different angle
    case discovery     // Stretch pick for variety
}

// MARK: - Artist Seed

/// An artist suggested by the LLM for seeding recommendations
struct ArtistSeed: Codable, Equatable {
    let name: String
    let reason: String
    let similarityType: SimilarityType
    let expectedGenres: [String]?
}

// MARK: - Artist Score

/// Aggregated feedback score for an artist (from Supabase view)
struct ArtistScore: Codable, Equatable {
    let artistName: String
    let likeCount: Int
    let dislikeCount: Int
    let skipCount: Int
    let listenCount: Int
    let lastPlayedAt: Date?
    let weightedScore: Double

    /// Whether this artist should be avoided (negative score)
    var shouldAvoid: Bool {
        weightedScore < -1.0
    }

    /// Whether this artist is preferred (positive score)
    var isPreferred: Bool {
        weightedScore > 1.0
    }
}

// MARK: - Track Feedback Record

/// A single feedback event to store in Supabase
struct TrackFeedbackRecord: Codable {
    let userId: UUID
    let appleMusicId: String?
    let isrc: String?
    let trackTitle: String
    let artistName: String
    let albumName: String?
    let feedbackType: ProviderFeedbackType
    let stationId: UUID?
    let playedAt: Date
    let feedbackAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case appleMusicId = "apple_music_id"
        case isrc
        case trackTitle = "track_title"
        case artistName = "artist_name"
        case albumName = "album_name"
        case feedbackType = "feedback_type"
        case stationId = "station_id"
        case playedAt = "played_at"
        case feedbackAt = "feedback_at"
    }
}

// MARK: - Provider Feedback Type

/// Feedback type for Supabase storage (distinct from local FeedbackType in Feedback.swift)
enum ProviderFeedbackType: String, Codable, CaseIterable {
    case like = "like"
    case dislike = "dislike"
    case skip = "skip"
    case listenThrough = "listen_through"
}

// MARK: - Taste Hash

/// Hash of user preferences for cache invalidation
struct TasteHash: Codable, Equatable {
    let hash: String

    init(from preferences: [String: Any]) {
        // Create a stable hash from preferences
        let sortedKeys = preferences.keys.sorted()
        var components: [String] = []
        for key in sortedKeys {
            if let value = preferences[key] {
                components.append("\(key):\(value)")
            }
        }
        let combined = components.joined(separator: "|")
        self.hash = combined.sha256Hash
    }

    init(hash: String) {
        self.hash = hash
    }
}

// MARK: - Cached Artist

/// Artist data from the global cache
struct CachedArtist: Codable {
    let canonicalId: String
    let name: String
    let providerType: MusicProviderType
    let genres: [String]?
    let imageUrl: String?
    let topTrackIds: [String]
    let cachedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case canonicalId = "canonical_id"
        case name
        case providerType = "provider_type"
        case genres
        case imageUrl = "image_url"
        case topTrackIds = "top_track_ids"
        case cachedAt = "cached_at"
        case expiresAt = "expires_at"
    }

    var isExpired: Bool {
        Date() > expiresAt
    }
}

// MARK: - Cached Seed

/// Seed cache entry from Supabase
struct CachedSeed: Codable {
    let id: UUID
    let userId: UUID
    let stationConfigHash: String
    let tasteHash: String
    let seedsJson: String
    let cachedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case stationConfigHash = "station_config_hash"
        case tasteHash = "taste_hash"
        case seedsJson = "seeds_json"
        case cachedAt = "cached_at"
        case expiresAt = "expires_at"
    }

    var isExpired: Bool {
        Date() > expiresAt
    }

    /// Decode the seeds from JSON
    func decodedSeeds() throws -> [ArtistSeed] {
        guard let data = seedsJson.data(using: .utf8) else {
            throw MusicProviderError.invalidData("Invalid seed JSON encoding")
        }
        return try JSONDecoder().decode([ArtistSeed].self, from: data)
    }
}

// MARK: - Errors

enum MusicProviderError: LocalizedError {
    case notAuthorized
    case artistNotFound(String)
    case noTracksAvailable(String)
    case rateLimited
    case networkError(Error)
    case invalidData(String)
    case cacheError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Music provider not authorized"
        case .artistNotFound(let name):
            return "Artist not found: \(name)"
        case .noTracksAvailable(let artist):
            return "No tracks available for artist: \(artist)"
        case .rateLimited:
            return "Rate limited by music provider"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidData(let message):
            return "Invalid data: \(message)"
        case .cacheError(let message):
            return "Cache error: \(message)"
        }
    }
}

// Note: sha256Hash extension is defined in LLMStationTypes.swift
