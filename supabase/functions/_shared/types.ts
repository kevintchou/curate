/**
 * Shared types for Curate Edge Functions
 * These mirror the Swift types in LLMStationTypes.swift
 */

// MARK: - Feature Range

export interface FeatureRange {
  min: number;
  max: number;
}

// MARK: - Station Config

export interface StationConfig {
  name: string;
  description: string;
  contextDescription: string;
  valenceRange?: FeatureRange;
  energyRange?: FeatureRange;
  danceabilityRange?: FeatureRange;
  bpmRange?: FeatureRange;
  acousticnessRange?: FeatureRange;
  instrumentalnessRange?: FeatureRange;
  valenceWeight: number;
  energyWeight: number;
  danceabilityWeight: number;
  bpmWeight: number;
  acousticnessWeight: number;
  instrumentalnessWeight: number;
  suggestedGenres: string[];
  suggestedDecades?: number[];
  moodKeywords: string[];
}

// MARK: - Taste Profile

export interface TasteProfile {
  preferredGenres: string[];
  avoidedGenres: string[];
  preferredArtists: string[];
  avoidedArtists: string[];
  preferredDecades: number[];
  energyPreference: string;
  moodPreference: string;
  notablePatterns: string[];
}

// MARK: - Song Suggestion

export interface SongSuggestion {
  title: string;
  artist: string;
  album?: string;
  year?: number;
  reason: string;
  estimatedBpm?: number;
  estimatedEnergy?: number;
  estimatedValence?: number;
  estimatedDanceability?: number;
  estimatedAcousticness?: number;
  estimatedInstrumentalness?: number;
}

// MARK: - Feedback Summary

export interface SongInfo {
  title: string;
  artist: string;
  genre?: string;
}

export interface FeedbackSummary {
  totalLikes: number;
  totalDislikes: number;
  totalSkips: number;
  likedSongs: SongInfo[];
  dislikedSongs: SongInfo[];
}

// MARK: - Request Types

export interface GenerateConfigRequest {
  prompt: string;
  tasteProfile?: TasteProfile;
}

export interface SuggestSongsRequest {
  config: StationConfig & { originalPrompt: string };
  likedSongs: Array<{ title: string; artist: string }>;
  dislikedSongs: Array<{ title: string; artist: string }>;
  recentlyPlayed: string[];
  count: number;
}

export interface AnalyzeTasteRequest {
  originalPrompt: string;
  currentProfile?: TasteProfile;
  feedbackSummary: FeedbackSummary;
}

// MARK: - Response Types

export interface GenerateConfigResponse extends StationConfig {}

export interface SuggestSongsResponse {
  songs: SongSuggestion[];
}

export interface AnalyzeTasteResponse extends TasteProfile {}

// MARK: - Error Response

export interface ErrorResponse {
  error: {
    code: string;
    message: string;
    details?: unknown;
  };
}

// Error codes
export const ErrorCodes = {
  INVALID_REQUEST: "INVALID_REQUEST",
  MISSING_FIELD: "MISSING_FIELD",
  LLM_ERROR: "LLM_ERROR",
  PARSE_ERROR: "PARSE_ERROR",
  UNAUTHORIZED: "UNAUTHORIZED",
  RATE_LIMITED: "RATE_LIMITED",
  INTERNAL_ERROR: "INTERNAL_ERROR",
} as const;

// ============================================================================
// MARK: - Hybrid Candidate Pool Types
// ============================================================================

export type MusicPlatform = "apple_music" | "spotify";
export type TrackSource = "playlist" | "search" | "artist_seed" | "related_artist";

// MARK: - Search Plan Types

export interface PlaylistSearch {
  term: string;
  priority: number;
}

export interface CatalogSearch {
  term: string;
  genres?: string[];
}

export interface ArtistSeedFallbackConfig {
  seedCount: number;
  similarityRatios: {
    direct: number;
    adjacent: number;
    discovery: number;
  };
}

export interface StationPolicy {
  playlistSourceRatio: number;
  searchSourceRatio: number;
  artistSeedSourceRatio: number;
  explorationWeight: number;
  artistRepeatWindow: number;
}

export interface SearchPlan {
  canonicalIntent: string;
  moodCategories: string[];
  flavorTags: string[];
  intentConfidence: number;
  playlistSearches: PlaylistSearch[];
  catalogSearches: CatalogSearch[];
  artistSeedConfig?: ArtistSeedFallbackConfig;
  stationPolicy: StationPolicy;
}

// MARK: - Candidate Pool Types

export interface PoolTrack {
  id: string;
  trackId: string;
  artistId: string;
  isrc?: string;
  source: TrackSource;
  sourceDetail?: string;
  addedAt: string;
  lastServedAt?: string;
  serveCount: number;
}

export interface CandidatePool {
  id: string;
  canonicalIntentHash: string;
  canonicalIntent: string;
  platform: MusicPlatform;
  trackCount: number;
  createdAt: string;
  updatedAt: string;
  softTtlAt: string;
  hardTtlAt: string;
  refreshInProgress: boolean;
  strategiesUsed: string[];
  strategiesExhausted: string[];
}

export interface PoolMetadata {
  trackCount: number;
  isStale: boolean;
  needsRefresh: boolean;
  strategiesExhausted: string[];
}

// MARK: - Request Types for Hybrid Pool

export interface GenerateSearchPlanRequest {
  prompt: string;
  platform: MusicPlatform;
}

export interface GenerateSearchPlanResponse {
  canonicalIntent: string;
  moodCategories: string[];
  flavorTags: string[];
  intentConfidence: number;
  searchPlan: {
    playlistSearches: PlaylistSearch[];
    catalogSearches: CatalogSearch[];
    artistSeedConfig?: ArtistSeedFallbackConfig;
  };
  stationPolicy: StationPolicy;
  isCached: boolean;
}

export interface GetCandidatePoolRequest {
  canonicalIntentHash: string;
  platform: MusicPlatform;
  limit?: number;
  excludeTrackIds?: string[];
}

export interface GetCandidatePoolResponse {
  poolId: string;
  canonicalIntent: string;
  tracks: PoolTrack[];
  poolMetadata: PoolMetadata;
}

export interface RefreshCandidatePoolRequest {
  canonicalIntentHash: string;
  platform: MusicPlatform;
  refreshPercentage: number;
  newTracks?: Array<{
    trackId: string;
    artistId: string;
    isrc?: string;
    source: TrackSource;
    sourceDetail?: string;
  }>;
}

export interface RefreshCandidatePoolResponse {
  success: boolean;
  poolId: string;
  tracksAdded: number;
  tracksEvicted: number;
  newTrackCount: number;
}

// MARK: - Intent Mapping Types

export interface IntentMapping {
  id: string;
  rawPromptHash: string;
  rawPrompt: string;
  canonicalIntent: string;
  moodCategories: string[];
  flavorTags: string[];
  occurrenceCount: number;
  platform: MusicPlatform;
}
