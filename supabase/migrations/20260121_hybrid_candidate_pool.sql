-- ============================================================================
-- HYBRID CANDIDATE POOL ARCHITECTURE
-- Migration: 20260121_hybrid_candidate_pool.sql
--
-- This migration creates the database schema for the hybrid candidate pool
-- recommendation system. Run this in the Supabase SQL Editor or via CLI.
-- ============================================================================

-- ============================================================================
-- TABLE 1: intent_mappings
-- Maps raw user prompts to canonical intents. Grows over time as patterns emerge.
-- ============================================================================

CREATE TABLE IF NOT EXISTS intent_mappings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    raw_prompt_hash TEXT NOT NULL,              -- SHA256 of lowercased, trimmed prompt
    raw_prompt TEXT NOT NULL,                   -- Original prompt for debugging
    canonical_intent TEXT NOT NULL,             -- e.g., "relaxed-driving-mood"
    mood_categories TEXT[] DEFAULT '{}',        -- e.g., ["chill", "evening", "driving"]
    flavor_tags TEXT[] DEFAULT '{}',            -- e.g., ["sunset", "golden-hour"]
    occurrence_count INTEGER DEFAULT 1,
    platform TEXT NOT NULL,                     -- "apple_music" | "spotify"
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT intent_mappings_platform_check CHECK (platform IN ('apple_music', 'spotify')),
    CONSTRAINT intent_mappings_unique UNIQUE(raw_prompt_hash, platform)
);

-- Indexes for intent_mappings
CREATE INDEX IF NOT EXISTS idx_intent_mappings_canonical
    ON intent_mappings(canonical_intent, platform);
CREATE INDEX IF NOT EXISTS idx_intent_mappings_prompt_hash
    ON intent_mappings(raw_prompt_hash);
CREATE INDEX IF NOT EXISTS idx_intent_mappings_occurrence
    ON intent_mappings(occurrence_count DESC);

-- Trigger to update updated_at
CREATE OR REPLACE FUNCTION update_intent_mappings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER intent_mappings_updated_at
    BEFORE UPDATE ON intent_mappings
    FOR EACH ROW
    EXECUTE FUNCTION update_intent_mappings_updated_at();

COMMENT ON TABLE intent_mappings IS 'Maps raw user prompts to canonical intents for cache efficiency';
COMMENT ON COLUMN intent_mappings.raw_prompt_hash IS 'SHA256 hash of lowercased, trimmed prompt';
COMMENT ON COLUMN intent_mappings.canonical_intent IS 'Normalized intent ID (e.g., relaxed-driving-mood)';
COMMENT ON COLUMN intent_mappings.occurrence_count IS 'Number of times this prompt has been seen (threshold: 3 for caching)';


-- ============================================================================
-- TABLE 2: search_plan_cache
-- Stores LLM-generated search plans per canonical intent.
-- ============================================================================

CREATE TABLE IF NOT EXISTS search_plan_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_intent TEXT NOT NULL,
    platform TEXT NOT NULL,                     -- "apple_music" | "spotify"

    -- Search strategies (JSONB for flexibility)
    playlist_searches JSONB NOT NULL DEFAULT '[]',   -- [{term: "sunset vibes", priority: 1}, ...]
    catalog_searches JSONB DEFAULT '[]',             -- [{term: "chill acoustic", genres: [...]}]
    artist_seed_config JSONB DEFAULT NULL,           -- Fallback config if needed

    -- Mood/activity metadata
    mood_categories TEXT[] DEFAULT '{}',
    activity_tags TEXT[] DEFAULT '{}',

    -- Station policy tweaks (LLM-suggested)
    suggested_exploration_weight FLOAT DEFAULT 0.3,
    suggested_source_mix JSONB DEFAULT '{"playlist": 0.55, "search": 0.25, "artist_seed": 0.20}',
    artist_repeat_window INTEGER DEFAULT 10,

    -- Intent confidence (0-1, low triggers artist seed fallback)
    intent_confidence FLOAT DEFAULT 0.8,

    -- Cache metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,            -- Typically created_at + 7 days
    refresh_count INTEGER DEFAULT 0,

    CONSTRAINT search_plan_platform_check CHECK (platform IN ('apple_music', 'spotify')),
    CONSTRAINT search_plan_exploration_check CHECK (suggested_exploration_weight >= 0 AND suggested_exploration_weight <= 1),
    CONSTRAINT search_plan_confidence_check CHECK (intent_confidence >= 0 AND intent_confidence <= 1),
    CONSTRAINT search_plan_unique UNIQUE(canonical_intent, platform)
);

