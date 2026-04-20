//
//  TrackRepository.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation
import Supabase

// MARK: - Track Repository Protocol
protocol TrackRepositoryProtocol {
    /// Fetch a track by ISRC
    func getTrack(byISRC isrc: String) async throws -> Track?
    
    /// Fetch tracks matching filter criteria for candidate pool
    func getCandidates(
        seedFeatures: TrackFeatures?,
        bpmRange: ClosedRange<Float>?,
        energyRange: ClosedRange<Float>?,
        genres: [String]?,
        decades: [Int]?,
        excludeISRCs: [String],
        limit: Int
    ) async throws -> [Track]
    
    /// Fetch all tracks (for small datasets during development)
    func getAllTracks() async throws -> [Track]
    
    /// Get a random sample of tracks
    func getRandomTracks(limit: Int, excludeISRCs: [String]) async throws -> [Track]
}

// MARK: - Supabase Implementation
final class SupabaseTrackRepository: TrackRepositoryProtocol {
    private let client: SupabaseClient
    
    init(client: SupabaseClient = SupabaseConfig.client) {
        self.client = client
    }
    
    func getTrack(byISRC isrc: String) async throws -> Track? {
        let response: [Track] = try await client
            .from("tracks")
            .select()
            .eq("isrc", value: isrc)
            .limit(1)
            .execute()
            .value
        
        return response.first
    }
    
    func getCandidates(
        seedFeatures: TrackFeatures?,
        bpmRange: ClosedRange<Float>?,
        energyRange: ClosedRange<Float>?,
        genres: [String]?,
        decades: [Int]?,
        excludeISRCs: [String],
        limit: Int
    ) async throws -> [Track] {
        var query = client
            .from("tracks")
            .select()
        
        // Apply BPM range filter
        if let bpmRange = bpmRange {
            // Convert normalized BPM back to actual BPM (60-200 range)
            let minBPM = Double(60 + bpmRange.lowerBound * 140)
            let maxBPM = Double(60 + bpmRange.upperBound * 140)
            query = query
                .gte("bpm", value: minBPM)
                .lte("bpm", value: maxBPM)
        }
        
        // Apply energy range filter
        if let energyRange = energyRange {
            query = query
                .gte("energy", value: Double(energyRange.lowerBound))
                .lte("energy", value: Double(energyRange.upperBound))
        }
        
        // Apply genre filter (if specified)
        if let genres = genres, !genres.isEmpty {
            // Use IN filter for multiple genres
            query = query.in("genre", values: genres)
        }
        
        // Note: Decade filtering would need to be done client-side
        // since release_date is a date string
        
        // Exclude recently played tracks
        if !excludeISRCs.isEmpty {
            // Supabase doesn't have a direct "NOT IN" for arrays,
            // so we'll filter this client-side for now
        }
        
        // Only get tracks with audio features
        query = query.not("bpm", operator: .is, value: "null")
        
        let allTracks: [Track] = try await query
            .limit(limit * 2)  // Fetch extra to allow for client-side filtering
            .execute()
            .value
        
        // Client-side filtering
        var filtered = allTracks.filter { track in
            // Exclude recently played
            guard !excludeISRCs.contains(track.isrc) else { return false }
            
            // Filter by decade if specified
            if let decades = decades, !decades.isEmpty {
                guard let trackDecade = track.decade,
                      decades.contains(trackDecade) else {
                    return false
                }
            }
            
            return true
        }
        
        // If we have seed features, sort by similarity
        if let seedFeatures = seedFeatures {
            filtered.sort { track1, track2 in
                let sim1 = track1.featureVector().similarity(to: seedFeatures)
                let sim2 = track2.featureVector().similarity(to: seedFeatures)
                return sim1 > sim2
            }
        }
        
        return Array(filtered.prefix(limit))
    }
    
    func getAllTracks() async throws -> [Track] {
        let response: [Track] = try await client
            .from("tracks")
            .select()
            .not("bpm", operator: .is, value: "null")  // Only tracks with features
            .execute()
            .value
        
        return response
    }
    
