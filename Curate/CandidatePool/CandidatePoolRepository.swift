//
//  CandidatePoolRepository.swift
//  Curate
//
//  Repository for candidate pool operations via Supabase.
//  Handles pool CRUD, track management, and refresh coordination.
//

import Foundation
import Supabase

// MARK: - Protocol

protocol CandidatePoolRepositoryProtocol {
    /// Get a candidate pool by intent hash and platform
    func getPool(
        intentHash: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool?

    /// Get pool tracks (calls Edge Function for efficient filtering)
    func getPoolTracks(
        intentHash: String,
        platform: MusicPlatform,
        limit: Int,
        excludeTrackIds: [String]
    ) async throws -> (tracks: [PoolTrack], metadata: PoolMetadata?)

    /// Save a new pool or update existing
    func savePool(_ pool: CandidatePool) async throws

    /// Refresh pool with new tracks (calls Edge Function)
    func refreshPool(
        intentHash: String,
        platform: MusicPlatform,
        newTracks: [PoolTrack],
        refreshPercentage: Double
    ) async throws -> RefreshCandidatePoolResponse

    /// Update track serve count after selection
    func recordTrackServed(poolId: UUID, trackIds: [String]) async throws
}

// MARK: - Implementation

final class CandidatePoolRepository: CandidatePoolRepositoryProtocol {

    private let supabaseClient: SupabaseClient

    // MARK: - Initialization

    init(supabaseClient: SupabaseClient) {
        self.supabaseClient = supabaseClient
    }

    // MARK: - Get Pool

    func getPool(
        intentHash: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool? {
        let response: [PoolRow] = try await supabaseClient
            .from("candidate_pools")
            .select()
            .eq("canonical_intent_hash", value: intentHash)
            .eq("platform", value: platform.rawValue)
            .limit(1)
            .execute()
            .value

        guard let row = response.first else {
            return nil
        }

        // Fetch tracks for this pool
        let trackRows: [PoolTrackRow] = try await supabaseClient
            .from("candidate_pool_tracks")
            .select()
            .eq("pool_id", value: row.id)
            .order("added_at", ascending: false)
            .limit(1000)
            .execute()
            .value

        return row.toCandidatePool(tracks: trackRows.map { $0.toPoolTrack() })
    }

    // MARK: - Get Pool Tracks (via Edge Function)

    func getPoolTracks(
        intentHash: String,
        platform: MusicPlatform,
        limit: Int,
        excludeTrackIds: [String]
    ) async throws -> (tracks: [PoolTrack], metadata: PoolMetadata?) {
        let request = GetCandidatePoolRequest(
            canonicalIntentHash: intentHash,
            platform: platform,
            limit: limit,
            excludeTrackIds: excludeTrackIds.isEmpty ? nil : excludeTrackIds
        )

        let response: GetCandidatePoolResponse = try await supabaseClient.functions
            .invoke(
                "get-candidate-pool",
                options: FunctionInvokeOptions(body: request)
            )

        // Convert response tracks to PoolTrack models
        let tracks = response.tracks.compactMap { $0.toPoolTrack() }

        // Empty poolId means pool doesn't exist
        if response.poolId.isEmpty {
            return (tracks: [], metadata: nil)
        }

        return (tracks: tracks, metadata: response.poolMetadata)
    }

    // MARK: - Save Pool

    func savePool(_ pool: CandidatePool) async throws {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Upsert pool metadata
        let poolData: [String: AnyJSON] = [
            "id": .string(pool.id.uuidString),
            "canonical_intent_hash": .string(pool.canonicalIntentHash),
            "canonical_intent": .string(pool.canonicalIntent),
            "platform": .string(pool.platform.rawValue),
            "track_count": .integer(pool.trackCount),
            "soft_ttl_at": .string(dateFormatter.string(from: pool.softTTLAt)),
            "hard_ttl_at": .string(dateFormatter.string(from: pool.hardTTLAt)),
            "refresh_in_progress": .bool(pool.refreshInProgress),
            "strategies_used": .array(pool.strategiesUsed.map { .string($0) }),
            "strategies_exhausted": .array(pool.strategiesExhausted.map { .string($0) })
        ]

        try await supabaseClient
            .from("candidate_pools")
            .upsert(poolData, onConflict: "canonical_intent_hash,platform")
            .execute()

        // Insert tracks in batches
        if !pool.tracks.isEmpty {
            let batchSize = 100
            for batchStart in stride(from: 0, to: pool.tracks.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, pool.tracks.count)
                let batch = pool.tracks[batchStart..<batchEnd]

                let trackData: [[String: AnyJSON]] = batch.map { track in
                    var data: [String: AnyJSON] = [
                        "pool_id": .string(pool.id.uuidString),
                        "track_id": .string(track.trackId),
                        "artist_id": .string(track.artistId),
                        "source": .string(track.source.rawValue),
                        "serve_count": .integer(track.serveCount)
                    ]

                    if let isrc = track.isrc {
                        data["isrc"] = .string(isrc)
                    }
                    if let sourceDetail = track.sourceDetail {
                        data["source_detail"] = .string(sourceDetail)
                    }

                    return data
                }

                // Use upsert to handle duplicates
                try await supabaseClient
                    .from("candidate_pool_tracks")
                    .upsert(trackData, onConflict: "pool_id,track_id")
                    .execute()
            }
        }
    }