-- Indexes for search_plan_cache
CREATE INDEX IF NOT EXISTS idx_search_plan_canonical
    ON search_plan_cache(canonical_intent, platform);
CREATE INDEX IF NOT EXISTS idx_search_plan_expires
    ON search_plan_cache(expires_at);

COMMENT ON TABLE search_plan_cache IS 'LLM-generated search plans cached per canonical intent';
COMMENT ON COLUMN search_plan_cache.playlist_searches IS 'Array of playlist search terms with priorities';
COMMENT ON COLUMN search_plan_cache.intent_confidence IS '0-1 score; low values trigger artist seed fallback';


-- ============================================================================
-- TABLE 3: candidate_pools
-- Global shared candidate pools per intent. Metadata only - tracks in separate table.
-- ============================================================================

CREATE TABLE IF NOT EXISTS candidate_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_intent_hash TEXT NOT NULL,        -- SHA256 of canonical_intent
    canonical_intent TEXT NOT NULL,             -- Human-readable for debugging
    platform TEXT NOT NULL,

    -- Pool metadata
    track_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    soft_ttl_at TIMESTAMPTZ NOT NULL,           -- created_at + 6 hours (triggers refresh)
    hard_ttl_at TIMESTAMPTZ NOT NULL,           -- created_at + 24-48 hours (requires rebuild)

    -- Refresh tracking
    last_refresh_at TIMESTAMPTZ,
    refresh_in_progress BOOLEAN DEFAULT FALSE,
    refresh_lock_at TIMESTAMPTZ,                -- When lock was acquired (for timeout)
    strategies_used TEXT[] DEFAULT '{}',        -- Track which strategies populated this
    strategies_exhausted TEXT[] DEFAULT '{}',   -- Strategies with no more results

    CONSTRAINT candidate_pools_platform_check CHECK (platform IN ('apple_music', 'spotify')),
    CONSTRAINT candidate_pools_unique UNIQUE(canonical_intent_hash, platform)
);

-- Indexes for candidate_pools
CREATE INDEX IF NOT EXISTS idx_candidate_pools_hash
    ON candidate_pools(canonical_intent_hash, platform);
CREATE INDEX IF NOT EXISTS idx_candidate_pools_soft_ttl
    ON candidate_pools(soft_ttl_at);
CREATE INDEX IF NOT EXISTS idx_candidate_pools_hard_ttl
    ON candidate_pools(hard_ttl_at);
CREATE INDEX IF NOT EXISTS idx_candidate_pools_refresh
    ON candidate_pools(refresh_in_progress) WHERE refresh_in_progress = TRUE;

-- Trigger to update updated_at
CREATE OR REPLACE FUNCTION update_candidate_pools_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER candidate_pools_updated_at
    BEFORE UPDATE ON candidate_pools
    FOR EACH ROW
    EXECUTE FUNCTION update_candidate_pools_updated_at();

COMMENT ON TABLE candidate_pools IS 'Global shared candidate pools per canonical intent';
COMMENT ON COLUMN candidate_pools.soft_ttl_at IS 'When pool becomes stale and triggers incremental refresh';
COMMENT ON COLUMN candidate_pools.hard_ttl_at IS 'When pool expires and requires full rebuild';
COMMENT ON COLUMN candidate_pools.refresh_lock_at IS 'Timestamp of lock acquisition for timeout handling';


-- ============================================================================
-- TABLE 4: candidate_pool_tracks
-- Individual tracks in candidate pools.
-- ============================================================================

CREATE TABLE IF NOT EXISTS candidate_pool_tracks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pool_id UUID NOT NULL REFERENCES candidate_pools(id) ON DELETE CASCADE,

    -- Track identifiers
    track_id TEXT NOT NULL,                     -- Platform-specific ID (Apple Music catalog ID)
    artist_id TEXT NOT NULL,                    -- Platform-specific artist ID
    isrc TEXT,                                  -- For cross-platform deduplication

    -- Source tracking
    source TEXT NOT NULL,                       -- "playlist" | "search" | "artist_seed" | "related_artist"
    source_detail TEXT,                         -- e.g., "playlist:sunset-vibes-2024" or "search:chill+acoustic"

    -- Lifecycle
    added_at TIMESTAMPTZ DEFAULT NOW(),
    last_served_at TIMESTAMPTZ,                 -- When last selected for a user
    serve_count INTEGER DEFAULT 0,              -- How many times selected globally

    CONSTRAINT pool_tracks_source_check CHECK (source IN ('playlist', 'search', 'artist_seed', 'related_artist')),
    CONSTRAINT pool_tracks_unique UNIQUE(pool_id, track_id)
);

