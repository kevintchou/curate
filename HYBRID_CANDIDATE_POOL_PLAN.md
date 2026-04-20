# Hybrid Candidate Pool Architecture - Implementation Plan

## Overview

This plan introduces a new recommendation system using a hybrid candidate-pool architecture (global pools + per-user overlays) as the primary method, with the existing artist-seed approach as a fallback. The LLM is only used for intent-to-search-plan generation, not for real-time track decisions.

---

## Architecture Summary

```
User Input ("relaxing sunset drive")
       │
       ▼
┌──────────────────────────────────────────────────────┐
│  1. Intent Canonicalization                          │
│     - Hash intent + platform                         │
│     - Check intent_mappings table for known mapping  │
│     - If unknown, LLM generates canonical intent     │
│     - Store new mapping after 3+ occurrences         │
└──────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────┐
│  2. Search Plan Cache                                │
│     - Key: (canonical_intent, platform)              │
│     - TTL: Days (long-term)                          │
│     - Contains: playlist searches, mood categories,  │
│       search terms, expansion strategies, policy     │
└──────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────┐
│  3. Global Candidate Pool                            │
│     - Key: (canonical_intent_hash, platform)         │
│     - Shared across all users                        │
│     - Target: 500 tracks, Max: 1000 tracks           │
│     - Soft TTL: 6h, Hard TTL: 24-48h                 │
│     - Incremental 25% refresh when stale             │
└──────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────┐
│  4. Per-User Overlay (user_station_overlay)          │
│     - Recent tracks played (per station)             │
│     - Skip history + patterns                        │
│     - Disliked artists                               │
│     - Session exploration weight                     │
└──────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────┐
│  5. Recommender Engine (Deterministic)               │
│     - Hard filter (no repeats, no dislikes)          │
│     - Bucketize by source/familiarity                │
│     - Score by freshness, balance, randomness        │
│     - Weighted random selection                      │
│     - Update overlay after play/skip                 │
└──────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────┐
│  6. Playback via Apple Music SDK                     │
└──────────────────────────────────────────────────────┘
```

---

## Phase 1: Database Schema

### 1.1 New Supabase Tables

#### `intent_mappings`
Maps raw prompts to canonical intents. Grows over time as patterns emerge.

```sql
CREATE TABLE intent_mappings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_prompt_hash TEXT NOT NULL,           -- SHA256 of lowercased, trimmed prompt
    raw_prompt TEXT NOT NULL,                -- Original prompt for debugging
    canonical_intent TEXT NOT NULL,          -- e.g., "relaxed-driving-mood"
    mood_categories TEXT[] DEFAULT '{}',     -- e.g., ["chill", "evening", "driving"]
    flavor_tags TEXT[] DEFAULT '{}',         -- e.g., ["sunset", "golden-hour"]
    occurrence_count INTEGER DEFAULT 1,
    platform TEXT NOT NULL,                  -- "apple_music" | "spotify"
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(raw_prompt_hash, platform)
);

CREATE INDEX idx_intent_mappings_canonical ON intent_mappings(canonical_intent, platform);
CREATE INDEX idx_intent_mappings_prompt_hash ON intent_mappings(raw_prompt_hash);
```

#### `search_plan_cache`
Stores LLM-generated search plans per canonical intent.

```sql
CREATE TABLE search_plan_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_intent TEXT NOT NULL,
    platform TEXT NOT NULL,                  -- "apple_music" | "spotify"

    -- Search strategies (JSON arrays)
    playlist_searches JSONB NOT NULL,        -- [{term: "sunset vibes", priority: 1}, ...]
    catalog_searches JSONB DEFAULT '[]',     -- [{term: "chill acoustic", genres: [...]}]
    artist_seed_config JSONB DEFAULT NULL,   -- Fallback config if needed

    -- Mood/activity metadata
    mood_categories TEXT[] DEFAULT '{}',
    activity_tags TEXT[] DEFAULT '{}',

    -- Station policy tweaks (LLM-suggested)
    suggested_exploration_weight FLOAT DEFAULT 0.3,
    suggested_source_mix JSONB DEFAULT '{"playlist": 0.55, "search": 0.25, "artist_seed": 0.20}',

    -- Cache metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,         -- Typically created_at + 7 days
    refresh_count INTEGER DEFAULT 0,

    UNIQUE(canonical_intent, platform)
);

CREATE INDEX idx_search_plan_canonical ON search_plan_cache(canonical_intent, platform);
```

#### `candidate_pools`
Global shared candidate pools per intent.

```sql
CREATE TABLE candidate_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_intent_hash TEXT NOT NULL,     -- SHA256 of canonical_intent
    canonical_intent TEXT NOT NULL,          -- Human-readable for debugging
    platform TEXT NOT NULL,

    -- Pool metadata
    track_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    soft_ttl_at TIMESTAMPTZ NOT NULL,        -- created_at + 6 hours
    hard_ttl_at TIMESTAMPTZ NOT NULL,        -- created_at + 24-48 hours

    -- Refresh tracking
    last_refresh_at TIMESTAMPTZ,
    refresh_in_progress BOOLEAN DEFAULT FALSE,
    strategies_used TEXT[] DEFAULT '{}',     -- Track which strategies populated this
    strategies_exhausted TEXT[] DEFAULT '{}', -- Strategies with no more results

    UNIQUE(canonical_intent_hash, platform)
);

CREATE INDEX idx_candidate_pools_hash ON candidate_pools(canonical_intent_hash, platform);
CREATE INDEX idx_candidate_pools_ttl ON candidate_pools(soft_ttl_at);
```

