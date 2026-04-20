//
//  SeedCacheRepository.swift
//  Curate
//
//  Supabase operations for per-user seed cache.
//  Caches LLM-generated artist seeds for 24 hours.
//

import Foundation
import Supabase

// MARK: - Seed Cache Repository

final class SeedCacheRepository: SeedCacheRepositoryProtocol {
    private let supabase: SupabaseClient

    init(supabase: SupabaseClient = SupabaseConfig.client) {
        self.supabase = supabase
    }

    // MARK: - Get Cached Seeds

    func getCachedSeeds(
        userId: UUID,
        configHash: String,
        tasteHash: String
    ) async throws -> [ArtistSeed]? {
        let response: [SeedCacheRow] = try await supabase
            .from("seed_cache")
            .select()
            .eq("user_id", value: userId.uuidString)
            .eq("station_config_hash", value: configHash)
            .eq("taste_hash", value: tasteHash)
            .limit(1)
            .execute()
            .value

        guard let row = response.first else {
            return nil
        }

        // Check if expired
        if row.expiresAt < Date() {
            return nil
        }

        // Decode seeds from JSON
        guard let data = row.seedsJson.data(using: .utf8) else {
            return nil
        }

        return try JSONDecoder().decode([ArtistSeed].self, from: data)
    }

    // MARK: - Cache Seeds

    func cacheSeeds(
        userId: UUID,
        configHash: String,
        tasteHash: String,
        seeds: [ArtistSeed]
    ) async throws {
        let seedsJson = try JSONEncoder().encode(seeds)
        guard let seedsString = String(data: seedsJson, encoding: .utf8) else {
            throw MusicProviderError.invalidData("Failed to encode seeds to JSON")
        }

        let insert = SeedCacheInsert(
            userId: userId,
            stationConfigHash: configHash,
            tasteHash: tasteHash,
            seedsJson: seedsString,
            cachedAt: Date(),
            expiresAt: Calendar.current.date(byAdding: .hour, value: 24, to: Date()) ?? Date()
        )

        // Upsert: insert or update if exists
        try await supabase
            .from("seed_cache")
            .upsert(insert, onConflict: "user_id,station_config_hash,taste_hash")
            .execute()
    }

    // MARK: - Invalidate User Cache

    func invalidateUserCache(userId: UUID) async throws {
        try await supabase
            .from("seed_cache")
            .delete()
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    // MARK: - Cleanup Expired

    func cleanupExpired() async throws {
        try await supabase
            .from("seed_cache")
            .delete()
            .lt("expires_at", value: ISO8601DateFormatter().string(from: Date()))
            .execute()
    }
}

// MARK: - Database Row Types

private struct SeedCacheInsert: Encodable {
    let userId: UUID
    let stationConfigHash: String
    let tasteHash: String
    let seedsJson: String
    let cachedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case stationConfigHash = "station_config_hash"
        case tasteHash = "taste_hash"
        case seedsJson = "seeds_json"
        case cachedAt = "cached_at"
        case expiresAt = "expires_at"
    }
}

private struct SeedCacheRow: Decodable {
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
}