-- Indexes for candidate_pool_tracks
CREATE INDEX IF NOT EXISTS idx_pool_tracks_pool
    ON candidate_pool_tracks(pool_id);
CREATE INDEX IF NOT EXISTS idx_pool_tracks_isrc
    ON candidate_pool_tracks(isrc) WHERE isrc IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pool_tracks_added
    ON candidate_pool_tracks(pool_id, added_at DESC);
CREATE INDEX IF NOT EXISTS idx_pool_tracks_source
    ON candidate_pool_tracks(pool_id, source);
CREATE INDEX IF NOT EXISTS idx_pool_tracks_served
    ON candidate_pool_tracks(pool_id, serve_count DESC);

COMMENT ON TABLE candidate_pool_tracks IS 'Individual tracks in global candidate pools';
COMMENT ON COLUMN candidate_pool_tracks.source IS 'How this track was discovered (playlist, search, artist_seed, related_artist)';
COMMENT ON COLUMN candidate_pool_tracks.source_detail IS 'Specific source identifier for debugging/analytics';


-- ============================================================================
-- TABLE 5: user_station_overlay
-- Per-user, per-station state for filtering and personalization.
-- ============================================================================

CREATE TABLE IF NOT EXISTS user_station_overlay (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    station_id UUID NOT NULL,                   -- References local Station.id (client-side)
    canonical_intent TEXT NOT NULL,             -- Links to the pool being used

    -- Recent history (for this station)
    recent_track_ids TEXT[] DEFAULT '{}',       -- Last 100 track IDs played
    recent_track_isrcs TEXT[] DEFAULT '{}',     -- Last 100 ISRCs played
    recent_artist_ids TEXT[] DEFAULT '{}',      -- Last 50 artist IDs

    -- Skip tracking
    session_skip_count INTEGER DEFAULT 0,
    session_started_at TIMESTAMPTZ,
    total_skip_count INTEGER DEFAULT 0,
    skipped_track_ids TEXT[] DEFAULT '{}',      -- Tracks skipped (for pattern analysis)

    -- Exploration state
    current_exploration_weight FLOAT DEFAULT 0.3,
    base_exploration_weight FLOAT DEFAULT 0.3,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_played_at TIMESTAMPTZ,

    CONSTRAINT overlay_exploration_check CHECK (current_exploration_weight >= 0 AND current_exploration_weight <= 1),
    CONSTRAINT overlay_base_exploration_check CHECK (base_exploration_weight >= 0 AND base_exploration_weight <= 1),
    CONSTRAINT overlay_unique UNIQUE(user_id, station_id)
);

-- Indexes for user_station_overlay
CREATE INDEX IF NOT EXISTS idx_overlay_user_station
    ON user_station_overlay(user_id, station_id);
CREATE INDEX IF NOT EXISTS idx_overlay_user
    ON user_station_overlay(user_id);
CREATE INDEX IF NOT EXISTS idx_overlay_canonical
    ON user_station_overlay(canonical_intent);
CREATE INDEX IF NOT EXISTS idx_overlay_last_played
    ON user_station_overlay(user_id, last_played_at DESC);

-- Trigger to update updated_at
CREATE OR REPLACE FUNCTION update_user_station_overlay_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER user_station_overlay_updated_at
    BEFORE UPDATE ON user_station_overlay
    FOR EACH ROW
    EXECUTE FUNCTION update_user_station_overlay_updated_at();

COMMENT ON TABLE user_station_overlay IS 'Per-user, per-station state for filtering global pools';
COMMENT ON COLUMN user_station_overlay.recent_track_ids IS 'Circular buffer of last 100 played track IDs';
COMMENT ON COLUMN user_station_overlay.current_exploration_weight IS 'Current session exploration (decays with skips)';


-- ============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE intent_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE search_plan_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidate_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidate_pool_tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_station_overlay ENABLE ROW LEVEL SECURITY;

