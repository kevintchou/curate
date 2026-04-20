/**
 * Get Candidate Pool Edge Function
 *
 * POST /functions/v1/get-candidate-pool
 *
 * Returns tracks from a global candidate pool for client-side selection.
 * Supports filtering out already-played tracks.
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors } from "../_shared/cors.ts";
import {
  badRequest,
  missingField,
  internalError,
  successResponse,
  unauthorized,
} from "../_shared/errors.ts";
import {
  GetCandidatePoolRequest,
  GetCandidatePoolResponse,
  PoolTrack,
  PoolMetadata,
  MusicPlatform,
} from "../_shared/types.ts";

// MARK: - Constants

const DEFAULT_LIMIT = 500;
const MAX_LIMIT = 1000;

// MARK: - Database Types

interface PoolRow {
  id: string;
  canonical_intent_hash: string;
  canonical_intent: string;
  platform: string;
  track_count: number;
  created_at: string;
  updated_at: string;
  soft_ttl_at: string;
  hard_ttl_at: string;
  refresh_in_progress: boolean;
  strategies_used: string[];
  strategies_exhausted: string[];
}

interface PoolTrackRow {
  id: string;
  pool_id: string;
  track_id: string;
  artist_id: string;
  isrc: string | null;
  source: string;
  source_detail: string | null;
  added_at: string;
  last_served_at: string | null;
  serve_count: number;
}

// MARK: - Handler

serve(async (req: Request) => {
  // Handle CORS preflight
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  // Only allow POST
  if (req.method !== "POST") {
    return badRequest("Method not allowed. Use POST.");
  }

  try {
    console.log("📥 get-candidate-pool: Request received");

    // Verify JWT authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return unauthorized("Missing or invalid Authorization header");
    }

    const token = authHeader.replace("Bearer ", "");

    // Create Supabase clients
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !supabaseAnonKey) {
      return internalError("Supabase configuration missing");
    }

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    // Verify the JWT
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser(token);

    if (authError || !user) {
      console.log("❌ get-candidate-pool: Auth failed", authError?.message);
      return unauthorized("Invalid or expired token");
    }

    console.log(`✅ get-candidate-pool: Authenticated user ${user.id}`);

    // Parse request body
    const body: GetCandidatePoolRequest = await req.json();

    // Validate required fields
    if (!body.canonicalIntentHash || typeof body.canonicalIntentHash !== "string") {
      return missingField("canonicalIntentHash");
    }

    if (!body.platform || !["apple_music", "spotify"].includes(body.platform)) {
      return badRequest("platform must be 'apple_music' or 'spotify'");
    }

    const platform = body.platform as MusicPlatform;
    const limit = Math.min(body.limit || DEFAULT_LIMIT, MAX_LIMIT);
    const excludeTrackIds = body.excludeTrackIds || [];

    console.log(
      `📝 get-candidate-pool: Hash = ${body.canonicalIntentHash.substring(0, 16)}..., ` +
        `Platform = ${platform}, Limit = ${limit}, Exclude = ${excludeTrackIds.length} tracks`
    );

    // Step 1: Get pool metadata
    const { data: poolData, error: poolError } = await supabase
      .from("candidate_pools")
      .select("*")
      .eq("canonical_intent_hash", body.canonicalIntentHash)
      .eq("platform", platform)
      .single();

    if (poolError || !poolData) {
      console.log(`📭 get-candidate-pool: Pool not found`);
      // Return empty response - client will need to build pool
      const emptyResponse: GetCandidatePoolResponse = {
        poolId: "",
        canonicalIntent: "",
        tracks: [],
        poolMetadata: {
          trackCount: 0,
          isStale: true,
          needsRefresh: true,
          strategiesExhausted: [],
        },
      };
      return successResponse(emptyResponse);
    }

    const pool = poolData as PoolRow;
    const now = new Date();
    const softTtl = new Date(pool.soft_ttl_at);
    const hardTtl = new Date(pool.hard_ttl_at);

    const isStale = now > softTtl;
    const isExpired = now > hardTtl;
    const needsRefresh = isStale && !isExpired && !pool.refresh_in_progress;

    console.log(
      `📦 get-candidate-pool: Found pool "${pool.canonical_intent}" ` +
        `(${pool.track_count} tracks, stale=${isStale}, expired=${isExpired})`
    );

    // Step 2: Get pool tracks
    let query = supabase
      .from("candidate_pool_tracks")
      .select("*")
      .eq("pool_id", pool.id)
      .order("added_at", { ascending: false })
      .limit(limit);

    // Exclude already-played tracks if specified
    if (excludeTrackIds.length > 0) {
      // Supabase doesn't support NOT IN directly, so we filter in batches
      // For large exclude lists, this should be done client-side
      if (excludeTrackIds.length <= 100) {
        query = query.not("track_id", "in", `(${excludeTrackIds.join(",")})`);
      }
    }

    const { data: tracksData, error: tracksError } = await query;

    if (tracksError) {
      console.error("Error fetching tracks:", tracksError);
      return internalError("Failed to fetch pool tracks");
    }

    const trackRows = (tracksData || []) as PoolTrackRow[];

    // Filter out excluded tracks if we have a large exclude list
    let filteredTracks = trackRows;
    if (excludeTrackIds.length > 100) {
      const excludeSet = new Set(excludeTrackIds);
      filteredTracks = trackRows.filter((t) => !excludeSet.has(t.track_id));
    }

    // Map to response format
    const tracks: PoolTrack[] = filteredTracks.map((row) => ({
      id: row.id,
      trackId: row.track_id,
      artistId: row.artist_id,
      isrc: row.isrc || undefined,
      source: row.source as PoolTrack["source"],
      sourceDetail: row.source_detail || undefined,
      addedAt: row.added_at,
      lastServedAt: row.last_served_at || undefined,
      serveCount: row.serve_count,
    }));

    const poolMetadata: PoolMetadata = {
      trackCount: pool.track_count,
      isStale,
      needsRefresh,
      strategiesExhausted: pool.strategies_exhausted || [],
    };

    const response: GetCandidatePoolResponse = {
      poolId: pool.id,
      canonicalIntent: pool.canonical_intent,
      tracks,
      poolMetadata,
    };

    console.log(
      `✅ get-candidate-pool: Returning ${tracks.length} tracks ` +
        `(needsRefresh=${needsRefresh})`
    );

    return successResponse(response);
  } catch (error) {
    console.error("Error in get-candidate-pool:", error);

    if (error instanceof Error) {
      return internalError(error.message);
    }

    return internalError("An unexpected error occurred");
  }
});
