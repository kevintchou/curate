//
//  UserOverlayManager.swift
//  Curate
//
//  Manages per-user, per-station state for recommendation personalization.
//  Handles session lifecycle, skip tracking, and exploration decay.
//

import Foundation

// MARK: - Protocol

protocol UserOverlayManagerProtocol {
    /// Get or create an overlay for user+station
    func getOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        policy: StationPolicy
    ) async throws -> UserStationOverlay

    /// Save overlay changes to persistent storage
    func saveOverlay(_ overlay: UserStationOverlay) async throws

    /// Reset session state (called when station starts playing)
    func resetSession(
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    )

    /// Record a track play
    func recordPlay(
        track: PoolTrack,
        overlay: inout UserStationOverlay
    ) async throws

    /// Record a skip
    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    ) async throws

    /// Delete overlay for a station
    func deleteOverlay(userId: UUID, stationId: UUID) async throws
}

// MARK: - Implementation

final class UserOverlayManager: UserOverlayManagerProtocol {

    private let repository: UserOverlayRepositoryProtocol

    // Cache for quick access (avoids hitting DB on every play/skip)
    private var cache: [String: UserStationOverlay] = [:]
    private let cacheQueue = DispatchQueue(label: "com.curate.overlay.cache")

    // Debounced save to reduce DB writes
    private var pendingSaves: [String: UserStationOverlay] = [:]
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: TimeInterval = 2.0

    // MARK: - Initialization

    init(repository: UserOverlayRepositoryProtocol) {
        self.repository = repository
    }

    // MARK: - Get Overlay

    func getOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        policy: StationPolicy
    ) async throws -> UserStationOverlay {
        let cacheKey = Self.cacheKey(userId: userId, stationId: stationId)

        // Check cache first
        if let cached = cacheQueue.sync(execute: { cache[cacheKey] }) {
            return cached
        }

        // Fetch or create from repository
        let overlay = try await repository.getOrCreateOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: canonicalIntent,
            policy: policy
        )

        // Update cache
        cacheQueue.sync {
            cache[cacheKey] = overlay
        }

        return overlay
    }

    // MARK: - Save Overlay

    func saveOverlay(_ overlay: UserStationOverlay) async throws {
        let cacheKey = Self.cacheKey(userId: overlay.userId, stationId: overlay.stationId)

        // Update cache immediately
        cacheQueue.sync {
            cache[cacheKey] = overlay
            pendingSaves[cacheKey] = overlay
        }

        // Schedule debounced save
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(saveDebounceInterval * 1_000_000_000))

            guard !Task.isCancelled else { return }

            // Get pending saves and clear
            let toSave = cacheQueue.sync { () -> [UserStationOverlay] in
                let values = Array(pendingSaves.values)
                pendingSaves.removeAll()
                return values
            }

            // Save all pending overlays
            for overlay in toSave {
                try? await repository.saveOverlay(overlay)
            }
        }
    }

    /// Force immediate save of all pending overlays
    func flushPendingSaves() async {
        saveTask?.cancel()

        let toSave = cacheQueue.sync { () -> [UserStationOverlay] in
            let values = Array(pendingSaves.values)
            pendingSaves.removeAll()
            return values
        }

        for overlay in toSave {
            try? await repository.saveOverlay(overlay)
        }
    }

    // MARK: - Reset Session

    func resetSession(overlay: inout UserStationOverlay, policy: StationPolicy) {
        overlay.resetSession(policy: policy)

        // Update cache
        let cacheKey = Self.cacheKey(userId: overlay.userId, stationId: overlay.stationId)
        cacheQueue.sync {
            cache[cacheKey] = overlay
        }
    }

    // MARK: - Record Play

    func recordPlay(track: PoolTrack, overlay: inout UserStationOverlay) async throws {
        overlay.recordPlay(track: track)
        try await saveOverlay(overlay)
    }

    // MARK: - Record Skip

    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    ) async throws {
        overlay.recordSkip(trackId: track.trackId, policy: policy)
        try await saveOverlay(overlay)
    }

    // MARK: - Delete Overlay

    func deleteOverlay(userId: UUID, stationId: UUID) async throws {
        let cacheKey = Self.cacheKey(userId: userId, stationId: stationId)

        // Remove from cache
        cacheQueue.sync {
            cache.removeValue(forKey: cacheKey)
            pendingSaves.removeValue(forKey: cacheKey)
        }

        // Delete from repository
        try await repository.deleteOverlay(userId: userId, stationId: stationId)
    }

    // MARK: - Cache Helpers

    private static func cacheKey(userId: UUID, stationId: UUID) -> String {
        "\(userId.uuidString)_\(stationId.uuidString)"
    }

    /// Clear all cached overlays (for testing or logout)
    func clearCache() {
        cacheQueue.sync {
            cache.removeAll()
            pendingSaves.removeAll()
        }
        saveTask?.cancel()
    }

    /// Preload overlays for multiple stations
    func preloadOverlays(userId: UUID, stationIds: [UUID]) async {
        for stationId in stationIds {
            if let overlay = try? await repository.getOverlay(
                userId: userId,
                stationId: stationId
            ) {
                let key = Self.cacheKey(userId: userId, stationId: stationId)
                cacheQueue.sync {
                    cache[key] = overlay
                }
            }
        }
    }
}