    // MARK: - Refresh Pool (via Edge Function)

    func refreshPool(
        intentHash: String,
        platform: MusicPlatform,
        newTracks: [PoolTrack],
        refreshPercentage: Double
    ) async throws -> RefreshCandidatePoolResponse {
        let requestTracks = newTracks.map { track in
            RefreshCandidatePoolRequest.NewPoolTrack(
                trackId: track.trackId,
                artistId: track.artistId,
                isrc: track.isrc,
                source: track.source,
                sourceDetail: track.sourceDetail
            )
        }

        let request = RefreshCandidatePoolRequest(
            canonicalIntentHash: intentHash,
            platform: platform,
            refreshPercentage: refreshPercentage,
            newTracks: requestTracks.isEmpty ? nil : requestTracks
        )

        let response: RefreshCandidatePoolResponse = try await supabaseClient.functions
            .invoke(
                "refresh-candidate-pool",
                options: FunctionInvokeOptions(body: request)
            )

        return response
    }

    // MARK: - Record Track Served

    func recordTrackServed(poolId: UUID, trackIds: [String]) async throws {
        // Update serve_count and last_served_at for selected tracks
        let now = ISO8601DateFormatter().string(from: Date())

        for trackId in trackIds {
            try await supabaseClient
                .from("candidate_pool_tracks")
                .update([
                    "serve_count": AnyJSON.string("serve_count + 1"),  // Will be interpreted as SQL
                    "last_served_at": AnyJSON.string(now)
                ])
                .eq("pool_id", value: poolId.uuidString)
                .eq("track_id", value: trackId)
                .execute()
        }
    }
}

// MARK: - Database Row Types

private struct PoolRow: Codable {
    let id: String
    let canonicalIntentHash: String
    let canonicalIntent: String
    let platform: String
    let trackCount: Int
    let createdAt: String
    let updatedAt: String
    let softTtlAt: String
    let hardTtlAt: String
    let refreshInProgress: Bool
    let strategiesUsed: [String]
    let strategiesExhausted: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalIntentHash = "canonical_intent_hash"
        case canonicalIntent = "canonical_intent"
        case platform
        case trackCount = "track_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case softTtlAt = "soft_ttl_at"
        case hardTtlAt = "hard_ttl_at"
        case refreshInProgress = "refresh_in_progress"
        case strategiesUsed = "strategies_used"
        case strategiesExhausted = "strategies_exhausted"
    }

