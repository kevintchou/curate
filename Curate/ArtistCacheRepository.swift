//
//  ArtistCacheRepository.swift
//  Curate
//
//  Supabase operations for global artist cache.
//  This cache is shared across all users to reduce API calls.
//

import Foundation
import Supabase

// MARK: - Artist Cache Repository

final class ArtistCacheRepository: ArtistCacheRepositoryProtocol {
    private let supabase: SupabaseClient

    init(supabase: SupabaseClient = SupabaseConfig.client) {
        self.supabase = supabase
    }

    // MARK: - Get Cached Artist

    func getCachedArtist(canonicalId: String) async throws -> CachedArtist? {
        let response: [CachedArtistRow] = try await supabase
            .from("artist_cache")
            .select()
            .eq("canonical_id", value: canonicalId)
            .limit(1)
            .execute()
            .value

        guard let row = response.first else {
            return nil
        }

        let cached = row.toCachedArtist()

        // Return nil if expired (caller should refresh)
        if cached.isExpired {
            return nil
        }

        return cached
    }

    // MARK: - Get Multiple Cached Artists

    func getCachedArtists(canonicalIds: [String]) async throws -> [CachedArtist] {
        guard !canonicalIds.isEmpty else { return [] }

        let response: [CachedArtistRow] = try await supabase
            .from("artist_cache")
            .select()
            .in("canonical_id", values: canonicalIds)
            .execute()
            .value

        let now = Date()
        return response
            .map { $0.toCachedArtist() }
            .filter { $0.expiresAt > now }  // Filter out expired
    }

    // MARK: - Cache Artist

    func cacheArtist(_ artist: ResolvedArtist, topTrackIds: [String]) async throws {
        let insert = ArtistCacheInsert(
            canonicalId: artist.id,
            name: artist.name,
            providerType: artist.providerType.rawValue,
            genres: artist.genres,
            imageUrl: artist.imageURL?.absoluteString,
            topTrackIds: topTrackIds,
            cachedAt: Date(),
            expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        )

        // Upsert: insert or update if exists
        try await supabase
            .from("artist_cache")
            .upsert(insert, onConflict: "canonical_id")
            .execute()
    }

    // MARK: - Cleanup Expired

    func cleanupExpired() async throws {
        try await supabase
            .from("artist_cache")
            .delete()
            .lt("expires_at", value: ISO8601DateFormatter().string(from: Date()))
            .execute()
    }
}

// MARK: - Database Row Types

private struct ArtistCacheInsert: Encodable {
    let canonicalId: String
    let name: String
    let providerType: String
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
}

private struct CachedArtistRow: Decodable {
    let canonicalId: String
    let name: String
    let providerType: String
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

    func toCachedArtist() -> CachedArtist {
        CachedArtist(
            canonicalId: canonicalId,
            name: name,
            providerType: MusicProviderType(rawValue: providerType) ?? .appleMusic,
            genres: genres,
            imageUrl: imageUrl,
            topTrackIds: topTrackIds,
            cachedAt: cachedAt,
            expiresAt: expiresAt
        )
    }
}
