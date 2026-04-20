//
//  FeedbackRepository.swift
//  Curate
//
//  Supabase operations for track feedback storage and retrieval.
//

import Foundation
import Supabase

// MARK: - Feedback Repository

final class FeedbackRepository: FeedbackRepositoryProtocol {
    private let supabase: SupabaseClient

    init(supabase: SupabaseClient = SupabaseConfig.client) {
        self.supabase = supabase
    }

    // MARK: - Record Feedback

    func recordFeedback(_ feedback: TrackFeedbackRecord) async throws {
        let insertData = FeedbackInsert(
            userId: feedback.userId,
            appleMusicId: feedback.appleMusicId,
            isrc: feedback.isrc,
            trackTitle: feedback.trackTitle,
            artistName: feedback.artistName,
            albumName: feedback.albumName,
            feedbackType: feedback.feedbackType.rawValue,
            stationId: feedback.stationId,
            playedAt: feedback.playedAt,
            feedbackAt: feedback.feedbackAt
        )

        try await supabase
            .from("track_feedback")
            .insert(insertData)
            .execute()
    }

    // MARK: - Get Feedback

    func getFeedback(userId: UUID) async throws -> [TrackFeedbackRecord] {
        let response: [FeedbackRow] = try await supabase
            .from("track_feedback")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("played_at", ascending: false)
            .execute()
            .value

        return response.map { $0.toRecord() }
    }

    // MARK: - Get Artist Scores

    func getArtistScores(userId: UUID) async throws -> [ArtistScore] {
        let response: [ArtistScoreRow] = try await supabase
            .from("artist_scores")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        return response.map { $0.toArtistScore() }
    }

    // MARK: - Get Recently Played ISRCs

    func getRecentlyPlayedISRCs(userId: UUID, days: Int) async throws -> [String] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let response: [ISRCRow] = try await supabase
            .from("track_feedback")
            .select("isrc")
            .eq("user_id", value: userId.uuidString)
            .gte("played_at", value: ISO8601DateFormatter().string(from: cutoffDate))
            .not("isrc", operator: .is, value: "null")
            .execute()
            .value

        return response.compactMap { $0.isrc }
    }

    // MARK: - Get Recently Played Track IDs

    func getRecentlyPlayedTrackIds(userId: UUID, days: Int) async throws -> [String] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let response: [TrackIdRow] = try await supabase
            .from("track_feedback")
            .select("apple_music_id")
            .eq("user_id", value: userId.uuidString)
            .gte("played_at", value: ISO8601DateFormatter().string(from: cutoffDate))
            .not("apple_music_id", operator: .is, value: "null")
            .execute()
            .value

        return response.compactMap { $0.appleMusicId }
    }
}

// MARK: - Database Row Types

private struct FeedbackInsert: Encodable {
    let userId: UUID
    let appleMusicId: String?
    let isrc: String?
    let trackTitle: String
    let artistName: String
    let albumName: String?
    let feedbackType: String
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

private struct FeedbackRow: Decodable {
    let id: UUID
    let userId: UUID
    let appleMusicId: String?
    let isrc: String?
    let trackTitle: String
    let artistName: String
    let albumName: String?
    let feedbackType: String
    let stationId: UUID?
    let playedAt: Date
    let feedbackAt: Date

    enum CodingKeys: String, CodingKey {
        case id
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

    func toRecord() -> TrackFeedbackRecord {
        TrackFeedbackRecord(
            userId: userId,
            appleMusicId: appleMusicId,
            isrc: isrc,
            trackTitle: trackTitle,
            artistName: artistName,
            albumName: albumName,
            feedbackType: ProviderFeedbackType(rawValue: feedbackType) ?? .skip,
            stationId: stationId,
            playedAt: playedAt,
            feedbackAt: feedbackAt
        )
    }
}

private struct ArtistScoreRow: Decodable {
    let userId: UUID
    let artistName: String
    let likeCount: Int
    let dislikeCount: Int
    let skipCount: Int
    let listenCount: Int
    let lastPlayedAt: Date?
    let weightedScore: Double

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case artistName = "artist_name"
        case likeCount = "like_count"
        case dislikeCount = "dislike_count"
        case skipCount = "skip_count"
        case listenCount = "listen_count"
        case lastPlayedAt = "last_played_at"
        case weightedScore = "weighted_score"
    }

    func toArtistScore() -> ArtistScore {
        ArtistScore(
            artistName: artistName,
            likeCount: likeCount,
            dislikeCount: dislikeCount,
            skipCount: skipCount,
            listenCount: listenCount,
            lastPlayedAt: lastPlayedAt,
            weightedScore: weightedScore
        )
    }
}

private struct ISRCRow: Decodable {
    let isrc: String?
}

private struct TrackIdRow: Decodable {
    let appleMusicId: String?

    enum CodingKeys: String, CodingKey {
        case appleMusicId = "apple_music_id"
    }
}
