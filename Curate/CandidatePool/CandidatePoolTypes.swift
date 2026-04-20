//
//  CandidatePoolTypes.swift
//  Curate
//
//  Data models for the hybrid candidate pool architecture.
//  These types mirror the Supabase schema and Edge Function types.
//

import Foundation
import CryptoKit

// MARK: - Music Platform

enum MusicPlatform: String, Codable, CaseIterable {
    case appleMusic = "apple_music"
    case spotify = "spotify"
}

// MARK: - Track Source

enum TrackSource: String, Codable, CaseIterable {
    case playlist = "playlist"
    case search = "search"
    case artistSeed = "artist_seed"
    case relatedArtist = "related_artist"
}

// MARK: - Pool Track

/// A track in a candidate pool
struct PoolTrack: Codable, Identifiable, Hashable {
    let id: UUID
    let trackId: String           // Platform-specific ID (Apple Music catalog ID)
    let artistId: String          // Platform-specific artist ID
    let isrc: String?             // For cross-platform deduplication
    let source: TrackSource
    let sourceDetail: String?     // e.g., "playlist:sunset-vibes-2024"
    let addedAt: Date
    var lastServedAt: Date?
    var serveCount: Int

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(trackId)
    }

    static func == (lhs: PoolTrack, rhs: PoolTrack) -> Bool {
        lhs.trackId == rhs.trackId
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case artistId = "artist_id"
        case isrc
        case source
        case sourceDetail = "source_detail"
        case addedAt = "added_at"
        case lastServedAt = "last_served_at"
        case serveCount = "serve_count"
    }

    init(
        id: UUID = UUID(),
        trackId: String,
        artistId: String,
        isrc: String? = nil,
        source: TrackSource,
        sourceDetail: String? = nil,
        addedAt: Date = Date(),
        lastServedAt: Date? = nil,
        serveCount: Int = 0
    ) {
        self.id = id
        self.trackId = trackId
        self.artistId = artistId
        self.isrc = isrc
        self.source = source
        self.sourceDetail = sourceDetail
        self.addedAt = addedAt
        self.lastServedAt = lastServedAt
        self.serveCount = serveCount
    }
}

// MARK: - Candidate Pool

/// A global candidate pool for a canonical intent
struct CandidatePool: Codable, Identifiable {
    let id: UUID
    let canonicalIntentHash: String
    let canonicalIntent: String
    let platform: MusicPlatform
    var tracks: [PoolTrack]

    let createdAt: Date
    var updatedAt: Date
    var softTTLAt: Date
    var hardTTLAt: Date

    var refreshInProgress: Bool
    var strategiesUsed: [String]
    var strategiesExhausted: [String]

    // MARK: - Computed Properties

    var trackCount: Int {
        tracks.count
    }

    var isStale: Bool {
        Date() > softTTLAt
    }

    var isExpired: Bool {
        Date() > hardTTLAt
    }

    var needsRefresh: Bool {
        isStale && !isExpired && !refreshInProgress
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalIntentHash = "canonical_intent_hash"
        case canonicalIntent = "canonical_intent"
        case platform
        case tracks
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case softTTLAt = "soft_ttl_at"
        case hardTTLAt = "hard_ttl_at"
        case refreshInProgress = "refresh_in_progress"
        case strategiesUsed = "strategies_used"
        case strategiesExhausted = "strategies_exhausted"
    }

    init(
        id: UUID = UUID(),
        canonicalIntentHash: String,
        canonicalIntent: String,
        platform: MusicPlatform,
        tracks: [PoolTrack] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        softTTLAt: Date? = nil,
        hardTTLAt: Date? = nil,
        refreshInProgress: Bool = false,
        strategiesUsed: [String] = [],
        strategiesExhausted: [String] = []
    ) {
        self.id = id
        self.canonicalIntentHash = canonicalIntentHash
        self.canonicalIntent = canonicalIntent
        self.platform = platform
        self.tracks = tracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.softTTLAt = softTTLAt ?? createdAt.addingTimeInterval(6 * 3600)  // 6 hours
        self.hardTTLAt = hardTTLAt ?? createdAt.addingTimeInterval(24 * 3600) // 24 hours
        self.refreshInProgress = refreshInProgress
        self.strategiesUsed = strategiesUsed
        self.strategiesExhausted = strategiesExhausted
    }
}