#### `candidate_pool_tracks`
Individual tracks in candidate pools.

```sql
CREATE TABLE candidate_pool_tracks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pool_id UUID NOT NULL REFERENCES candidate_pools(id) ON DELETE CASCADE,

    -- Track identifiers
    track_id TEXT NOT NULL,                  -- Platform-specific ID (Apple Music catalog ID)
    artist_id TEXT NOT NULL,                 -- Platform-specific artist ID
    isrc TEXT,                               -- For cross-platform deduplication

    -- Source tracking
    source TEXT NOT NULL,                    -- "playlist" | "search" | "artist_seed" | "related_artist"
    source_detail TEXT,                      -- e.g., "playlist:sunset-vibes-2024" or "search:chill+acoustic"

    -- Lifecycle
    added_at TIMESTAMPTZ DEFAULT NOW(),
    last_served_at TIMESTAMPTZ,              -- When last selected for a user
    serve_count INTEGER DEFAULT 0,           -- How many times selected globally

    UNIQUE(pool_id, track_id)
);

CREATE INDEX idx_pool_tracks_pool ON candidate_pool_tracks(pool_id);
CREATE INDEX idx_pool_tracks_isrc ON candidate_pool_tracks(isrc) WHERE isrc IS NOT NULL;
CREATE INDEX idx_pool_tracks_added ON candidate_pool_tracks(pool_id, added_at);
CREATE INDEX idx_pool_tracks_source ON candidate_pool_tracks(pool_id, source);
```

#### `user_station_overlay`
Per-user, per-station state for filtering and personalization.

```sql
CREATE TABLE user_station_overlay (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    station_id UUID NOT NULL,                -- References local Station.id
    canonical_intent TEXT NOT NULL,          -- Links to the pool being used

    -- Recent history (for this station)
    recent_track_ids TEXT[] DEFAULT '{}',    -- Last 100 track IDs played
    recent_track_isrcs TEXT[] DEFAULT '{}',  -- Last 100 ISRCs played
    recent_artist_ids TEXT[] DEFAULT '{}',   -- Last 50 artist IDs

    -- Skip tracking
    session_skip_count INTEGER DEFAULT 0,
    session_started_at TIMESTAMPTZ,
    total_skip_count INTEGER DEFAULT 0,
    skipped_track_ids TEXT[] DEFAULT '{}',   -- Tracks skipped (for pattern analysis)

    -- Exploration state
    current_exploration_weight FLOAT DEFAULT 0.3,
    base_exploration_weight FLOAT DEFAULT 0.3,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_played_at TIMESTAMPTZ,

    UNIQUE(user_id, station_id)
);

CREATE INDEX idx_overlay_user_station ON user_station_overlay(user_id, station_id);
CREATE INDEX idx_overlay_user ON user_station_overlay(user_id);
```

### 1.2 Row Level Security (RLS)

```sql
-- intent_mappings: Read-only for authenticated users, write via Edge Functions
ALTER TABLE intent_mappings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read intent mappings" ON intent_mappings FOR SELECT USING (true);

-- search_plan_cache: Read-only for authenticated users
ALTER TABLE search_plan_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read search plans" ON search_plan_cache FOR SELECT USING (true);

-- candidate_pools: Read-only for authenticated users
ALTER TABLE candidate_pools ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read pools" ON candidate_pools FOR SELECT USING (true);

-- candidate_pool_tracks: Read-only for authenticated users
ALTER TABLE candidate_pool_tracks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read pool tracks" ON candidate_pool_tracks FOR SELECT USING (true);

-- user_station_overlay: Users can only access their own data
ALTER TABLE user_station_overlay ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage own overlays" ON user_station_overlay
    FOR ALL USING (auth.uid() = user_id);
```

---

## Phase 2: Edge Functions

### 2.1 `generate-search-plan`
Generates search plan + canonical intent from user prompt.

**Endpoint**: `POST /functions/v1/generate-search-plan`

**Request**:
```typescript
interface GenerateSearchPlanRequest {
    prompt: string;
    platform: "apple_music" | "spotify";
}
```

**Response**:
```typescript
interface GenerateSearchPlanResponse {
    canonical_intent: string;
    mood_categories: string[];
    flavor_tags: string[];
    search_plan: {
        playlist_searches: Array<{term: string; priority: number}>;
        catalog_searches: Array<{term: string; genres?: string[]}>;
        artist_seed_config?: {
            seed_count: number;
            similarity_ratios: {direct: number; adjacent: number; discovery: number};
        };
    };
    station_policy: {
        exploration_weight: number;
        source_mix: {playlist: number; search: number; artist_seed: number};
        artist_repeat_window: number;  // tracks
    };
    is_cached: boolean;
    intent_confidence: number;  // 0-1, low confidence triggers artist seed fallback
}
```

