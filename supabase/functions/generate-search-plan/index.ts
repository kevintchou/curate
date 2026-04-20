/**
 * Generate Search Plan Edge Function
 *
 * POST /functions/v1/generate-search-plan
 *
 * Generates a search plan + canonical intent from a user prompt.
 * Handles intent canonicalization with learning (occurrence threshold: 3).
 * Caches search plans per canonical intent.
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors } from "../_shared/cors.ts";
import {
  badRequest,
  missingField,
  llmError,
  unprocessable,
  internalError,
  successResponse,
  unauthorized,
} from "../_shared/errors.ts";
import { getLLMProvider, cleanJsonResponse } from "../_shared/llm-provider.ts";
import {
  GenerateSearchPlanRequest,
  GenerateSearchPlanResponse,
  MusicPlatform,
  SearchPlan,
  StationPolicy,
  PlaylistSearch,
  CatalogSearch,
  ArtistSeedFallbackConfig,
} from "../_shared/types.ts";

// MARK: - Constants

const INTENT_OCCURRENCE_THRESHOLD = 3; // Use cached mapping after 3 occurrences
const SEARCH_PLAN_TTL_DAYS = 7;

// MARK: - LLM Prompt Builder

function buildSearchPlanPrompt(
  prompt: string,
  platform: MusicPlatform
): { system: string; user: string } {
  const platformGuidance =
    platform === "apple_music"
      ? `For Apple Music, prioritize:
- Editorial playlist searches (PRIMARY) - Apple's curated playlists are high quality
- Catalog term searches (SECONDARY) - for abstract intents or low playlist yield
- Artist seeds only as fallback config (when intent is ambiguous or pool is small)`
      : `For Spotify, prioritize:
- Playlist search + extraction (PRIMARY) - editorial + high-follower playlists
- Artist-related expansion (SECONDARY) - Spotify's related-artists graph is strong
- Recommendations endpoint (carefully) - high quality but can collapse diversity`;

  const systemPrompt = `You are a music search strategist for streaming platforms. Given a user's natural language intent, generate a search plan optimized for discovering relevant tracks.

Your output must be valid JSON with this exact structure:
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
        "playlist_source_ratio": 0.55,
        "search_source_ratio": 0.25,
        "artist_seed_source_ratio": 0.20,
        "exploration_weight": 0.3,
        "artist_repeat_window": 10
    }
}

Guidelines:
- canonical_intent should be REUSABLE across similar prompts
  Examples:
  - "sunset drive", "evening drive", "golden hour drive" → "relaxed-driving-mood"
  - "morning workout", "gym session", "exercise music" → "high-energy-workout"
  - "study music", "focus time", "concentration" → "focused-study-ambient"
- mood_categories are broad (e.g., "chill", "energetic", "melancholic", "uplifting")
- flavor_tags capture specific nuances (e.g., "sunset", "acoustic", "90s", "indie")
- intent_confidence: 1.0 = very clear intent, 0.5 = ambiguous, <0.5 = recommend artist seeds
- For playlist_searches, provide 3-5 terms ordered by priority (1 = highest)
- For catalog_searches, provide 2-3 backup search terms
- artist_seed_config is only needed if intent is ambiguous or user mentions specific artists

${platformGuidance}

Always respond with valid JSON only. No markdown, no code blocks, no explanations.`;

  const userPrompt = `Platform: ${platform}
Intent: "${prompt}"

Generate a search plan optimized for this platform and intent.`;

  return { system: systemPrompt, user: userPrompt };
}

// MARK: - Hash Function

async function hashPrompt(prompt: string): Promise<string> {
  const normalized = prompt.toLowerCase().trim();
  const encoder = new TextEncoder();
  const data = encoder.encode(normalized);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

// MARK: - Database Operations

interface IntentMappingRow {
  id: string;
  canonical_intent: string;
  mood_categories: string[];
  flavor_tags: string[];
  occurrence_count: number;
}

interface SearchPlanRow {
  id: string;
  canonical_intent: string;
  playlist_searches: PlaylistSearch[];
  catalog_searches: CatalogSearch[];
  artist_seed_config: ArtistSeedFallbackConfig | null;
  mood_categories: string[];
  activity_tags: string[];
  suggested_exploration_weight: number;
  suggested_source_mix: {
    playlist: number;
    search: number;
    artist_seed: number;
  };
  artist_repeat_window: number;
  intent_confidence: number;
  expires_at: string;
}

async function getExistingIntentMapping(
  supabase: ReturnType<typeof createClient>,
  promptHash: string,
  platform: MusicPlatform
): Promise<IntentMappingRow | null> {
  const { data, error } = await supabase
    .from("intent_mappings")
    .select("id, canonical_intent, mood_categories, flavor_tags, occurrence_count")
    .eq("raw_prompt_hash", promptHash)
    .eq("platform", platform)
    .single();

  if (error || !data) return null;
  return data as IntentMappingRow;
}

async function upsertIntentMapping(
  supabase: ReturnType<typeof createClient>,
  rawPrompt: string,
  promptHash: string,
  canonicalIntent: string,
  moodCategories: string[],
  flavorTags: string[],
  platform: MusicPlatform
): Promise<{ occurrenceCount: number }> {
  // Try to insert, on conflict update occurrence count
  const { data, error } = await supabase
    .from("intent_mappings")
    .upsert(
      {
        raw_prompt_hash: promptHash,
        raw_prompt: rawPrompt,
        canonical_intent: canonicalIntent,
        mood_categories: moodCategories,
        flavor_tags: flavorTags,
        platform: platform,
        occurrence_count: 1,
      },
      {
        onConflict: "raw_prompt_hash,platform",
        ignoreDuplicates: false,
      }
    )
    .select("occurrence_count")
    .single();

  if (error) {
    // If upsert failed, try incrementing existing
    const { data: updateData } = await supabase
      .rpc("upsert_intent_mapping", {
        p_raw_prompt: rawPrompt,
        p_canonical_intent: canonicalIntent,
        p_mood_categories: moodCategories,
        p_flavor_tags: flavorTags,
        p_platform: platform,
      })
      .single();

    return { occurrenceCount: updateData?.occurrence_count || 1 };
  }

  return { occurrenceCount: data?.occurrence_count || 1 };
}

async function getCachedSearchPlan(
  supabase: ReturnType<typeof createClient>,
  canonicalIntent: string,
  platform: MusicPlatform
): Promise<SearchPlanRow | null> {
  const { data, error } = await supabase
    .from("search_plan_cache")
    .select("*")
    .eq("canonical_intent", canonicalIntent)
    .eq("platform", platform)
    .gt("expires_at", new Date().toISOString())
    .single();

  if (error || !data) return null;
  return data as SearchPlanRow;
}

async function cacheSearchPlan(
  supabase: ReturnType<typeof createClient>,
  canonicalIntent: string,
  platform: MusicPlatform,
  plan: {
    playlistSearches: PlaylistSearch[];
    catalogSearches: CatalogSearch[];
    artistSeedConfig?: ArtistSeedFallbackConfig;
    moodCategories: string[];
    activityTags: string[];
    explorationWeight: number;
    sourceMix: { playlist: number; search: number; artist_seed: number };
    artistRepeatWindow: number;
    intentConfidence: number;
  }
): Promise<void> {
  const expiresAt = new Date();
  expiresAt.setDate(expiresAt.getDate() + SEARCH_PLAN_TTL_DAYS);

  await supabase.from("search_plan_cache").upsert(
    {
      canonical_intent: canonicalIntent,
      platform: platform,
      playlist_searches: plan.playlistSearches,
      catalog_searches: plan.catalogSearches,
      artist_seed_config: plan.artistSeedConfig || null,
      mood_categories: plan.moodCategories,
      activity_tags: plan.activityTags,
      suggested_exploration_weight: plan.explorationWeight,
      suggested_source_mix: plan.sourceMix,
      artist_repeat_window: plan.artistRepeatWindow,
      intent_confidence: plan.intentConfidence,
      expires_at: expiresAt.toISOString(),
    },
    {
      onConflict: "canonical_intent,platform",
    }
  );
}

// MARK: - Response Builder

function buildResponse(
  canonicalIntent: string,
  moodCategories: string[],
  flavorTags: string[],
  intentConfidence: number,
  playlistSearches: PlaylistSearch[],
  catalogSearches: CatalogSearch[],
  artistSeedConfig: ArtistSeedFallbackConfig | undefined,
  stationPolicy: StationPolicy,
  isCached: boolean
): GenerateSearchPlanResponse {
  return {
    canonicalIntent,
    moodCategories,
    flavorTags,
    intentConfidence,
    searchPlan: {
      playlistSearches,
      catalogSearches,
      artistSeedConfig,
    },
    stationPolicy,
    isCached,
  };
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
    console.log("📥 generate-search-plan: Request received");

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

    // Client for auth verification
    const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Service client for database operations (bypasses RLS)
    const supabaseService = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Verify the JWT
    const {
      data: { user },
      error: authError,
    } = await supabaseAuth.auth.getUser(token);

    if (authError || !user) {
      console.log("❌ generate-search-plan: Auth failed", authError?.message);
      return unauthorized("Invalid or expired token");
    }

    console.log(`✅ generate-search-plan: Authenticated user ${user.id}`);

    // Parse request body
    const body: GenerateSearchPlanRequest = await req.json();
    console.log(
      `📝 generate-search-plan: Prompt = "${body.prompt?.substring(0, 50)}...", Platform = ${body.platform}`
    );

    // Validate required fields
    if (!body.prompt || typeof body.prompt !== "string") {
      return missingField("prompt");
    }

    if (body.prompt.trim().length === 0) {
      return badRequest("prompt cannot be empty");
    }

    if (!body.platform || !["apple_music", "spotify"].includes(body.platform)) {
      return badRequest("platform must be 'apple_music' or 'spotify'");
    }

    const platform = body.platform as MusicPlatform;
    const promptHash = await hashPrompt(body.prompt);

    // Step 1: Check for existing intent mapping
    const existingMapping = await getExistingIntentMapping(
      supabaseService,
      promptHash,
      platform
    );

    let canonicalIntent: string;
    let moodCategories: string[];
    let flavorTags: string[];
    let intentConfidence: number;
    let playlistSearches: PlaylistSearch[];
    let catalogSearches: CatalogSearch[];
    let artistSeedConfig: ArtistSeedFallbackConfig | undefined;
    let stationPolicy: StationPolicy;
    let isCached = false;

    // If we have a mapping with enough occurrences, use it
    if (existingMapping && existingMapping.occurrence_count >= INTENT_OCCURRENCE_THRESHOLD) {
      console.log(
        `🎯 generate-search-plan: Using cached mapping (${existingMapping.occurrence_count} occurrences)`
      );
      canonicalIntent = existingMapping.canonical_intent;
      moodCategories = existingMapping.mood_categories;
      flavorTags = existingMapping.flavor_tags;

      // Check for cached search plan
      const cachedPlan = await getCachedSearchPlan(supabaseService, canonicalIntent, platform);

      if (cachedPlan) {
        console.log(`📦 generate-search-plan: Using cached search plan`);
        isCached = true;
        intentConfidence = cachedPlan.intent_confidence;
        playlistSearches = cachedPlan.playlist_searches;
        catalogSearches = cachedPlan.catalog_searches;
        artistSeedConfig = cachedPlan.artist_seed_config || undefined;
        stationPolicy = {
          playlistSourceRatio: cachedPlan.suggested_source_mix.playlist,
          searchSourceRatio: cachedPlan.suggested_source_mix.search,
          artistSeedSourceRatio: cachedPlan.suggested_source_mix.artist_seed,
          explorationWeight: cachedPlan.suggested_exploration_weight,
          artistRepeatWindow: cachedPlan.artist_repeat_window,
        };

        // Increment occurrence count for analytics
        await upsertIntentMapping(
          supabaseService,
          body.prompt,
          promptHash,
          canonicalIntent,
          moodCategories,
          flavorTags,
          platform
        );

        return successResponse(
          buildResponse(
            canonicalIntent,
            moodCategories,
            flavorTags,
            intentConfidence,
            playlistSearches,
            catalogSearches,
            artistSeedConfig,
            stationPolicy,
            isCached
          )
        );
      }
    }

    // Step 2: Generate via LLM
    console.log(`🤖 generate-search-plan: Calling LLM...`);
    const { system, user: userPrompt } = buildSearchPlanPrompt(body.prompt, platform);

    const provider = getLLMProvider();
    const rawResponse = await provider.generateContent(system, userPrompt);
    const cleanedResponse = cleanJsonResponse(rawResponse);

    let llmResult: {
      canonical_intent: string;
      mood_categories: string[];
      flavor_tags: string[];
      intent_confidence: number;
      search_plan: {
        playlist_searches: Array<{ term: string; priority: number }>;
        catalog_searches: Array<{ term: string; genres?: string[] }>;
        artist_seed_config?: {
          seed_count: number;
          similarity_ratios: { direct: number; adjacent: number; discovery: number };
        };
      };
      station_policy: {
        playlist_source_ratio: number;
        search_source_ratio: number;
        artist_seed_source_ratio: number;
        exploration_weight: number;
        artist_repeat_window: number;
      };
    };

    try {
      llmResult = JSON.parse(cleanedResponse);
    } catch (parseError) {
      console.error("Failed to parse LLM response:", cleanedResponse);
      return unprocessable(
        "Failed to parse LLM response as JSON",
        parseError instanceof Error ? parseError.message : String(parseError)
      );
    }

    // Validate and normalize LLM response
    canonicalIntent = llmResult.canonical_intent || "unknown-intent";
    moodCategories = llmResult.mood_categories || [];
    flavorTags = llmResult.flavor_tags || [];
    intentConfidence = Math.max(0, Math.min(1, llmResult.intent_confidence || 0.8));

    playlistSearches = (llmResult.search_plan?.playlist_searches || []).map((s) => ({
      term: s.term,
      priority: s.priority || 1,
    }));

    catalogSearches = (llmResult.search_plan?.catalog_searches || []).map((s) => ({
      term: s.term,
      genres: s.genres,
    }));

    if (llmResult.search_plan?.artist_seed_config) {
      const asc = llmResult.search_plan.artist_seed_config;
      artistSeedConfig = {
        seedCount: asc.seed_count || 5,
        similarityRatios: {
          direct: asc.similarity_ratios?.direct || 0.5,
          adjacent: asc.similarity_ratios?.adjacent || 0.35,
          discovery: asc.similarity_ratios?.discovery || 0.15,
        },
      };
    }

    const rawPolicy = llmResult.station_policy || {};
    stationPolicy = {
      playlistSourceRatio: rawPolicy.playlist_source_ratio || 0.55,
      searchSourceRatio: rawPolicy.search_source_ratio || 0.25,
      artistSeedSourceRatio: rawPolicy.artist_seed_source_ratio || 0.20,
      explorationWeight: rawPolicy.exploration_weight || 0.3,
      artistRepeatWindow: rawPolicy.artist_repeat_window || 10,
    };

    // Normalize source ratios to sum to 1
    const totalRatio =
      stationPolicy.playlistSourceRatio +
      stationPolicy.searchSourceRatio +
      stationPolicy.artistSeedSourceRatio;
    if (totalRatio > 0 && Math.abs(totalRatio - 1) > 0.01) {
      stationPolicy.playlistSourceRatio /= totalRatio;
      stationPolicy.searchSourceRatio /= totalRatio;
      stationPolicy.artistSeedSourceRatio /= totalRatio;
    }

    // Step 3: Cache the results
    await upsertIntentMapping(
      supabaseService,
      body.prompt,
      promptHash,
      canonicalIntent,
      moodCategories,
      flavorTags,
      platform
    );

    await cacheSearchPlan(supabaseService, canonicalIntent, platform, {
      playlistSearches,
      catalogSearches,
      artistSeedConfig,
      moodCategories,
      activityTags: flavorTags,
      explorationWeight: stationPolicy.explorationWeight,
      sourceMix: {
        playlist: stationPolicy.playlistSourceRatio,
        search: stationPolicy.searchSourceRatio,
        artist_seed: stationPolicy.artistSeedSourceRatio,
      },
      artistRepeatWindow: stationPolicy.artistRepeatWindow,
      intentConfidence,
    });

    console.log(
      `✅ generate-search-plan: Success - Intent: "${canonicalIntent}", Confidence: ${intentConfidence}`
    );

    return successResponse(
      buildResponse(
        canonicalIntent,
        moodCategories,
        flavorTags,
        intentConfidence,
        playlistSearches,
        catalogSearches,
        artistSeedConfig,
        stationPolicy,
        isCached
      )
    );
  } catch (error) {
    console.error("Error in generate-search-plan:", error);

    if (error instanceof Error) {
      if (
        error.message.includes("API error") ||
        error.message.includes("Gemini") ||
        error.message.includes("OpenAI") ||
        error.message.includes("Anthropic")
      ) {
        return llmError(error.message);
      }

      return internalError(error.message);
    }

    return internalError("An unexpected error occurred");
  }
});