// MARK: - Pool Metadata

/// Lightweight metadata about a pool (from Edge Function response)
struct PoolMetadata: Codable {
    let trackCount: Int
    let isStale: Bool
    let needsRefresh: Bool
    let strategiesExhausted: [String]

    enum CodingKeys: String, CodingKey {
        case trackCount = "track_count"
        case isStale = "is_stale"
        case needsRefresh = "needs_refresh"
        case strategiesExhausted = "strategies_exhausted"
    }
}

// MARK: - Search Plan Types

/// A playlist search term with priority
struct PlaylistSearch: Codable {
    let term: String
    let priority: Int
}

/// A catalog search configuration
struct CatalogSearch: Codable {
    let term: String
    let genres: [String]?
}

/// Configuration for artist seed fallback
struct ArtistSeedFallbackConfig: Codable {
    let seedCount: Int
    let similarityRatios: SimilarityRatios

    struct SimilarityRatios: Codable {
        let direct: Double
        let adjacent: Double
        let discovery: Double
    }

    enum CodingKeys: String, CodingKey {
        case seedCount = "seed_count"
        case similarityRatios = "similarity_ratios"
    }
}

/// Station policy configuration
struct StationPolicy: Codable {
    // Source mix targets (should sum to 1.0)
    var playlistSourceRatio: Double
    var searchSourceRatio: Double
    var artistSeedSourceRatio: Double

    // Exploration
    var baseExplorationWeight: Double
    var minExplorationWeight: Double      // Floor (50% of base by default)
    var explorationDecayPerSkip: Double   // ~7% reduction per skip

    // Repeat prevention
    var artistRepeatWindow: Int           // Don't repeat artist within N tracks
    var trackRepeatWindow: Int            // Don't repeat track within N plays

    // Fallback thresholds
    var minPoolSizeForPrimary: Int
    var maxArtistSeedContribution: Double

    // MARK: - Default Configuration

    static let `default` = StationPolicy(
        playlistSourceRatio: 0.55,
        searchSourceRatio: 0.25,
        artistSeedSourceRatio: 0.20,
        baseExplorationWeight: 0.30,
        minExplorationWeight: 0.15,
        explorationDecayPerSkip: 0.07,
        artistRepeatWindow: 10,
        trackRepeatWindow: 100,
        minPoolSizeForPrimary: 100,
        maxArtistSeedContribution: 0.30
    )

    enum CodingKeys: String, CodingKey {
        case playlistSourceRatio = "playlist_source_ratio"
        case searchSourceRatio = "search_source_ratio"
        case artistSeedSourceRatio = "artist_seed_source_ratio"
        case baseExplorationWeight = "base_exploration_weight"
        case minExplorationWeight = "min_exploration_weight"
        case explorationDecayPerSkip = "exploration_decay_per_skip"
        case artistRepeatWindow = "artist_repeat_window"
        case trackRepeatWindow = "track_repeat_window"
        case minPoolSizeForPrimary = "min_pool_size_for_primary"
        case maxArtistSeedContribution = "max_artist_seed_contribution"
    }

    /// Merge with LLM-suggested policy, keeping defaults for missing values
    func merged(with suggested: SuggestedStationPolicy?) -> StationPolicy {
        guard let suggested = suggested else { return self }

        var merged = self
        merged.playlistSourceRatio = suggested.playlistSourceRatio ?? playlistSourceRatio
        merged.searchSourceRatio = suggested.searchSourceRatio ?? searchSourceRatio
        merged.artistSeedSourceRatio = suggested.artistSeedSourceRatio ?? artistSeedSourceRatio
        merged.baseExplorationWeight = suggested.explorationWeight ?? baseExplorationWeight
        merged.artistRepeatWindow = suggested.artistRepeatWindow ?? artistRepeatWindow

        // Normalize source ratios
        let total = merged.playlistSourceRatio + merged.searchSourceRatio + merged.artistSeedSourceRatio
        if total > 0 && abs(total - 1.0) > 0.01 {
            merged.playlistSourceRatio /= total
            merged.searchSourceRatio /= total
            merged.artistSeedSourceRatio /= total
        }

        return merged
    }
}