-- intent_mappings: Read-only for authenticated users, write via service role (Edge Functions)
CREATE POLICY "Authenticated users can read intent mappings"
    ON intent_mappings FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Service role can manage intent mappings"
    ON intent_mappings FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- search_plan_cache: Read-only for authenticated users
CREATE POLICY "Authenticated users can read search plans"
    ON search_plan_cache FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Service role can manage search plans"
    ON search_plan_cache FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- candidate_pools: Read-only for authenticated users
CREATE POLICY "Authenticated users can read pools"
    ON candidate_pools FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Service role can manage pools"
    ON candidate_pools FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- candidate_pool_tracks: Read-only for authenticated users
CREATE POLICY "Authenticated users can read pool tracks"
    ON candidate_pool_tracks FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Service role can manage pool tracks"
    ON candidate_pool_tracks FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- user_station_overlay: Users can only access their own data
CREATE POLICY "Users can read own overlays"
    ON user_station_overlay FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own overlays"
    ON user_station_overlay FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own overlays"
    ON user_station_overlay FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own overlays"
    ON user_station_overlay FOR DELETE
    TO authenticated
    USING (auth.uid() = user_id);

CREATE POLICY "Service role can manage all overlays"
    ON user_station_overlay FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);


-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function to update pool track count
CREATE OR REPLACE FUNCTION update_pool_track_count()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE candidate_pools
        SET track_count = track_count + 1
        WHERE id = NEW.pool_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE candidate_pools
        SET track_count = track_count - 1
        WHERE id = OLD.pool_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pool_track_count_trigger
    AFTER INSERT OR DELETE ON candidate_pool_tracks
    FOR EACH ROW
    EXECUTE FUNCTION update_pool_track_count();