**Logic**:
1. Hash the raw prompt
2. Check `intent_mappings` for existing mapping
3. If found with occurrence_count >= 3, use cached canonical intent
4. If not found or occurrence_count < 3:
   - Call LLM to generate canonical intent + search plan
   - Upsert to `intent_mappings` (increment occurrence_count)
5. Check `search_plan_cache` for the canonical intent
6. If found and not expired, return cached plan
7. If not found or expired:
   - Use LLM-generated plan
   - Cache to `search_plan_cache`
8. Return response with `is_cached` flag

**LLM Prompt Structure**:
```
System: You are a music search strategist. Given a user's intent, generate:
1. A canonical intent ID (lowercase, hyphenated, e.g., "relaxed-driving-mood")
2. Mood categories for analytics
3. Search strategies optimized for {platform}

For Apple Music, prioritize:
- Editorial playlist searches (PRIMARY)
- Catalog term searches (SECONDARY)
- Artist seeds only as fallback config

User: Intent: "{prompt}"
Platform: {platform}

Respond with JSON only.
```

### 2.2 `refresh-candidate-pool`
Handles incremental pool refresh (called by client or scheduled job).

**Endpoint**: `POST /functions/v1/refresh-candidate-pool`

**Request**:
```typescript
interface RefreshPoolRequest {
    canonical_intent_hash: string;
    platform: "apple_music" | "spotify";
    refresh_percentage: number;  // 0.25 for 25%
    // Client provides tracks it fetched (since Edge Function can't call Apple Music)
    new_tracks?: Array<{
        track_id: string;
        artist_id: string;
        isrc?: string;
        source: string;
        source_detail?: string;
    }>;
}
```

**Response**:
```typescript
interface RefreshPoolResponse {
    success: boolean;
    pool_id: string;
    tracks_added: number;
    tracks_evicted: number;
    new_track_count: number;
}
```

**Logic**:
1. Acquire lock (set `refresh_in_progress = true`)
2. If `new_tracks` provided, insert them
3. Evict oldest/least-served tracks if over 1000 cap
4. Update pool metadata (track_count, updated_at, soft_ttl_at)
5. Release lock
6. Return stats

### 2.3 `get-candidate-pool`
Returns pool tracks for client-side selection.

**Endpoint**: `POST /functions/v1/get-candidate-pool`

**Request**:
```typescript
interface GetPoolRequest {
    canonical_intent_hash: string;
    platform: "apple_music" | "spotify";
    limit?: number;  // Default 500
    exclude_track_ids?: string[];  // Already played
}
```

**Response**:
```typescript
interface GetPoolResponse {
    pool_id: string;
    canonical_intent: string;
    tracks: Array<{
        track_id: string;
        artist_id: string;
        isrc?: string;
        source: string;
        source_detail?: string;
        added_at: string;
    }>;
    pool_metadata: {
        track_count: number;
        is_stale: boolean;  // soft_ttl exceeded
        needs_refresh: boolean;
        strategies_exhausted: string[];
    };
}
```

---

## Phase 3: Swift Client Architecture

### 3.1 New Files to Create

```
Curate/
├── CandidatePool/
│   ├── CandidatePoolService.swift          # Main orchestrator
│   ├── CandidatePoolRepository.swift       # Supabase CRUD for pools
│   ├── SearchPlanService.swift             # Calls generate-search-plan
│   ├── PoolRefreshCoordinator.swift        # Handles refresh logic
│   └── Types/
│       ├── CandidatePool.swift             # Pool model
│       ├── PoolTrack.swift                 # Track in pool
│       ├── SearchPlan.swift                # Search plan model
│       └── StationPolicy.swift             # Policy config
│
├── Recommender/
│   ├── HybridRecommender.swift             # New recommender (replaces RecommendationEngine)
│   ├── TrackSelector.swift                 # Deterministic selection logic
│   ├── UserOverlayManager.swift            # Manages user_station_overlay
│   └── SourceBucketizer.swift              # Bucketizes tracks by source/familiarity
│
├── Intent/
│   ├── IntentCanonicalizer.swift           # Hashes and maps intents
│   └── IntentMappingRepository.swift       # Local cache + Supabase sync
```

### 3.2 Core Protocols

```swift
// MARK: - CandidatePoolServiceProtocol

protocol CandidatePoolServiceProtocol {
    /// Get or create a candidate pool for the given intent
    func getPool(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool

    /// Trigger background refresh if pool is stale
    func refreshPoolIfNeeded(
        pool: CandidatePool
    ) async throws

    /// Build pool from search plan (client-side Apple Music fetching)
    func buildPool(
        searchPlan: SearchPlan,
        canonicalIntent: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool
}

// MARK: - HybridRecommenderProtocol

protocol HybridRecommenderProtocol {
    /// Select next tracks from pool with user overlay applied
    func selectTracks(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        count: Int
    ) -> [PoolTrack]

    /// Update overlay after track is played
    func recordPlay(
        track: PoolTrack,
        overlay: inout UserStationOverlay
    )

    /// Update overlay after track is skipped
    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    )
}

// MARK: - UserOverlayManagerProtocol

protocol UserOverlayManagerProtocol {
    /// Get or create overlay for user+station
    func getOverlay(
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String
    ) async throws -> UserStationOverlay

    /// Persist overlay changes to Supabase
    func saveOverlay(_ overlay: UserStationOverlay) async throws

    /// Reset session state (called on station start)
    func resetSession(_ overlay: inout UserStationOverlay)
}
```

