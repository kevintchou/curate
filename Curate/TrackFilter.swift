//
//  TrackFilter.swift
//  Curate
//
//  Local filtering logic for track recommendations.
//  Ensures diversity, avoids recently played, and respects user preferences.
//

import Foundation

// MARK: - Track Filter

final class TrackFilter: TrackFilterProtocol {

    // MARK: - Filter Implementation

    func filter(
        tracks: [ProviderTrack],
        context: TrackFilterContext,
        targetCount: Int
    ) -> [ProviderTrack] {
        guard !tracks.isEmpty else { return [] }

        // Step 1: Remove recently played tracks
        var filteredTracks = removeRecentlyPlayed(tracks, context: context)

        // Step 2: Score and sort tracks
        let scoredTracks = filteredTracks.map { track in
            (track: track, score: scoreTrack(track, context: context))
        }.sorted { $0.score > $1.score }

        // Step 3: Apply diversity constraints (max per artist)
        filteredTracks = applyDiversityConstraints(
            scoredTracks.map { $0.track },
            maxPerArtist: context.maxTracksPerArtist
        )

        // Step 4: Return target count
        return Array(filteredTracks.prefix(targetCount))
    }

    // MARK: - Remove Recently Played

    private func removeRecentlyPlayed(
        _ tracks: [ProviderTrack],
        context: TrackFilterContext
    ) -> [ProviderTrack] {
        tracks.filter { track in
            // Check ISRC first (more reliable)
            if let isrc = track.isrc, context.recentlyPlayedISRCs.contains(isrc) {
                return false
            }

            // Fallback to track ID
            if context.recentlyPlayedIds.contains(track.id) {
                return false
            }

            return true
        }
    }

    // MARK: - Score Track

    /// Score a track based on artist preference history
    /// Higher score = more likely to be selected
    private func scoreTrack(_ track: ProviderTrack, context: TrackFilterContext) -> Double {
        var score = 1.0  // Base score

        // Apply artist preference boost/penalty
        let normalizedArtistName = track.artistName.lowercased()
        if let artistScore = context.artistScores[normalizedArtistName] {
            // weightedScore ranges from ~-10 to +10 typically
            // Map to a multiplier: -5 -> 0.1x, 0 -> 1x, +5 -> 2x
            let multiplier = max(0.1, min(3.0, 1.0 + (artistScore.weightedScore / 5.0)))
            score *= multiplier

            // Strong penalty for disliked artists
            if artistScore.shouldAvoid {
                score *= 0.1
            }

            // Mild recency penalty (don't repeat artists too soon)
            if let lastPlayed = artistScore.lastPlayedAt {
                let daysSinceLastPlayed = Calendar.current.dateComponents(
                    [.day],
                    from: lastPlayed,
                    to: Date()
                ).day ?? 0

                // Penalty decays over 7 days
                if daysSinceLastPlayed < 7 {
                    let recencyPenalty = 1.0 - Double(7 - daysSinceLastPlayed) / 14.0
                    score *= recencyPenalty
                }
            }
        }

        // Add small random factor for variety (±10%)
        let randomFactor = Double.random(in: 0.9...1.1)
        score *= randomFactor

        return score
    }

    // MARK: - Diversity Constraints

    /// Limit tracks per artist to ensure variety
    private func applyDiversityConstraints(
        _ tracks: [ProviderTrack],
        maxPerArtist: Int
    ) -> [ProviderTrack] {
        var result: [ProviderTrack] = []
        var artistCounts: [String: Int] = [:]

        for track in tracks {
            let normalizedArtist = track.artistName.lowercased()
            let currentCount = artistCounts[normalizedArtist] ?? 0

            if currentCount < maxPerArtist {
                result.append(track)
                artistCounts[normalizedArtist] = currentCount + 1
            }
        }

        return result
    }
}

// MARK: - Track Filter Context Builder

extension TrackFilterContext {
    /// Create context from repository data
    static func build(
        recentlyPlayedISRCs: [String],
        recentlyPlayedIds: [String],
        artistScores: [ArtistScore],
        maxTracksPerArtist: Int = 2,
        recencyWindowDays: Int = 45,
        stationId: UUID? = nil
    ) -> TrackFilterContext {
        // Convert artist scores array to dictionary keyed by lowercase name
        let scoresDict = Dictionary(
            artistScores.map { ($0.artistName.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return TrackFilterContext(
            recentlyPlayedISRCs: Set(recentlyPlayedISRCs),
            recentlyPlayedIds: Set(recentlyPlayedIds),
            artistScores: scoresDict,
            maxTracksPerArtist: maxTracksPerArtist,
            recencyWindowDays: recencyWindowDays,
            stationId: stationId
        )
    }
}

// MARK: - Shuffle Extension

extension Array {
    /// Shuffle while maintaining relative order of high-scored items
    func weightedShuffle<T: Comparable>(by keyPath: KeyPath<Element, T>) -> [Element] {
        // Group into buckets and shuffle within buckets
        let sorted = self.sorted { $0[keyPath: keyPath] > $1[keyPath: keyPath] }
        let bucketSize = Swift.max(3, count / 5)  // ~5 buckets

        var result: [Element] = []
        for i in stride(from: 0, to: count, by: bucketSize) {
            let end = Swift.min(i + bucketSize, count)
            var bucket = Array(sorted[i..<end])
            bucket.shuffle()
            result.append(contentsOf: bucket)
        }

        return result
    }
}
