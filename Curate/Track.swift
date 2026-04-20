//
//  Track.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation

/// Track model matching the Supabase `tracks` table schema
struct Track: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let isrc: String
    let spotifyId: String?
    let appleMusicId: String?
    let reccobeatsId: String?
    let title: String
    let artistName: String
    let albumName: String?
    let durationMs: Int?
    let releaseDate: String?  // ISO date string
    let genre: String?
    let hasLyrics: Bool?
    
    // Audio features from ReccoBeats
    let bpm: Float?
    let energy: Float?
    let danceability: Float?
    let valence: Float?
    let acousticness: Float?
    let instrumentalness: Float?
    let liveness: Float?
    let speechiness: Float?
    let loudness: Float?
    let key: Int?
    let mode: Int?
    
    let attributesFetchedAt: String?
    let createdAt: String?
    let updatedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case isrc
        case spotifyId = "spotify_id"
        case appleMusicId = "apple_music_id"
        case reccobeatsId = "reccobeats_id"
        case title
        case artistName = "artist_name"
        case albumName = "album_name"
        case durationMs = "duration_ms"
        case releaseDate = "release_date"
        case genre
        case hasLyrics = "has_lyrics"
        case bpm
        case energy
        case danceability
        case valence
        case acousticness
        case instrumentalness
        case liveness
        case speechiness
        case loudness
        case key
        case mode
        case attributesFetchedAt = "attributes_fetched_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    /// Check if this track has complete audio features for recommendation
    var hasAudioFeatures: Bool {
        bpm != nil && energy != nil && danceability != nil && valence != nil
    }
    
    /// Extract the decade from release date (e.g., 1990 for 1990s)
    var decade: Int? {
        guard let releaseDate = releaseDate,
              let year = Int(releaseDate.prefix(4)) else {
            return nil
        }
        return (year / 10) * 10
    }
}

// MARK: - Track Features for Thompson Sampling
extension Track {
    /// Extracts normalized feature vector for Thompson Sampling
    /// All features are normalized to 0-1 range
    func featureVector() -> TrackFeatures {
        TrackFeatures(
            bpm: normalizedBPM,
            energy: energy ?? 0.5,
            danceability: danceability ?? 0.5,
            valence: valence ?? 0.5,
            acousticness: acousticness ?? 0.5,
            instrumentalness: instrumentalness ?? 0.5
        )
    }
    
    /// BPM normalized to 0-1 range (assuming 60-200 BPM range)
    private var normalizedBPM: Float {
        guard let bpm = bpm else { return 0.5 }
        let minBPM: Float = 60
        let maxBPM: Float = 200
        return max(0, min(1, (bpm - minBPM) / (maxBPM - minBPM)))
    }
}

/// Normalized feature vector for a track
struct TrackFeatures: Codable, Equatable {
    let bpm: Float           // 0-1 normalized
    let energy: Float        // 0-1
    let danceability: Float  // 0-1
    let valence: Float       // 0-1 (mood: 0=sad, 1=happy)
    let acousticness: Float  // 0-1
    let instrumentalness: Float // 0-1
    
    /// Calculate similarity to another track's features (0-1, higher = more similar)
    func similarity(to other: TrackFeatures) -> Float {
        let diffs: [Float] = [
            abs(bpm - other.bpm),
            abs(energy - other.energy),
            abs(danceability - other.danceability),
            abs(valence - other.valence),
            abs(acousticness - other.acousticness),
            abs(instrumentalness - other.instrumentalness)
        ]
        let avgDiff = diffs.reduce(0, +) / Float(diffs.count)
        return 1 - avgDiff
    }
}