### 3.3 Data Models

```swift
// MARK: - CandidatePool

struct CandidatePool: Codable {
    let id: UUID
    let canonicalIntentHash: String
    let canonicalIntent: String
    let platform: MusicPlatform
    var tracks: [PoolTrack]

    let createdAt: Date
    var updatedAt: Date
    var softTTLAt: Date
    var hardTTLAt: Date

    var strategiesUsed: [String]
    var strategiesExhausted: [String]

    var isStale: Bool {
        Date() > softTTLAt
    }

    var isExpired: Bool {
        Date() > hardTTLAt
    }

    var needsRefresh: Bool {
        isStale && !isExpired
    }
}

// MARK: - PoolTrack

struct PoolTrack: Codable, Identifiable {
    let id: UUID
    let trackId: String           // Apple Music catalog ID
    let artistId: String
    let isrc: String?
    let source: TrackSource
    let sourceDetail: String?
    let addedAt: Date
    var lastServedAt: Date?
    var serveCount: Int
}

enum TrackSource: String, Codable {
    case playlist
    case search
    case artistSeed = "artist_seed"
    case relatedArtist = "related_artist"
}

// MARK: - SearchPlan

struct SearchPlan: Codable {
    let canonicalIntent: String
    let moodCategories: [String]
    let flavorTags: [String]

    let playlistSearches: [PlaylistSearch]
    let catalogSearches: [CatalogSearch]
    let artistSeedConfig: ArtistSeedFallbackConfig?

    let stationPolicy: StationPolicy
    let intentConfidence: Double

    struct PlaylistSearch: Codable {
        let term: String
        let priority: Int
    }

    struct CatalogSearch: Codable {
        let term: String
        let genres: [String]?
    }

    struct ArtistSeedFallbackConfig: Codable {
        let seedCount: Int
        let similarityRatios: SimilarityRatios
    }
}

// MARK: - StationPolicy

struct StationPolicy: Codable {
    // Source mix targets
    var playlistSourceRatio: Double = 0.55
    var searchSourceRatio: Double = 0.25
    var artistSeedSourceRatio: Double = 0.20

    // Exploration
    var baseExplorationWeight: Double = 0.30
    var minExplorationWeight: Double = 0.15  // 50% of base
    var explorationDecayPerSkip: Double = 0.07  // ~7% reduction per skip

    // Repeat prevention
    var artistRepeatWindow: Int = 10  // Don't repeat artist within N tracks
    var trackRepeatWindow: Int = 100  // Don't repeat track within N plays

    // Fallback thresholds
    var minPoolSizeForPrimary: Int = 100
    var maxArtistSeedContribution: Double = 0.30

    static let `default` = StationPolicy()
}

// MARK: - UserStationOverlay

struct UserStationOverlay: Codable {
    let id: UUID
    let userId: UUID
    let stationId: UUID
    let canonicalIntent: String

    // Recent history
    var recentTrackIds: [String]      // Circular buffer, max 100
    var recentTrackISRCs: [String]    // Circular buffer, max 100
    var recentArtistIds: [String]     // Circular buffer, max 50

    // Skip tracking
    var sessionSkipCount: Int
    var sessionStartedAt: Date?
    var totalSkipCount: Int
    var skippedTrackIds: [String]     // For pattern analysis

    // Exploration state
    var currentExplorationWeight: Double
    var baseExplorationWeight: Double

    var createdAt: Date
    var updatedAt: Date
    var lastPlayedAt: Date?

    // MARK: - Session Management

    mutating func resetSession(policy: StationPolicy) {
        sessionSkipCount = 0
        sessionStartedAt = Date()
        currentExplorationWeight = policy.baseExplorationWeight
    }

    mutating func recordSkip(trackId: String, policy: StationPolicy) {
        sessionSkipCount += 1
        totalSkipCount += 1
        skippedTrackIds.append(trackId)

        // Decay exploration weight
        if sessionSkipCount >= 1 {
            let decay = policy.explorationDecayPerSkip
            let floor = policy.minExplorationWeight
            currentExplorationWeight = max(floor, currentExplorationWeight * (1 - decay))
        }
    }
}
```

### 3.4 HybridRecommender Implementation