// MARK: - Session Analytics

extension UserStationOverlay {
    /// Calculate skip rate for current session
    var sessionSkipRate: Double {
        let totalPlays = recentTrackIds.count
        guard totalPlays > 0 else { return 0 }
        return Double(sessionSkipCount) / Double(totalPlays)
    }

    /// Calculate overall skip rate
    var overallSkipRate: Double {
        let totalPlays = recentTrackIds.count
        guard totalPlays > 0 else { return 0 }
        return Double(totalSkipCount) / Double(totalPlays)
    }

    /// Time since session started
    var sessionDuration: TimeInterval? {
        guard let start = sessionStartedAt else { return nil }
        return Date().timeIntervalSince(start)
    }

    /// Whether the session is stale (e.g., > 1 hour since last play)
    func isSessionStale(threshold: TimeInterval = 3600) -> Bool {
        guard let lastPlayed = lastPlayedAt else { return true }
        return Date().timeIntervalSince(lastPlayed) > threshold
    }
}

// MARK: - Mock Implementation for Testing

final class MockUserOverlayManager: UserOverlayManagerProtocol {

    var overlays: [String: UserStationOverlay] = [:]
    var getOverlayCallCount = 0
    var saveOverlayCallCount = 0
    var recordPlayCallCount = 0
    var recordSkipCallCount = 0

    private func key(userId: UUID, stationId: UUID) -> String {
        "\(userId.uuidString)_\(stationId.uuidString)"
    }

    func getOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        policy: StationPolicy
    ) async throws -> UserStationOverlay {
        getOverlayCallCount += 1
        let k = key(userId: userId, stationId: stationId)

        if let existing = overlays[k] {
            return existing
        }

        let overlay = UserStationOverlay(
            userId: userId,
            stationId: stationId,
            canonicalIntent: canonicalIntent,
            currentExplorationWeight: policy.baseExplorationWeight,
            baseExplorationWeight: policy.baseExplorationWeight
        )

        overlays[k] = overlay
        return overlay
    }

    func saveOverlay(_ overlay: UserStationOverlay) async throws {
        saveOverlayCallCount += 1
        overlays[key(userId: overlay.userId, stationId: overlay.stationId)] = overlay
    }

    func resetSession(overlay: inout UserStationOverlay, policy: StationPolicy) {
        overlay.resetSession(policy: policy)
    }

    func recordPlay(track: PoolTrack, overlay: inout UserStationOverlay) async throws {
        recordPlayCallCount += 1
        overlay.recordPlay(track: track)
    }

    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    ) async throws {
        recordSkipCallCount += 1
        overlay.recordSkip(trackId: track.trackId, policy: policy)
    }

    func deleteOverlay(userId: UUID, stationId: UUID) async throws {
        overlays.removeValue(forKey: key(userId: userId, stationId: stationId))
    }
}