/// LLM-suggested station policy (from search plan)
struct SuggestedStationPolicy: Codable {
    let playlistSourceRatio: Double?
    let searchSourceRatio: Double?
    let artistSeedSourceRatio: Double?
    let explorationWeight: Double?
    let artistRepeatWindow: Int?

    enum CodingKeys: String, CodingKey {
        case playlistSourceRatio = "playlist_source_ratio"
        case searchSourceRatio = "search_source_ratio"
        case artistSeedSourceRatio = "artist_seed_source_ratio"
        case explorationWeight = "exploration_weight"
        case artistRepeatWindow = "artist_repeat_window"
    }
}

/// Complete search plan from LLM
struct SearchPlan: Codable {
    let canonicalIntent: String
    let moodCategories: [String]
    let flavorTags: [String]
    let intentConfidence: Double

    let playlistSearches: [PlaylistSearch]
    let catalogSearches: [CatalogSearch]
    let artistSeedConfig: ArtistSeedFallbackConfig?

    let stationPolicy: SuggestedStationPolicy
    let isCached: Bool

    enum CodingKeys: String, CodingKey {
        case canonicalIntent = "canonical_intent"
        case moodCategories = "mood_categories"
        case flavorTags = "flavor_tags"
        case intentConfidence = "intent_confidence"
        case playlistSearches = "playlist_searches"
        case catalogSearches = "catalog_searches"
        case artistSeedConfig = "artist_seed_config"
        case stationPolicy = "station_policy"
        case isCached = "is_cached"
    }

    /// Whether this plan suggests using artist seeds as primary source
    var shouldUseArtistSeedFallback: Bool {
        intentConfidence < 0.5
    }
}

// MARK: - User Station Overlay