```swift
// MARK: - HybridRecommender

final class HybridRecommender: HybridRecommenderProtocol {

    // MARK: - Track Selection

    func selectTracks(
        from pool: CandidatePool,
        userOverlay: UserStationOverlay,
        policy: StationPolicy,
        count: Int
    ) -> [PoolTrack] {

        // Step 1: Hard filter
        var candidates = hardFilter(
            pool.tracks,
            overlay: userOverlay,
            policy: policy
        )

        // Step 2: Check if fallback needed
        if candidates.count < policy.minPoolSizeForPrimary {
            // Will need artist seed expansion (handled by caller)
            // For now, work with what we have
        }

        // Step 3: Bucketize by source
        let buckets = bucketize(candidates)

        // Step 4: Choose bucket based on policy + exploration
        var selected: [PoolTrack] = []
        var usedTrackIds = Set(userOverlay.recentTrackIds)
        var usedArtistIds = Set<String>()

        for _ in 0..<count {
            // Determine target bucket based on policy ratios + randomness
            let bucket = chooseBucket(
                buckets: buckets,
                policy: policy,
                explorationWeight: userOverlay.currentExplorationWeight,
                usedTrackIds: usedTrackIds
            )

            // Score tracks in bucket
            let scored = bucket.compactMap { track -> (PoolTrack, Double)? in
                guard !usedTrackIds.contains(track.trackId) else { return nil }

                // Enforce artist repeat window
                let recentArtistCount = userOverlay.recentArtistIds
                    .suffix(policy.artistRepeatWindow)
                    .filter { $0 == track.artistId }
                    .count
                if recentArtistCount > 0 { return nil }

                let score = scoreTrack(track, usedArtistIds: usedArtistIds)
                return (track, score)
            }

            // Weighted random selection from top candidates
            if let selectedTrack = weightedRandomSelect(from: scored, topK: 5) {
                selected.append(selectedTrack)
                usedTrackIds.insert(selectedTrack.trackId)
                usedArtistIds.insert(selectedTrack.artistId)
            }
        }

        return selected
    }

    // MARK: - Hard Filter

    private func hardFilter(
        _ tracks: [PoolTrack],
        overlay: UserStationOverlay,
        policy: StationPolicy
    ) -> [PoolTrack] {
        let recentTrackSet = Set(overlay.recentTrackIds.suffix(policy.trackRepeatWindow))
        let recentISRCSet = Set(overlay.recentTrackISRCs.suffix(policy.trackRepeatWindow))

        // Load disliked artists from existing artist_scores (passed in or fetched)
        // For now, filter by recent tracks only

        return tracks.filter { track in
            // No recent repeats
            if recentTrackSet.contains(track.trackId) { return false }
            if let isrc = track.isrc, recentISRCSet.contains(isrc) { return false }

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
        // Higher exploration = more diverse sources
        var ratios: [TrackSource: Double] = [
            .playlist: policy.playlistSourceRatio,
            .search: policy.searchSourceRatio,
            .artistSeed: policy.artistSeedSourceRatio,
            .relatedArtist: policy.artistSeedSourceRatio * 0.5
        ]

        // Adjust for exploration (boost search/discovery when exploring)
        let explorationBoost = explorationWeight - 0.3  // Deviation from baseline
        ratios[.search] = (ratios[.search] ?? 0) + explorationBoost * 0.2
        ratios[.playlist] = (ratios[.playlist] ?? 0) - explorationBoost * 0.1

        // Normalize
        let total = ratios.values.reduce(0, +)
        ratios = ratios.mapValues { $0 / total }

        // Weighted random bucket selection
        let rand = Double.random(in: 0...1)
        var cumulative = 0.0

        for (source, ratio) in ratios.sorted(by: { $0.value > $1.value }) {
            cumulative += ratio
            if rand <= cumulative, let bucket = buckets[source], !bucket.isEmpty {
                return bucket
            }
        }

        // Fallback to largest bucket
        return buckets.max(by: { $0.value.count < $1.value.count })?.value ?? []
    }

    // MARK: - Track Scoring

    private func scoreTrack(_ track: PoolTrack, usedArtistIds: Set<String>) -> Double {
        var score = 1.0

        // Freshness boost (newer = slightly better)
        let ageHours = Date().timeIntervalSince(track.addedAt) / 3600
        let freshnessBoost = max(0.8, 1.0 - (ageHours / 168))  // Decay over 1 week
        score *= freshnessBoost

        // Source balance (slight preference for less-served tracks)
        let serveCountPenalty = max(0.5, 1.0 - Double(track.serveCount) * 0.05)
        score *= serveCountPenalty

        // Artist diversity boost
        if usedArtistIds.contains(track.artistId) {
            score *= 0.3  // Heavy penalty for same artist in same batch
        }

        // Random factor for variety
        score *= Double.random(in: 0.9...1.1)

        return score
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
        // Add to recent history (circular buffer)
        overlay.recentTrackIds.append(track.trackId)
        if overlay.recentTrackIds.count > 100 {
            overlay.recentTrackIds.removeFirst()
        }

        if let isrc = track.isrc {
            overlay.recentTrackISRCs.append(isrc)
            if overlay.recentTrackISRCs.count > 100 {
                overlay.recentTrackISRCs.removeFirst()
            }
        }

        overlay.recentArtistIds.append(track.artistId)
        if overlay.recentArtistIds.count > 50 {
            overlay.recentArtistIds.removeFirst()
        }

        overlay.lastPlayedAt = Date()
        overlay.updatedAt = Date()
    }

    func recordSkip(
        track: PoolTrack,
        overlay: inout UserStationOverlay,
        policy: StationPolicy
    ) {
        overlay.recordSkip(trackId: track.trackId, policy: policy)
        overlay.updatedAt = Date()
    }
}
```