    func getRandomTracks(limit: Int, excludeISRCs: [String]) async throws -> [Track] {
        // Supabase doesn't have native random ordering,
        // so we fetch more and shuffle client-side
        let allTracks: [Track] = try await client
            .from("tracks")
            .select()
            .not("bpm", operator: .is, value: "null")
            .limit(limit * 3)
            .execute()
            .value
        
        let filtered = allTracks.filter { !excludeISRCs.contains($0.isrc) }
        let shuffled = filtered.shuffled()
        
        return Array(shuffled.prefix(limit))
    }
}

// MARK: - Mock Implementation (for testing without Supabase)
final class MockTrackRepository: TrackRepositoryProtocol {
    private var tracks: [Track] = []
    
    init(tracks: [Track] = []) {
        self.tracks = tracks.isEmpty ? Self.generateMockTracks() : tracks
    }
    
    func getTrack(byISRC isrc: String) async throws -> Track? {
        tracks.first { $0.isrc == isrc }
    }
    
    func getCandidates(
        seedFeatures: TrackFeatures?,
        bpmRange: ClosedRange<Float>?,
        energyRange: ClosedRange<Float>?,
        genres: [String]?,
        decades: [Int]?,
        excludeISRCs: [String],
        limit: Int
    ) async throws -> [Track] {
        var filtered = tracks.filter { track in
            guard !excludeISRCs.contains(track.isrc) else { return false }
            guard track.hasAudioFeatures else { return false }
            
            if let bpmRange = bpmRange, let bpm = track.bpm {
                let normalizedBPM = (bpm - 60) / 140
                guard bpmRange.contains(normalizedBPM) else { return false }
            }
            
            if let energyRange = energyRange, let energy = track.energy {
                guard energyRange.contains(energy) else { return false }
            }
            
            if let genres = genres, !genres.isEmpty, let genre = track.genre {
                guard genres.contains(genre) else { return false }
            }
            
            if let decades = decades, !decades.isEmpty {
                guard let trackDecade = track.decade,
                      decades.contains(trackDecade) else { return false }
            }
            
            return true
        }
        
        if let seedFeatures = seedFeatures {
            filtered.sort { track1, track2 in
                let sim1 = track1.featureVector().similarity(to: seedFeatures)
                let sim2 = track2.featureVector().similarity(to: seedFeatures)
                return sim1 > sim2
            }
        }
        
        return Array(filtered.prefix(limit))
    }
    
    func getAllTracks() async throws -> [Track] {
        tracks.filter { $0.hasAudioFeatures }
    }
    
    func getRandomTracks(limit: Int, excludeISRCs: [String]) async throws -> [Track] {
        let filtered = tracks.filter { !excludeISRCs.contains($0.isrc) && $0.hasAudioFeatures }
        return Array(filtered.shuffled().prefix(limit))
    }
    
    // MARK: - Mock Data Generation
    static func generateMockTracks(count: Int = 100) -> [Track] {
        let genres = ["pop", "rock", "hip-hop", "electronic", "r&b", "indie", "jazz", "classical"]
        let decades = [1980, 1990, 2000, 2010, 2020]
        
        return (0..<count).map { i in
            Track(
                id: UUID(),
                isrc: "MOCK\(String(format: "%08d", i))",
                spotifyId: "spotify_\(i)",
                appleMusicId: "apple_\(i)",
                reccobeatsId: "recco_\(i)",
                title: "Mock Song \(i + 1)",
                artistName: "Mock Artist \(i % 20 + 1)",
                albumName: "Mock Album \(i % 10 + 1)",
                durationMs: Int.random(in: 180000...300000),
                releaseDate: "\(decades.randomElement()!)-\(String(format: "%02d", Int.random(in: 1...12)))-\(String(format: "%02d", Int.random(in: 1...28)))",
                genre: genres.randomElement(),
                hasLyrics: Bool.random(),
                bpm: Float.random(in: 70...180),
                energy: Float.random(in: 0...1),
                danceability: Float.random(in: 0...1),
                valence: Float.random(in: 0...1),
                acousticness: Float.random(in: 0...1),
                instrumentalness: Float.random(in: 0...0.5),
                liveness: Float.random(in: 0...0.3),
                speechiness: Float.random(in: 0...0.3),
                loudness: Float.random(in: -20...0),
                key: Int.random(in: 0...11),
                mode: Int.random(in: 0...1),
                attributesFetchedAt: ISO8601DateFormatter().string(from: Date()),
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
        }
    }
}
