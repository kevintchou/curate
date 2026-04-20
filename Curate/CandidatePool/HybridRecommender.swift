//
//  HybridRecommender.swift
//  Curate
//
//  Deterministic track selection from candidate pools.
//  Replaces the Thompson Sampling-based RecommendationEngine.
//
//  Selection Flow:
//  1. Hard filter (no repeats, no disliked artists)
//  2. Bucketize by source/familiarity
//  3. Choose bucket based on policy + exploration weight
//  4. Score tracks (freshness, balance, randomness)
//  5. Select via weighted random from top-K
//

import Foundation

// MARK: - Protocol

protocol HybridRecommenderProtocol {
    /// Select tracks from a pool with user overlay applied
    func selectTracks(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>,
        count: Int
    ) -> [PoolTrack]

    /// Select tracks with detailed result diagnostics
    func selectTracksWithResult(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>,
        count: Int
    ) -> TrackSelectionResult

    /// Record a track play and update overlay
    func recordPlay(
        track: PoolTrack,
        overlay: inout UserStationOverlay
    )

    /// Record a skip and update overlay
    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    )
}

// MARK: - Implementation

final class HybridRecommender: HybridRecommenderProtocol {

    // MARK: - Track Selection

    func selectTracks(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>,
        count: Int
    ) -> [PoolTrack] {
        // Step 1: Hard filter
        var candidates = hardFilter(
            pool.tracks,
            overlay: userOverlay,
            policy: policy,
            dislikedArtistIds: dislikedArtistIds
        )

        guard !candidates.isEmpty else {
            return []
        }

        // Step 2: Bucketize by source
        let buckets = bucketize(candidates)

        // Step 3 & 4: Select tracks using bucket-based selection
        var selected: [PoolTrack] = []
        var usedTrackIds = Set(userOverlay.recentTrackIds)
        var recentArtistsInBatch: [String] = []

        for _ in 0..<count {
            // Choose a bucket based on policy ratios and exploration
            let bucket = chooseBucket(
                buckets: buckets,
                policy: policy,
                explorationWeight: userOverlay.currentExplorationWeight,
                usedTrackIds: usedTrackIds
            )

            guard !bucket.isEmpty else { continue }

            // Score tracks in the bucket
            let scored = scoreTracksInBucket(
                bucket,
                usedTrackIds: usedTrackIds,
                recentArtistsInBatch: recentArtistsInBatch,
                overlay: userOverlay,
                policy: policy
            )

            // Weighted random selection from top-K
            if let selectedTrack = weightedRandomSelect(from: scored, topK: 5) {
                selected.append(selectedTrack)
                usedTrackIds.insert(selectedTrack.trackId)
                recentArtistsInBatch.append(selectedTrack.artistId)
            }
        }

        return selected
    }

    // MARK: - Hard Filter

    private func hardFilter(
        _ tracks: [PoolTrack],
        overlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>
    ) -> [PoolTrack] {
        let recentTrackSet = Set(overlay.recentTrackIds.suffix(policy.trackRepeatWindow))
        let recentISRCSet = Set(overlay.recentTrackISRCs.suffix(policy.trackRepeatWindow))

        return tracks.filter { track in
            // No recent track repeats
            if recentTrackSet.contains(track.trackId) { return false }

            // No ISRC repeats (cross-platform dedup)
            if let isrc = track.isrc, recentISRCSet.contains(isrc) { return false }

            // No disliked artists
            if dislikedArtistIds.contains(track.artistId) { return false }

            return true
        }
    }

    // MARK: - Bucketization

    private func bucketize(_ tracks: [PoolTrack]) -> [TrackSource: [PoolTrack]] {
        Dictionary(grouping: tracks, by: \.source)
    }

    // MARK: - Bucket Selection