-- Function to acquire pool refresh lock (with 5 minute timeout)
CREATE OR REPLACE FUNCTION acquire_pool_refresh_lock(p_pool_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    lock_acquired BOOLEAN;
BEGIN
    UPDATE candidate_pools
    SET refresh_in_progress = TRUE,
        refresh_lock_at = NOW()
    WHERE id = p_pool_id
      AND (refresh_in_progress = FALSE
           OR refresh_lock_at < NOW() - INTERVAL '5 minutes')
    RETURNING TRUE INTO lock_acquired;

    RETURN COALESCE(lock_acquired, FALSE);
END;
$$ LANGUAGE plpgsql;

-- Function to release pool refresh lock
CREATE OR REPLACE FUNCTION release_pool_refresh_lock(p_pool_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE candidate_pools
    SET refresh_in_progress = FALSE,
        refresh_lock_at = NULL,
        last_refresh_at = NOW()
    WHERE id = p_pool_id;
END;
$$ LANGUAGE plpgsql;

-- Function to evict oldest tracks from pool (maintains cap)
CREATE OR REPLACE FUNCTION evict_pool_tracks(p_pool_id UUID, p_max_tracks INTEGER DEFAULT 1000)
RETURNS INTEGER AS $$
DECLARE
    current_count INTEGER;
    tracks_to_evict INTEGER;
    evicted INTEGER;
BEGIN
    SELECT track_count INTO current_count
    FROM candidate_pools WHERE id = p_pool_id;

    IF current_count <= p_max_tracks THEN
        RETURN 0;
    END IF;

    tracks_to_evict := current_count - p_max_tracks;

    -- Evict oldest, least-served tracks first
    WITH to_delete AS (
        SELECT id FROM candidate_pool_tracks
        WHERE pool_id = p_pool_id
        ORDER BY serve_count ASC, added_at ASC
        LIMIT tracks_to_evict
    )
    DELETE FROM candidate_pool_tracks
    WHERE id IN (SELECT id FROM to_delete);

    GET DIAGNOSTICS evicted = ROW_COUNT;
    RETURN evicted;
END;
$$ LANGUAGE plpgsql;

-- Function to increment intent mapping occurrence count
CREATE OR REPLACE FUNCTION upsert_intent_mapping(
    p_raw_prompt TEXT,
    p_canonical_intent TEXT,
    p_mood_categories TEXT[],
    p_flavor_tags TEXT[],
    p_platform TEXT
)
RETURNS TABLE(id UUID, occurrence_count INTEGER, is_new BOOLEAN) AS $$
DECLARE
    prompt_hash TEXT;
    result_id UUID;
    result_count INTEGER;
    result_is_new BOOLEAN;
BEGIN
    -- Generate hash of lowercased, trimmed prompt
    prompt_hash := encode(sha256(lower(trim(p_raw_prompt))::bytea), 'hex');

    INSERT INTO intent_mappings (
        raw_prompt_hash,
        raw_prompt,
        canonical_intent,
        mood_categories,
        flavor_tags,
        platform,
        occurrence_count
    ) VALUES (
        prompt_hash,
        p_raw_prompt,
        p_canonical_intent,
        p_mood_categories,
        p_flavor_tags,
        p_platform,
        1
    )
    ON CONFLICT (raw_prompt_hash, platform) DO UPDATE SET
        occurrence_count = intent_mappings.occurrence_count + 1,
        updated_at = NOW()
    RETURNING
        intent_mappings.id,
        intent_mappings.occurrence_count,
        (intent_mappings.occurrence_count = 1) AS is_new
    INTO result_id, result_count, result_is_new;

    RETURN QUERY SELECT result_id, result_count, result_is_new;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- VIEWS FOR ANALYTICS
-- ============================================================================

-- View: Pool health metrics
CREATE OR REPLACE VIEW pool_health_metrics AS
SELECT
    cp.id,
    cp.canonical_intent,
    cp.platform,
    cp.track_count,
    cp.created_at,
    cp.soft_ttl_at,
    cp.hard_ttl_at,
    cp.refresh_in_progress,
    CASE
        WHEN NOW() > cp.hard_ttl_at THEN 'expired'
        WHEN NOW() > cp.soft_ttl_at THEN 'stale'
        ELSE 'fresh'
    END AS status,
    EXTRACT(EPOCH FROM (cp.soft_ttl_at - NOW())) / 3600 AS hours_until_stale,
    array_length(cp.strategies_used, 1) AS strategies_used_count,
    array_length(cp.strategies_exhausted, 1) AS strategies_exhausted_count
FROM candidate_pools cp;

COMMENT ON VIEW pool_health_metrics IS 'Dashboard view for monitoring pool health and TTL status';

-- View: Source distribution per pool
CREATE OR REPLACE VIEW pool_source_distribution AS
SELECT
    pool_id,
    source,
    COUNT(*) AS track_count,
    ROUND(COUNT(*)::NUMERIC / SUM(COUNT(*)) OVER (PARTITION BY pool_id) * 100, 2) AS percentage
FROM candidate_pool_tracks
GROUP BY pool_id, source
ORDER BY pool_id, track_count DESC;

COMMENT ON VIEW pool_source_distribution IS 'Shows track source distribution within each pool';


-- ============================================================================
-- GRANTS (for Edge Functions using service_role)
-- ============================================================================

-- These are typically handled by Supabase automatically, but explicit for clarity
GRANT SELECT ON intent_mappings TO authenticated;
GRANT SELECT ON search_plan_cache TO authenticated;
GRANT SELECT ON candidate_pools TO authenticated;
GRANT SELECT ON candidate_pool_tracks TO authenticated;
GRANT ALL ON user_station_overlay TO authenticated;

GRANT ALL ON intent_mappings TO service_role;
GRANT ALL ON search_plan_cache TO service_role;
GRANT ALL ON candidate_pools TO service_role;
GRANT ALL ON candidate_pool_tracks TO service_role;
GRANT ALL ON user_station_overlay TO service_role;

GRANT SELECT ON pool_health_metrics TO authenticated;
GRANT SELECT ON pool_source_distribution TO authenticated;


-- ============================================================================
-- MIGRATION COMPLETE
-- ============================================================================

-- Verify tables were created
DO $$
BEGIN
    RAISE NOTICE 'Migration complete. Created tables:';
    RAISE NOTICE '  - intent_mappings';
    RAISE NOTICE '  - search_plan_cache';
    RAISE NOTICE '  - candidate_pools';
    RAISE NOTICE '  - candidate_pool_tracks';
    RAISE NOTICE '  - user_station_overlay';
    RAISE NOTICE '';
    RAISE NOTICE 'Created views:';
    RAISE NOTICE '  - pool_health_metrics';
    RAISE NOTICE '  - pool_source_distribution';
    RAISE NOTICE '';
    RAISE NOTICE 'Created functions:';
    RAISE NOTICE '  - acquire_pool_refresh_lock(pool_id)';
    RAISE NOTICE '  - release_pool_refresh_lock(pool_id)';
    RAISE NOTICE '  - evict_pool_tracks(pool_id, max_tracks)';
    RAISE NOTICE '  - upsert_intent_mapping(...)';
END $$;
