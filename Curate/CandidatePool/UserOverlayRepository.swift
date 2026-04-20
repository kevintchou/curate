//
//  UserOverlayRepository.swift
//  Curate
//
//  Repository for user station overlay operations via Supabase.
//  Manages per-user, per-station state for recommendation personalization.
//

import Foundation
import Supabase

// MARK: - Protocol

protocol UserOverlayRepositoryProtocol {
    /// Get overlay for a user and station
    func getOverlay(userId: UUID, stationId: UUID) async throws -> UserStationOverlay?

    /// Get or create overlay for a user and station
    func getOrCreateOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        policy: StationPolicy
    ) async throws -> UserStationOverlay

    /// Save overlay to Supabase
    func saveOverlay(_ overlay: UserStationOverlay) async throws

    /// Delete overlay (e.g., when station is deleted)
    func deleteOverlay(userId: UUID, stationId: UUID) async throws

    /// Get all overlays for a user
    func getOverlays(userId: UUID) async throws -> [UserStationOverlay]
}

// MARK: - Implementation

final class UserOverlayRepository: UserOverlayRepositoryProtocol {

    private let supabaseClient: SupabaseClient

    // MARK: - Initialization

    init(supabaseClient: SupabaseClient) {
        self.supabaseClient = supabaseClient
    }

    // MARK: - Get Overlay

    func getOverlay(userId: UUID, stationId: UUID) async throws -> UserStationOverlay? {
        let response: [OverlayRow] = try await supabaseClient
            .from("user_station_overlay")
            .select()
            .eq("user_id", value: userId.uuidString)
            .eq("station_id", value: stationId.uuidString)
            .limit(1)
            .execute()
            .value

        return response.first?.toUserStationOverlay()
    }

    // MARK: - Get or Create Overlay

    func getOrCreateOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        policy: StationPolicy
    ) async throws -> UserStationOverlay {
        // Try to get existing overlay
        if let existing = try await getOverlay(userId: userId, stationId: stationId) {
            return existing
        }

        // Create new overlay with default values
        let overlay = UserStationOverlay(
            id: UUID(),
            userId: userId,
            stationId: stationId,
            canonicalIntent: canonicalIntent,
            currentExplorationWeight: policy.baseExplorationWeight,
            baseExplorationWeight: policy.baseExplorationWeight
        )

        // Save to database
        try await saveOverlay(overlay)

        return overlay
    }

    // MARK: - Save Overlay

    func saveOverlay(_ overlay: UserStationOverlay) async throws {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var data: [String: AnyJSON] = [
            "id": .string(overlay.id.uuidString),
            "user_id": .string(overlay.userId.uuidString),
            "station_id": .string(overlay.stationId.uuidString),
            "canonical_intent": .string(overlay.canonicalIntent),
            "recent_track_ids": .array(overlay.recentTrackIds.map { .string($0) }),
            "recent_track_isrcs": .array(overlay.recentTrackISRCs.map { .string($0) }),
            "recent_artist_ids": .array(overlay.recentArtistIds.map { .string($0) }),
            "session_skip_count": .integer(overlay.sessionSkipCount),
            "total_skip_count": .integer(overlay.totalSkipCount),
            "skipped_track_ids": .array(overlay.skippedTrackIds.map { .string($0) }),
            "current_exploration_weight": .double(overlay.currentExplorationWeight),
            "base_exploration_weight": .double(overlay.baseExplorationWeight),
            "updated_at": .string(dateFormatter.string(from: overlay.updatedAt))
        ]

        if let sessionStartedAt = overlay.sessionStartedAt {
            data["session_started_at"] = .string(dateFormatter.string(from: sessionStartedAt))
        }

        if let lastPlayedAt = overlay.lastPlayedAt {
            data["last_played_at"] = .string(dateFormatter.string(from: lastPlayedAt))
        }

        try await supabaseClient
            .from("user_station_overlay")
            .upsert(data, onConflict: "user_id,station_id")
            .execute()
    }

    // MARK: - Delete Overlay

    func deleteOverlay(userId: UUID, stationId: UUID) async throws {
        try await supabaseClient
            .from("user_station_overlay")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .eq("station_id", value: stationId.uuidString)
            .execute()
    }

    // MARK: - Get All Overlays for User

    func getOverlays(userId: UUID) async throws -> [UserStationOverlay] {
        let response: [OverlayRow] = try await supabaseClient
            .from("user_station_overlay")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("last_played_at", ascending: false)
            .execute()
            .value

        return response.compactMap { $0.toUserStationOverlay() }
    }
}