    private func chooseBucket(
        buckets: [TrackSource: [PoolTrack]],
        policy: StationPolicy,
        explorationWeight: Double,
        usedTrackIds: Set<String>
    ) -> [PoolTrack] {
        // Calculate effective ratios based on exploration weight
        var ratios: [TrackSource: Double] = [
            .playlist: policy.playlistSourceRatio,
            .search: policy.searchSourceRatio,
            .artistSeed: policy.artistSeedSourceRatio,
            .relatedArtist: policy.artistSeedSourceRatio * 0.5
        ]

        // Adjust for exploration (boost search/discovery when exploring)
        let baseExploration = policy.baseExplorationWeight
        let explorationDelta = explorationWeight - baseExploration

        // Higher exploration = more variety from search and discovery sources
        ratios[.search] = (ratios[.search] ?? 0) + explorationDelta * 0.2
        ratios[.playlist] = (ratios[.playlist] ?? 0) - explorationDelta * 0.1
        ratios[.relatedArtist] = (ratios[.relatedArtist] ?? 0) + explorationDelta * 0.1

        // Filter to only buckets that have available tracks
        let availableBuckets = buckets.filter { source, tracks in
            !tracks.filter { !usedTrackIds.contains($0.trackId) }.isEmpty
        }

        guard !availableBuckets.isEmpty else {
            // Fallback to any non-empty bucket
            return buckets.max(by: { $0.value.count < $1.value.count })?.value ?? []
        }

        // Adjust ratios to only available buckets
        let availableRatios = ratios.filter { availableBuckets.keys.contains($0.key) }
        let total = availableRatios.values.reduce(0, +)

        guard total > 0 else {
            return availableBuckets.first?.value ?? []
        }

        // Normalize and do weighted random selection
        let normalizedRatios = availableRatios.mapValues { $0 / total }
        let rand = Double.random(in: 0...1)
        var cumulative = 0.0

        for (source, ratio) in normalizedRatios.sorted(by: { $0.value > $1.value }) {
            cumulative += ratio
            if rand <= cumulative, let bucket = availableBuckets[source] {
                return bucket
            }
        }

        // Fallback
        return availableBuckets.first?.value ?? []
    }

    // MARK: - Track Scoring

    private func scoreTracksInBucket(
        _ bucket: [PoolTrack],
        usedTrackIds: Set<String>,
        recentArtistsInBatch: [String],
        overlay: UserStationOverlay,
        policy: StationPolicy
    ) -> [(PoolTrack, Double)] {
        bucket.compactMap { track -> (PoolTrack, Double)? in
            // Skip already used tracks
            guard !usedTrackIds.contains(track.trackId) else { return nil }

            // Enforce artist repeat window within session
            let recentArtistWindow = overlay.recentArtistIds.suffix(policy.artistRepeatWindow)
            if recentArtistWindow.contains(track.artistId) { return nil }

            // Also avoid same artist within current batch
            if recentArtistsInBatch.contains(track.artistId) { return nil }

            let score = scoreTrack(track, recentArtistsInBatch: recentArtistsInBatch)
            return (track, score)
        }
    }

    private func scoreTrack(_ track: PoolTrack, recentArtistsInBatch: [String]) -> Double {
        var score = 1.0

        // Freshness boost (newer tracks slightly preferred)
        let ageHours = Date().timeIntervalSince(track.addedAt) / 3600
        let freshnessBoost = max(0.8, 1.0 - (ageHours / 168))  // Decay over 1 week
        score *= freshnessBoost

        // Serve count penalty (favor less-served tracks for variety)
        let serveCountPenalty = max(0.5, 1.0 - Double(track.serveCount) * 0.03)
        score *= serveCountPenalty

        // Source quality bonus
        switch track.source {
        case .playlist:
            score *= 1.1  // Editorial playlists are high quality
        case .search:
            score *= 1.0
        case .artistSeed:
            score *= 0.95  // Slightly lower for fallback sources
        case .relatedArtist:
            score *= 0.90
        }

        // Artist diversity within batch
        let artistCountInBatch = recentArtistsInBatch.filter { $0 == track.artistId }.count
        if artistCountInBatch > 0 {
            score *= 0.3  // Heavy penalty for same artist in same batch
        }

        // Random factor for variety (±10%)
        score *= Double.random(in: 0.9...1.1)

        return max(0.01, score)  // Ensure positive score
    }