    func toCandidatePool(tracks: [PoolTrack]) -> CandidatePool? {
        guard let poolId = UUID(uuidString: id),
              let platform = MusicPlatform(rawValue: platform) else {
            return nil
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return CandidatePool(
            id: poolId,
            canonicalIntentHash: canonicalIntentHash,
            canonicalIntent: canonicalIntent,
            platform: platform,
            tracks: tracks,
            createdAt: dateFormatter.date(from: createdAt) ?? Date(),
            updatedAt: dateFormatter.date(from: updatedAt) ?? Date(),
            softTTLAt: dateFormatter.date(from: softTtlAt),
            hardTTLAt: dateFormatter.date(from: hardTtlAt),
            refreshInProgress: refreshInProgress,
            strategiesUsed: strategiesUsed,
            strategiesExhausted: strategiesExhausted
        )
    }
}

private struct PoolTrackRow: Codable {
    let id: String
    let poolId: String
    let trackId: String
    let artistId: String
    let isrc: String?
    let source: String
    let sourceDetail: String?
    let addedAt: String
    let lastServedAt: String?
    let serveCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case poolId = "pool_id"
        case trackId = "track_id"
        case artistId = "artist_id"
        case isrc
        case source
        case sourceDetail = "source_detail"
        case addedAt = "added_at"
        case lastServedAt = "last_served_at"
        case serveCount = "serve_count"
    }

    func toPoolTrack() -> PoolTrack {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return PoolTrack(
            id: UUID(uuidString: id) ?? UUID(),
            trackId: trackId,
            artistId: artistId,
            isrc: isrc,
            source: TrackSource(rawValue: source) ?? .playlist,
            sourceDetail: sourceDetail,
            addedAt: dateFormatter.date(from: addedAt) ?? Date(),
            lastServedAt: lastServedAt.flatMap { dateFormatter.date(from: $0) },
            serveCount: serveCount
        )
    }
}

// MARK: - Mock Implementation for Testing

final class MockCandidatePoolRepository: CandidatePoolRepositoryProtocol {

    var pools: [String: CandidatePool] = [:]
    var getPoolCallCount = 0
    var savePoolCallCount = 0
    var refreshPoolCallCount = 0

    func getPool(intentHash: String, platform: MusicPlatform) async throws -> CandidatePool? {
        getPoolCallCount += 1
        return pools["\(intentHash)_\(platform.rawValue)"]
    }

    func getPoolTracks(
        intentHash: String,
        platform: MusicPlatform,
        limit: Int,
        excludeTrackIds: [String]
    ) async throws -> (tracks: [PoolTrack], metadata: PoolMetadata?) {
        guard let pool = pools["\(intentHash)_\(platform.rawValue)"] else {
            return (tracks: [], metadata: nil)
        }

        let excludeSet = Set(excludeTrackIds)
        let filteredTracks = pool.tracks
            .filter { !excludeSet.contains($0.trackId) }
            .prefix(limit)

        let metadata = PoolMetadata(
            trackCount: pool.trackCount,
            isStale: pool.isStale,
            needsRefresh: pool.needsRefresh,
            strategiesExhausted: pool.strategiesExhausted
        )

        return (tracks: Array(filteredTracks), metadata: metadata)
    }

    func savePool(_ pool: CandidatePool) async throws {
        savePoolCallCount += 1
        pools["\(pool.canonicalIntentHash)_\(pool.platform.rawValue)"] = pool
    }

    func refreshPool(
        intentHash: String,
        platform: MusicPlatform,
        newTracks: [PoolTrack],
        refreshPercentage: Double
    ) async throws -> RefreshCandidatePoolResponse {
        refreshPoolCallCount += 1

        let key = "\(intentHash)_\(platform.rawValue)"
        if var pool = pools[key] {
            pool.tracks.append(contentsOf: newTracks)
            pools[key] = pool

            return RefreshCandidatePoolResponse(
                success: true,
                poolId: pool.id.uuidString,
                tracksAdded: newTracks.count,
                tracksEvicted: 0,
                newTrackCount: pool.tracks.count
            )
        }

        return RefreshCandidatePoolResponse(
            success: false,
            poolId: "",
            tracksAdded: 0,
            tracksEvicted: 0,
            newTrackCount: 0
        )
    }

    func recordTrackServed(poolId: UUID, trackIds: [String]) async throws {
        // No-op for mock
    }
}