/// Per-user, per-station state for filtering and personalization
struct UserStationOverlay: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let stationId: UUID
    let canonicalIntent: String

    // Recent history (circular buffers)
    var recentTrackIds: [String]        // Last 100 track IDs played
    var recentTrackISRCs: [String]      // Last 100 ISRCs played
    var recentArtistIds: [String]       // Last 50 artist IDs

    // Skip tracking
    var sessionSkipCount: Int
    var sessionStartedAt: Date?
    var totalSkipCount: Int
    var skippedTrackIds: [String]       // For pattern analysis

    // Exploration state
    var currentExplorationWeight: Double
    var baseExplorationWeight: Double

    // Timestamps
    var createdAt: Date
    var updatedAt: Date
    var lastPlayedAt: Date?

    // MARK: - Constants

    private static let maxRecentTracks = 100
    private static let maxRecentArtists = 50

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case stationId = "station_id"
        case canonicalIntent = "canonical_intent"
        case recentTrackIds = "recent_track_ids"
        case recentTrackISRCs = "recent_track_isrcs"
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

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        userId: UUID,
        stationId: UUID,
        canonicalIntent: String,
        recentTrackIds: [String] = [],
        recentTrackISRCs: [String] = [],
        recentArtistIds: [String] = [],
        sessionSkipCount: Int = 0,
        sessionStartedAt: Date? = nil,
        totalSkipCount: Int = 0,
        skippedTrackIds: [String] = [],
        currentExplorationWeight: Double = 0.3,
        baseExplorationWeight: Double = 0.3,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.stationId = stationId
        self.canonicalIntent = canonicalIntent
        self.recentTrackIds = recentTrackIds
        self.recentTrackISRCs = recentTrackISRCs
        self.recentArtistIds = recentArtistIds
        self.sessionSkipCount = sessionSkipCount
        self.sessionStartedAt = sessionStartedAt
        self.totalSkipCount = totalSkipCount
        self.skippedTrackIds = skippedTrackIds
        self.currentExplorationWeight = currentExplorationWeight
        self.baseExplorationWeight = baseExplorationWeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPlayedAt = lastPlayedAt
    }

    // MARK: - Session Management

    /// Reset session state (called when station starts playing)
    mutating func resetSession(policy: StationPolicy) {
        sessionSkipCount = 0
        sessionStartedAt = Date()
        currentExplorationWeight = policy.baseExplorationWeight
    }

    /// Record a track play
    mutating func recordPlay(track: PoolTrack) {
        // Add to recent tracks (circular buffer)
        recentTrackIds.append(track.trackId)
        if recentTrackIds.count > Self.maxRecentTracks {
            recentTrackIds.removeFirst()
        }

        if let isrc = track.isrc {
            recentTrackISRCs.append(isrc)
            if recentTrackISRCs.count > Self.maxRecentTracks {
                recentTrackISRCs.removeFirst()
            }
        }

        recentArtistIds.append(track.artistId)
        if recentArtistIds.count > Self.maxRecentArtists {
            recentArtistIds.removeFirst()
        }

        lastPlayedAt = Date()
        updatedAt = Date()
    }

    /// Record a skip and decay exploration weight
    mutating func recordSkip(trackId: String, policy: StationPolicy) {
        sessionSkipCount += 1
        totalSkipCount += 1
        skippedTrackIds.append(trackId)

        // Decay exploration weight after skip
        if sessionSkipCount >= 1 {
            let decay = policy.explorationDecayPerSkip
            let floor = policy.minExplorationWeight
            currentExplorationWeight = max(floor, currentExplorationWeight * (1 - decay))
        }

        updatedAt = Date()
    }

    /// Check if a track was recently played
    func wasRecentlyPlayed(trackId: String, window: Int? = nil) -> Bool {
        let checkWindow = window ?? Self.maxRecentTracks
        let recentSlice = recentTrackIds.suffix(checkWindow)
        return recentSlice.contains(trackId)
    }

    /// Check if an artist was recently played
    func wasArtistRecentlyPlayed(artistId: String, window: Int) -> Bool {
        let recentSlice = recentArtistIds.suffix(window)
        return recentSlice.contains(artistId)
    }
}

// MARK: - Intent Mapping

/// Maps raw prompts to canonical intents
struct IntentMapping: Codable, Identifiable {
    let id: UUID
    let rawPromptHash: String
    let rawPrompt: String
    let canonicalIntent: String
    let moodCategories: [String]
    let flavorTags: [String]
    var occurrenceCount: Int
    let platform: MusicPlatform
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case rawPromptHash = "raw_prompt_hash"
        case rawPrompt = "raw_prompt"
        case canonicalIntent = "canonical_intent"
        case moodCategories = "mood_categories"
        case flavorTags = "flavor_tags"
        case occurrenceCount = "occurrence_count"
        case platform
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}


// MARK: - Edge Function Request/Response Types

/// Request to generate a search plan
struct GenerateSearchPlanRequest: Codable {
    let prompt: String
    let platform: MusicPlatform
}

/// Response from generate-search-plan Edge Function
struct GenerateSearchPlanResponse: Codable {
    let canonicalIntent: String
    let moodCategories: [String]
    let flavorTags: [String]
    let intentConfidence: Double
    let searchPlan: SearchPlanContent
    let stationPolicy: SuggestedStationPolicy
    let isCached: Bool

    struct SearchPlanContent: Codable {
        let playlistSearches: [PlaylistSearch]
        let catalogSearches: [CatalogSearch]
        let artistSeedConfig: ArtistSeedFallbackConfig?

        enum CodingKeys: String, CodingKey {
            case playlistSearches = "playlist_searches"
            case catalogSearches = "catalog_searches"
            case artistSeedConfig = "artist_seed_config"
        }
    }