### 3.5 CandidatePoolService Implementation

```swift
// MARK: - CandidatePoolService

final class CandidatePoolService: CandidatePoolServiceProtocol {

    private let searchPlanService: SearchPlanServiceProtocol
    private let poolRepository: CandidatePoolRepositoryProtocol
    private let musicProvider: MusicProviderProtocol
    private let artistSeedService: ArtistSeedServiceProtocol  // Fallback

    // MARK: - Get Pool

    func getPool(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool {

        // 1. Get search plan (handles intent canonicalization + caching)
        let searchPlan = try await searchPlanService.getSearchPlan(
            for: prompt,
            platform: platform
        )

        let intentHash = sha256(searchPlan.canonicalIntent)

        // 2. Check for existing pool
        if let existingPool = try await poolRepository.getPool(
            intentHash: intentHash,
            platform: platform
        ) {
            // Check if usable
            if !existingPool.isExpired {
                // Trigger background refresh if stale
                if existingPool.needsRefresh {
                    Task {
                        try? await refreshPoolIfNeeded(pool: existingPool)
                    }
                }
                return existingPool
            }
        }

        // 3. Build new pool
        return try await buildPool(
            searchPlan: searchPlan,
            canonicalIntent: searchPlan.canonicalIntent,
            platform: platform
        )
    }

    // MARK: - Build Pool

    func buildPool(
        searchPlan: SearchPlan,
        canonicalIntent: String,
        platform: MusicPlatform
    ) async throws -> CandidatePool {

        var allTracks: [PoolTrack] = []
        var strategiesUsed: [String] = []

        // Priority 1: Playlist searches
        for playlistSearch in searchPlan.playlistSearches.sorted(by: { $0.priority < $1.priority }) {
            let tracks = try await fetchPlaylistTracks(
                term: playlistSearch.term,
                limit: 100
            )
            allTracks.append(contentsOf: tracks)
            strategiesUsed.append("playlist:\(playlistSearch.term)")

            if allTracks.count >= 500 { break }
        }

        // Priority 2: Catalog searches (if needed)
        if allTracks.count < 500 {
            for catalogSearch in searchPlan.catalogSearches {
                let tracks = try await fetchCatalogTracks(
                    term: catalogSearch.term,
                    genres: catalogSearch.genres,
                    limit: 50
                )
                allTracks.append(contentsOf: tracks)
                strategiesUsed.append("search:\(catalogSearch.term)")

                if allTracks.count >= 500 { break }
            }
        }

        // Priority 3: Artist seed fallback (if pool too small or low confidence)
        if allTracks.count < 100 || searchPlan.intentConfidence < 0.5 {
            if let artistConfig = searchPlan.artistSeedConfig {
                let artistTracks = try await fetchArtistSeedTracks(
                    config: artistConfig,
                    maxContribution: searchPlan.stationPolicy.maxArtistSeedContribution,
                    currentCount: allTracks.count
                )
                allTracks.append(contentsOf: artistTracks)
                strategiesUsed.append("artist_seed")
            }
        }

        // Deduplicate by ISRC
        allTracks = deduplicateByISRC(allTracks)

        // Cap at 1000
        if allTracks.count > 1000 {
            allTracks = Array(allTracks.prefix(1000))
        }

        // Create pool
        let pool = CandidatePool(
            id: UUID(),
            canonicalIntentHash: sha256(canonicalIntent),
            canonicalIntent: canonicalIntent,
            platform: platform,
            tracks: allTracks,
            createdAt: Date(),
            updatedAt: Date(),
            softTTLAt: Date().addingTimeInterval(6 * 3600),   // 6 hours
            hardTTLAt: Date().addingTimeInterval(24 * 3600),  // 24 hours
            strategiesUsed: strategiesUsed,
            strategiesExhausted: []
        )

        // Persist to Supabase
        try await poolRepository.savePool(pool)

        return pool
    }

    // MARK: - Refresh Pool

    func refreshPoolIfNeeded(pool: CandidatePool) async throws {
        guard pool.needsRefresh else { return }

        // Fetch 25% new tracks using unused strategies
        let refreshCount = pool.tracks.count / 4
        var newTracks: [PoolTrack] = []

        // Use strategies not yet exhausted
        // ... implementation details ...

        // Submit to Edge Function for atomic update
        try await poolRepository.refreshPool(
            poolId: pool.id,
            newTracks: newTracks,
            refreshPercentage: 0.25
        )
    }

    // MARK: - Private Helpers

    private func fetchPlaylistTracks(term: String, limit: Int) async throws -> [PoolTrack] {
        let results = try await musicProvider.searchPlaylists(term: term, limit: 10)
        var tracks: [PoolTrack] = []

        for playlist in results {
            let playlistTracks = try await musicProvider.getPlaylistTracks(
                playlistId: playlist.id,
                limit: limit / results.count
            )

            tracks.append(contentsOf: playlistTracks.map { track in
                PoolTrack(
                    id: UUID(),
                    trackId: track.id,
                    artistId: track.artistId ?? "",
                    isrc: track.isrc,
                    source: .playlist,
                    sourceDetail: "playlist:\(playlist.id)",
                    addedAt: Date(),
                    lastServedAt: nil,
                    serveCount: 0
                )
            })
        }

        return tracks
    }

    private func fetchCatalogTracks(
        term: String,
        genres: [String]?,
        limit: Int
    ) async throws -> [PoolTrack] {
        let results = try await musicProvider.searchTracks(
            term: term,
            genres: genres,
            limit: limit
        )

        return results.map { track in
            PoolTrack(
                id: UUID(),
                trackId: track.id,
                artistId: track.artistId ?? "",
                isrc: track.isrc,
                source: .search,
                sourceDetail: "search:\(term)",
                addedAt: Date(),
                lastServedAt: nil,
                serveCount: 0
            )
        }
    }

    private func fetchArtistSeedTracks(
        config: SearchPlan.ArtistSeedFallbackConfig,
        maxContribution: Double,
        currentCount: Int
    ) async throws -> [PoolTrack] {
        // Delegate to existing ArtistSeedService
        // Cap at maxContribution of total pool
        let maxTracks = Int(Double(currentCount + 200) * maxContribution) -
                        Int(Double(currentCount) * maxContribution)

        // ... use artistSeedService ...

        return []  // Placeholder
    }

    private func deduplicateByISRC(_ tracks: [PoolTrack]) -> [PoolTrack] {
        var seen = Set<String>()
        var result: [PoolTrack] = []

        for track in tracks {
            if let isrc = track.isrc {
                if seen.contains(isrc) { continue }
                seen.insert(isrc)
            }
            result.append(track)
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        // Use CryptoKit
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

---

## Phase 4: Integration with Existing Code

### 4.1 Station Model Updates

Add to [Station.swift](Curate/Station.swift):

```swift
// MARK: - Hybrid Pool Properties