    // MARK: - Weighted Random Selection

    private func weightedRandomSelect(
        from scored: [(PoolTrack, Double)],
        topK: Int
    ) -> PoolTrack? {
        guard !scored.isEmpty else { return nil }

        // Take top K candidates
        let topCandidates = scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)

        guard !topCandidates.isEmpty else { return nil }

        // Weighted random from top K
        let totalWeight = topCandidates.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return topCandidates.first?.0 }

        let rand = Double.random(in: 0...totalWeight)
        var cumulative = 0.0

        for (track, weight) in topCandidates {
            cumulative += weight
            if rand <= cumulative {
                return track
            }
        }

        return topCandidates.first?.0
    }

    // MARK: - Feedback Recording

    func recordPlay(track: PoolTrack, overlay: inout UserStationOverlay) {
        overlay.recordPlay(track: track)
    }

    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    ) {
        overlay.recordSkip(trackId: track.trackId, policy: policy)
    }
}

// MARK: - Selection Result

/// Result of track selection with diagnostics
struct TrackSelectionResult {
    let tracks: [PoolTrack]
    let poolSize: Int
    let candidatesAfterFilter: Int
    let sourceMix: [TrackSource: Int]
    let needsMoreTracks: Bool

    var summary: String {
        let sourceDesc = sourceMix
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue): \($0.value)" }
            .joined(separator: ", ")

        return "Selected \(tracks.count) tracks from pool of \(poolSize) " +
               "(\(candidatesAfterFilter) after filter). Sources: \(sourceDesc)"
    }
}

// MARK: - Recommender Extensions

extension HybridRecommender {
    /// Select tracks with detailed result
    func selectTracksWithResult(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>,
        count: Int
    ) -> TrackSelectionResult {
        let candidates = hardFilter(
            pool.tracks,
            overlay: userOverlay,
            policy: policy,
            dislikedArtistIds: dislikedArtistIds
        )

        let tracks = selectTracks(
            from: pool,
            userOverlay: userOverlay,
            policy: policy,
            dislikedArtistIds: dislikedArtistIds,
            count: count
        )

        let sourceMix = Dictionary(grouping: tracks, by: \.source)
            .mapValues { $0.count }

        return TrackSelectionResult(
            tracks: tracks,
            poolSize: pool.tracks.count,
            candidatesAfterFilter: candidates.count,
            sourceMix: sourceMix,
            needsMoreTracks: candidates.count < policy.minPoolSizeForPrimary
        )
    }
}

// MARK: - Mock Implementation for Testing

final class MockHybridRecommender: HybridRecommenderProtocol {

    var selectTracksCallCount = 0
    var recordPlayCallCount = 0
    var recordSkipCallCount = 0
    var mockTracks: [PoolTrack] = []

    func selectTracks(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>,
        count: Int
    ) -> [PoolTrack] {
        selectTracksCallCount += 1

        if !mockTracks.isEmpty {
            return Array(mockTracks.prefix(count))
        }

        // Return tracks from pool
        return Array(pool.tracks.prefix(count))
    }

    func selectTracksWithResult(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        dislikedArtistIds: Set<String>,
        count: Int
    ) -> TrackSelectionResult {
        let tracks = selectTracks(
            from: pool,
            userOverlay: userOverlay,
            policy: policy,
            dislikedArtistIds: dislikedArtistIds,
            count: count
        )

        let sourceMix = Dictionary(grouping: tracks, by: \.source)
            .mapValues { $0.count }

        return TrackSelectionResult(
            tracks: tracks,
            poolSize: pool.tracks.count,
            candidatesAfterFilter: pool.tracks.count,
            sourceMix: sourceMix,
            needsMoreTracks: false
        )
    }

    func recordPlay(track: PoolTrack, overlay: inout UserStationOverlay) {
        recordPlayCallCount += 1
        overlay.recordPlay(track: track)
    }

    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    ) {
        recordSkipCallCount += 1
        overlay.recordSkip(trackId: track.trackId, policy: policy)
    }
}