    enum CodingKeys: String, CodingKey {
        case canonicalIntent = "canonical_intent"
        case moodCategories = "mood_categories"
        case flavorTags = "flavor_tags"
        case intentConfidence = "intent_confidence"
        case searchPlan = "search_plan"
        case stationPolicy = "station_policy"
        case isCached = "is_cached"
    }

    /// Convert to SearchPlan model
    func toSearchPlan() -> SearchPlan {
        SearchPlan(
            canonicalIntent: canonicalIntent,
            moodCategories: moodCategories,
            flavorTags: flavorTags,
            intentConfidence: intentConfidence,
            playlistSearches: searchPlan.playlistSearches,
            catalogSearches: searchPlan.catalogSearches,
            artistSeedConfig: searchPlan.artistSeedConfig,
            stationPolicy: stationPolicy,
            isCached: isCached
        )
    }
}

/// Request to get a candidate pool
struct GetCandidatePoolRequest: Codable {
    let canonicalIntentHash: String
    let platform: MusicPlatform
    let limit: Int?
    let excludeTrackIds: [String]?

    enum CodingKeys: String, CodingKey {
        case canonicalIntentHash = "canonical_intent_hash"
        case platform
        case limit
        case excludeTrackIds = "exclude_track_ids"
    }
}

/// Response from get-candidate-pool Edge Function
struct GetCandidatePoolResponse: Codable {
    let poolId: String
    let canonicalIntent: String
    let tracks: [PoolTrackResponse]
    let poolMetadata: PoolMetadata

    struct PoolTrackResponse: Codable {
        let id: String
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
            case trackId = "track_id"
            case artistId = "artist_id"
            case isrc
            case source
            case sourceDetail = "source_detail"
            case addedAt = "added_at"
            case lastServedAt = "last_served_at"
            case serveCount = "serve_count"
        }

        func toPoolTrack() -> PoolTrack? {
            guard let trackId = UUID(uuidString: id),
                  let source = TrackSource(rawValue: source) else {
                return nil
            }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let addedDate = dateFormatter.date(from: addedAt) ?? Date()
            let lastServed = lastServedAt.flatMap { dateFormatter.date(from: $0) }

            return PoolTrack(
                id: trackId,
                trackId: self.trackId,
                artistId: artistId,
                isrc: isrc,
                source: source,
                sourceDetail: sourceDetail,
                addedAt: addedDate,
                lastServedAt: lastServed,
                serveCount: serveCount
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case poolId = "pool_id"
        case canonicalIntent = "canonical_intent"
        case tracks
        case poolMetadata = "pool_metadata"
    }
}

/// Request to refresh a candidate pool
struct RefreshCandidatePoolRequest: Codable {
    let canonicalIntentHash: String
    let platform: MusicPlatform
    let refreshPercentage: Double
    let newTracks: [NewPoolTrack]?

    struct NewPoolTrack: Codable {
        let trackId: String
        let artistId: String
        let isrc: String?
        let source: TrackSource
        let sourceDetail: String?

        enum CodingKeys: String, CodingKey {
            case trackId = "track_id"
            case artistId = "artist_id"
            case isrc
            case source
            case sourceDetail = "source_detail"
        }
    }

    enum CodingKeys: String, CodingKey {
        case canonicalIntentHash = "canonical_intent_hash"
        case platform
        case refreshPercentage = "refresh_percentage"
        case newTracks = "new_tracks"
    }
}

/// Response from refresh-candidate-pool Edge Function
struct RefreshCandidatePoolResponse: Codable {
    let success: Bool
    let poolId: String
    let tracksAdded: Int
    let tracksEvicted: Int
    let newTrackCount: Int

    enum CodingKeys: String, CodingKey {
        case success
        case poolId = "pool_id"
        case tracksAdded = "tracks_added"
        case tracksEvicted = "tracks_evicted"
        case newTrackCount = "new_track_count"
    }
}