/// The canonical intent this station maps to (for pool lookup)
var canonicalIntent: String?

/// Whether this station uses the hybrid pool system (vs legacy artist seeds)
var usesHybridPool: Bool = true

/// Station policy overrides (nil = use defaults from search plan)
var policyOverridesData: Data?

var policyOverrides: StationPolicy? {
    get {
        guard let data = policyOverridesData else { return nil }
        return try? JSONDecoder().decode(StationPolicy.self, from: data)
    }
    set {
        policyOverridesData = try? JSONEncoder().encode(newValue)
    }
}
```

### 4.2 MusicProviderProtocol Extensions

Add to [MusicProviderProtocol.swift](Curate/MusicProviderProtocol.swift):

```swift
// MARK: - Playlist Discovery (for Hybrid Pool)

/// Search for playlists by term
func searchPlaylists(term: String, limit: Int) async throws -> [ProviderPlaylist]

/// Get tracks from a playlist
func getPlaylistTracks(playlistId: String, limit: Int) async throws -> [ProviderTrack]

// MARK: - ProviderPlaylist

struct ProviderPlaylist {
    let id: String
    let name: String
    let description: String?
    let trackCount: Int
    let curatorName: String?
    let isEditorial: Bool
}
```

### 4.3 Comment Out Thompson Sampling

In [RecommendationEngine.swift](Curate/RecommendationEngine.swift), wrap existing code:

```swift
/*
 * LEGACY: Thompson Sampling Recommendation Engine
 *
 * This code is preserved but disabled in favor of the HybridRecommender.
 * The hybrid candidate pool architecture provides better global caching
 * and more deterministic, explainable recommendations.
 *
 * To re-enable: Remove comment markers and update station service to use
 * RecommendationEngine instead of HybridRecommender.
 */

// ... existing code wrapped in /* */ ...
```

### 4.4 Fallback Integration

The existing `ArtistSeedService` remains as a fallback. Integration points:

1. **Pool Building**: If playlist/search yields < 100 tracks, call `ArtistSeedService.getRecommendedTracks()`
2. **Low Confidence**: If `SearchPlan.intentConfidence < 0.5`, proactively include artist seeds
3. **API Failure**: If Apple Music APIs fail, use `ArtistSeedService` as primary source

---

## Phase 5: Error Handling & Resilience

### 5.1 Error Recovery Strategy

```swift
enum PoolError: Error {
    case poolNotFound
    case poolExpired
    case poolTooSmall(available: Int, required: Int)
    case apiFailure(underlying: Error)
    case refreshInProgress
}