// MARK: - Database Row Type

private struct OverlayRow: Codable {
    let id: String
    let userId: String
    let stationId: String
    let canonicalIntent: String
    let recentTrackIds: [String]
    let recentTrackIsrcs: [String]
    let recentArtistIds: [String]
    let sessionSkipCount: Int
    let sessionStartedAt: String?
    let totalSkipCount: Int
    let skippedTrackIds: [String]
    let currentExplorationWeight: Double
    let baseExplorationWeight: Double
    let createdAt: String
    let updatedAt: String
    let lastPlayedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case stationId = "station_id"
        case canonicalIntent = "canonical_intent"
        case recentTrackIds = "recent_track_ids"
        case recentTrackIsrcs = "recent_track_isrcs"
        case recentArtistIds = "recent_artist_ids"
        case sessionSkipCount = "session_skip_count"
        case sessionStartedAt = "session_started_at"
        case totalSkipCount = "total_skip_count"
        case skippedTrackIds = "skipped_track_ids"
        case currentExplorationWeight = "current_exploration_weight"
        case baseExplorationWeight = "base_exploration_weight"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastPlayedAt = "last_played_at"
    }

    func toUserStationOverlay() -> UserStationOverlay? {
        guard let id = UUID(uuidString: id),
              let userId = UUID(uuidString: userId),
              let stationId = UUID(uuidString: stationId) else {
            return nil
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return UserStationOverlay(
            id: id,
            userId: userId,
            stationId: stationId,
            canonicalIntent: canonicalIntent,
            recentTrackIds: recentTrackIds,
            recentTrackISRCs: recentTrackIsrcs,
            recentArtistIds: recentArtistIds,
            sessionSkipCount: sessionSkipCount,
            sessionStartedAt: sessionStartedAt.flatMap { dateFormatter.date(from: $0) },
            totalSkipCount: totalSkipCount,
            skippedTrackIds: skippedTrackIds,
            currentExplorationWeight: currentExplorationWeight,
            baseExplorationWeight: baseExplorationWeight,
            createdAt: dateFormatter.date(from: createdAt) ?? Date(),
            updatedAt: dateFormatter.date(from: updatedAt) ?? Date(),
            lastPlayedAt: lastPlayedAt.flatMap { dateFormatter.date(from: $0) }
        )
    }
}

// MARK: - Mock Implementation for Testing

final class MockUserOverlayRepository: UserOverlayRepositoryProtocol {

    var overlays: [String: UserStationOverlay] = [:]
    var getOverlayCallCount = 0
    var saveOverlayCallCount = 0
    var deleteOverlayCallCount = 0

    private func key(userId: UUID, stationId: UUID) -> String {
        "\(userId.uuidString)_\(stationId.uuidString)"
    }

    func getOverlay(userId: UUID, stationId: UUID) async throws -> UserStationOverlay? {
        getOverlayCallCount += 1
        return overlays[key(userId: userId, stationId: stationId)]
    }

    func getOrCreateOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        policy: StationPolicy
    ) async throws -> UserStationOverlay {
        if let existing = overlays[key(userId: userId, stationId: stationId)] {
            return existing
        }

        let overlay = UserStationOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: canonicalIntent,
            currentExplorationWeight: policy.baseExplorationWeight,
            baseExplorationWeight: policy.baseExplorationWeight
        )

        overlays[key(userId: userId, stationId: stationId)] = overlay
        return overlay
    }

    func saveOverlay(_ overlay: UserStationOverlay) async throws {
        saveOverlayCallCount += 1
        overlays[key(userId: overlay.userId, stationId: overlay.stationId)] = overlay
    }

    func deleteOverlay(userId: UUID, stationId: UUID) async throws {
        deleteOverlayCallCount += 1
        overlays.removeValue(forKey: key(userId: userId, stationId: stationId))
    }

    func getOverlays(userId: UUID) async throws -> [UserStationOverlay] {
        overlays.values.filter { $0.userId == userId }
    }
}
