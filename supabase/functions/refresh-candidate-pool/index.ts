/**
 * Refresh Candidate Pool Edge Function
 *
 * POST /functions/v1/refresh-candidate-pool
 *
 * Handles incremental pool refresh (25% by default).
 * Client provides new tracks (since Edge Function can't call Apple Music).
 * Manages pool size cap and eviction of old tracks.
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
  RefreshCandidatePoolRequest,
  RefreshCandidatePoolResponse,
  MusicPlatform,
  TrackSource,
} from "../_shared/types.ts";

// MARK: - Constants

const MAX_POOL_SIZE = 1000;
const DEFAULT_SOFT_TTL_HOURS = 6;
const DEFAULT_HARD_TTL_HOURS = 24;

// MARK: - Database Types

interface PoolRow {
  id: string;
  canonical_intent_hash: string;
  canonical_intent: string;
  platform: string;
  track_count: number;
  refresh_in_progress: boolean;
  strategies_used: string[];
  strategies_exhausted: string[];
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
    console.log("📥 refresh-candidate-pool: Request received");

    // Verify JWT authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return unauthorized("Missing or invalid Authorization header");
    }

    const token = authHeader.replace("Bearer ", "");

    // Create Supabase clients
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
      return internalError("Supabase configuration missing");
    }

    // Auth client for verification
    const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Service client for database operations (bypasses RLS)
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Verify the JWT
    const {
      data: { user },
      error: authError,
    } = await supabaseAuth.auth.getUser(token);

    if (authError || !user) {
      console.log("❌ refresh-candidate-pool: Auth failed", authError?.message);
      return unauthorized("Invalid or expired token");
    }

    console.log(`✅ refresh-candidate-pool: Authenticated user ${user.id}`);

    // Parse request body
    const body: RefreshCandidatePoolRequest = await req.json();

    // Validate required fields
    if (!body.canonicalIntentHash || typeof body.canonicalIntentHash !== "string") {
      return missingField("canonicalIntentHash");
    }

    if (!body.platform || !["apple_music", "spotify"].includes(body.platform)) {
      return badRequest("platform must be 'apple_music' or 'spotify'");
    }

    const platform = body.platform as MusicPlatform;
    const refreshPercentage = Math.max(0.1, Math.min(1.0, body.refreshPercentage || 0.25));
    const newTracks = body.newTracks || [];

    console.log(
      `📝 refresh-candidate-pool: Hash = ${body.canonicalIntentHash.substring(0, 16)}..., ` +
        `Platform = ${platform}, RefreshPct = ${refreshPercentage * 100}%, ` +
        `NewTracks = ${newTracks.length}`
    );

    // Step 1: Get or create pool
    let { data: poolData, error: poolError } = await supabase
      .from("candidate_pools")
      .select("*")
      .eq("canonical_intent_hash", body.canonicalIntentHash)
      .eq("platform", platform)
      .single();

    let pool: PoolRow;
    let isNewPool = false;

    if (poolError || !poolData) {
      // Pool doesn't exist, create it
      console.log(`📦 refresh-candidate-pool: Creating new pool`);

      const now = new Date();
      const softTtl = new Date(now.getTime() + DEFAULT_SOFT_TTL_HOURS * 60 * 60 * 1000);
      const hardTtl = new Date(now.getTime() + DEFAULT_HARD_TTL_HOURS * 60 * 60 * 1000);

      const { data: newPoolData, error: createError } = await supabase
        .from("candidate_pools")
        .insert({
          canonical_intent_hash: body.canonicalIntentHash,
          canonical_intent: body.canonicalIntentHash.substring(0, 32) + "...", // Placeholder
          platform: platform,
          track_count: 0,
          soft_ttl_at: softTtl.toISOString(),
          hard_ttl_at: hardTtl.toISOString(),
          refresh_in_progress: true,
          strategies_used: [],
          strategies_exhausted: [],
        })
        .select()
        .single();

      if (createError || !newPoolData) {
        console.error("Failed to create pool:", createError);
        return internalError("Failed to create candidate pool");
      }

      pool = newPoolData as PoolRow;
      isNewPool = true;
    } else {
      pool = poolData as PoolRow;
    }

    // Step 2: Acquire refresh lock (if not new pool)
    if (!isNewPool) {
      const { data: lockResult } = await supabase
        .rpc("acquire_pool_refresh_lock", { p_pool_id: pool.id })
        .single();

      if (!lockResult) {
        console.log(`🔒 refresh-candidate-pool: Lock not acquired (refresh in progress)`);
        // Another refresh is in progress, return current state
        const response: RefreshCandidatePoolResponse = {
          success: false,
          poolId: pool.id,
          tracksAdded: 0,
          tracksEvicted: 0,
          newTrackCount: pool.track_count,
        };
        return successResponse(response);
      }
    }

    try {
      let tracksAdded = 0;
      let tracksEvicted = 0;

      // Step 3: Add new tracks (if provided)
      if (newTracks.length > 0) {
        // Deduplicate by track_id within the batch
        const seenTrackIds = new Set<string>();
        const uniqueTracks = newTracks.filter((t) => {
          if (seenTrackIds.has(t.trackId)) return false;
          seenTrackIds.add(t.trackId);
          return true;
        });

        // Check for existing tracks in pool to avoid duplicates
        const { data: existingTracks } = await supabase
          .from("candidate_pool_tracks")
          .select("track_id")
          .eq("pool_id", pool.id)
          .in(
            "track_id",
            uniqueTracks.map((t) => t.trackId)
          );

        const existingTrackIds = new Set((existingTracks || []).map((t) => t.track_id));

        const tracksToInsert = uniqueTracks
          .filter((t) => !existingTrackIds.has(t.trackId))
          .map((t) => ({
            pool_id: pool.id,
            track_id: t.trackId,
            artist_id: t.artistId,
            isrc: t.isrc || null,
            source: t.source,
            source_detail: t.sourceDetail || null,
            serve_count: 0,
          }));

        if (tracksToInsert.length > 0) {
          // Insert in batches to avoid request size limits
          const batchSize = 100;
          for (let i = 0; i < tracksToInsert.length; i += batchSize) {
            const batch = tracksToInsert.slice(i, i + batchSize);
            const { error: insertError } = await supabase
              .from("candidate_pool_tracks")
              .insert(batch);

            if (insertError) {
              console.error("Error inserting tracks:", insertError);
              // Continue with other batches
            } else {
              tracksAdded += batch.length;
            }
          }
        }

        console.log(
          `➕ refresh-candidate-pool: Added ${tracksAdded} tracks ` +
            `(${uniqueTracks.length - tracksAdded} duplicates skipped)`
        );
      }

      // Step 4: Evict old tracks if over cap
      // Get updated track count
      const { data: countData } = await supabase
        .from("candidate_pools")
        .select("track_count")
        .eq("id", pool.id)
        .single();

      const currentTrackCount = countData?.track_count || 0;

      if (currentTrackCount > MAX_POOL_SIZE) {
        const { data: evictResult } = await supabase
          .rpc("evict_pool_tracks", {
            p_pool_id: pool.id,
            p_max_tracks: MAX_POOL_SIZE,
          })
          .single();

        tracksEvicted = evictResult || 0;
        console.log(`➖ refresh-candidate-pool: Evicted ${tracksEvicted} tracks`);
      }

      // Step 5: Update pool TTLs
      const now = new Date();
      const newSoftTtl = new Date(now.getTime() + DEFAULT_SOFT_TTL_HOURS * 60 * 60 * 1000);
      const newHardTtl = new Date(now.getTime() + DEFAULT_HARD_TTL_HOURS * 60 * 60 * 1000);

      // Collect unique sources from new tracks
      const newSources = [...new Set(newTracks.map((t) => t.source))];
      const updatedStrategiesUsed = [...new Set([...pool.strategies_used, ...newSources])];

      await supabase
        .from("candidate_pools")
        .update({
          soft_ttl_at: newSoftTtl.toISOString(),
          hard_ttl_at: newHardTtl.toISOString(),
          strategies_used: updatedStrategiesUsed,
        })
        .eq("id", pool.id);

      // Step 6: Release lock
      await supabase.rpc("release_pool_refresh_lock", { p_pool_id: pool.id });

      // Get final track count
      const { data: finalCountData } = await supabase
        .from("candidate_pools")
        .select("track_count")
        .eq("id", pool.id)
        .single();

      const finalTrackCount = finalCountData?.track_count || 0;

      const response: RefreshCandidatePoolResponse = {
        success: true,
        poolId: pool.id,
        tracksAdded,
        tracksEvicted,
        newTrackCount: finalTrackCount,
      };

      console.log(
        `✅ refresh-candidate-pool: Success - Pool now has ${finalTrackCount} tracks`
      );

      return successResponse(response);
    } catch (innerError) {
      // Release lock on error
      await supabase.rpc("release_pool_refresh_lock", { p_pool_id: pool.id });
      throw innerError;
    }
  } catch (error) {
    console.error("Error in refresh-candidate-pool:", error);

    if (error instanceof Error) {
      return internalError(error.message);
    }

    return internalError("An unexpected error occurred");
  }
});