// In CandidatePoolService
func getPoolWithFallback(
    for prompt: String,
    platform: MusicPlatform
) async throws -> CandidatePool {
    do {
        return try await getPool(for: prompt, platform: platform)
    } catch PoolError.poolTooSmall(let available, _) where available > 0 {
        // Serve stale pool while refreshing
        // ...
    } catch PoolError.apiFailure {
        // Fall back to artist seeds entirely
        return try await buildArtistSeedOnlyPool(for: prompt, platform: platform)
    }
}
```

### 5.2 Immediate Lightweight Refresh

When pool is stale but usable, fetch 5-10 tracks synchronously:

```swift
func quickRefresh(pool: CandidatePool) async throws -> [PoolTrack] {
    // Pick one unused strategy
    // Fetch 5-10 tracks quickly
    // Add to local pool copy (not persisted until full refresh)
    // Return for immediate use
}
```

---

## Phase 6: Implementation Order

### Milestone 1: Database & Edge Functions (Backend)
1. Create Supabase migration with all new tables
2. Implement `generate-search-plan` Edge Function
3. Implement `get-candidate-pool` Edge Function
4. Implement `refresh-candidate-pool` Edge Function
5. Test Edge Functions via curl/Postman

### Milestone 2: Swift Data Layer
1. Create data models (`CandidatePool`, `PoolTrack`, `SearchPlan`, `StationPolicy`, `UserStationOverlay`)
2. Create repositories (`CandidatePoolRepository`, `IntentMappingRepository`, `UserOverlayRepository`)
3. Implement `SearchPlanService` (calls Edge Function)
4. Unit test repositories with mocks

### Milestone 3: Core Recommender
1. Implement `HybridRecommender` with all selection logic
2. Implement `SourceBucketizer`
3. Implement `TrackSelector`
4. Implement `UserOverlayManager`
5. Unit test recommender with mock pools

### Milestone 4: Pool Building (Client-Side)
1. Extend `MusicProviderProtocol` with playlist methods
2. Implement playlist search in `AppleMusicProvider`
3. Implement `CandidatePoolService.buildPool()`
4. Implement `PoolRefreshCoordinator`
5. Integration test pool building with Apple Music sandbox

### Milestone 5: Integration
1. Update `Station` model with hybrid pool properties
2. Comment out `RecommendationEngine.swift`
3. Wire up `HybridRecommender` in station playback flow
4. Implement fallback to `ArtistSeedService`
5. End-to-end testing

### Milestone 6: Polish & Monitoring
1. Add analytics events for pool hits/misses
2. Add logging for refresh triggers
3. Implement pool usage metrics in Supabase
4. Performance tuning (batch fetches, caching)

---

## Security Considerations

1. **RLS Policies**: All new tables have appropriate RLS to prevent unauthorized access
2. **JWT Validation**: Edge Functions validate auth tokens before writes
3. **Rate Limiting**: Pool refresh has lock mechanism to prevent concurrent refreshes
4. **Input Sanitization**: Prompts are hashed, not stored raw in cache keys
5. **No PII in Pools**: Global pools contain only track/artist IDs, no user data

---

## Appendix: LLM Prompt for Search Plan Generation

```
System: You are a music search strategist for streaming platforms. Given a user's natural language intent, generate a search plan optimized for discovering relevant tracks.

Your output must be valid JSON with this structure:
{
    "canonical_intent": "lowercase-hyphenated-intent-id",
    "mood_categories": ["category1", "category2"],
    "flavor_tags": ["specific", "nuance", "tags"],
    "intent_confidence": 0.0-1.0,
    "search_plan": {
        "playlist_searches": [
            {"term": "search term for playlists", "priority": 1}
        ],
        "catalog_searches": [
            {"term": "catalog search term", "genres": ["genre1"]}
        ],
        "artist_seed_config": {
            "seed_count": 5,
            "similarity_ratios": {"direct": 0.5, "adjacent": 0.35, "discovery": 0.15}
        }
    },
    "station_policy": {
        "exploration_weight": 0.3,
        "source_mix": {"playlist": 0.55, "search": 0.25, "artist_seed": 0.20},
        "artist_repeat_window": 10
    }
}

Guidelines:
- canonical_intent should be reusable across similar prompts (e.g., "sunset drive" and "evening drive" might both map to "relaxed-driving-mood")
- mood_categories are broad (e.g., "chill", "energetic", "melancholic")
- flavor_tags capture specific nuances (e.g., "sunset", "acoustic", "90s")
- intent_confidence: 1.0 = very clear intent, 0.5 = ambiguous, lower = artist seeds recommended
- For Apple Music: prioritize playlist searches (editorial playlists are high quality)
- For Spotify: balance playlist and catalog searches
- artist_seed_config is only needed if intent is ambiguous or user mentions specific artists

User: Platform: {platform}
Intent: "{user_prompt}"
```

---

## Summary

This architecture provides:

1. **Efficiency**: Global pools shared across users reduce API calls by ~90%
2. **Freshness**: Incremental 25% refresh keeps content fresh without rebuilding
3. **Personalization**: Per-user overlays filter global pools for individual taste
4. **Resilience**: Multiple fallback layers (stale pool → artist seeds → fail gracefully)
5. **Explainability**: All decisions are deterministic and logged
6. **Extensibility**: Clean protocol-based design supports Spotify integration later
