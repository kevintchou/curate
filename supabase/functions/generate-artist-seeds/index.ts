/**
 * Generate Artist Seeds Edge Function
 *
 * POST /functions/v1/generate-artist-seeds
 *
 * Generates artist seeds for a station based on configuration and user taste.
 * Requires JWT authentication.
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, corsHeaders } from "../_shared/cors.ts";
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
import { StationConfig } from "../_shared/types.ts";

// MARK: - Types

interface GenerateArtistSeedsRequest {
  config: StationConfig & { originalPrompt: string };
  tasteSummary?: string;
  avoidArtists?: string[];
  count: number;
  temperature?: number; // 0-1: 0=conservative/exploit, 1=adventurous/explore
  preferredGenres?: string[]; // Genres to boost (3x weight)
  nonPreferredGenres?: string[]; // Genres to deprioritize (0.3x weight)
}

// MARK: - Similarity Ratios

interface SimilarityRatios {
  direct: number;
  adjacent: number;
  discovery: number;
}

/**
 * Calculate similarity type ratios based on temperature
 * Low temp (0-0.3): More direct matches, fewer discoveries
 * Mid temp (0.3-0.7): Balanced mix
 * High temp (0.7-1.0): More discovery, fewer direct matches
 */
function getSimilarityRatios(temperature: number): SimilarityRatios {
  // Clamp temperature to 0-1
  const t = Math.max(0, Math.min(1, temperature));

  if (t < 0.3) {
    // Conservative: 60% direct, 30% adjacent, 10% discovery
    return { direct: 0.6, adjacent: 0.3, discovery: 0.1 };
  } else if (t < 0.7) {
    // Balanced: 40% direct, 40% adjacent, 20% discovery
    return { direct: 0.4, adjacent: 0.4, discovery: 0.2 };
  } else {
    // Adventurous: 20% direct, 40% adjacent, 40% discovery
    return { direct: 0.2, adjacent: 0.4, discovery: 0.4 };
  }
}

interface ArtistSeed {
  name: string;
  reason: string;
  similarityType: "direct" | "adjacent" | "discovery";
  expectedGenres?: string[];
}

interface GenerateArtistSeedsResponse {
  seeds: ArtistSeed[];
}

// MARK: - Genre Resolution

/**
 * Resolve effective genres for the prompt.
 * User preferences override station genres when set.
 *
 * Logic:
 * 1. If user has no preferred genres → use station's suggestedGenres as-is
 * 2. If user has preferred genres AND station has suggestedGenres:
 *    a. Find intersection (genres that match both)
 *    b. If intersection is non-empty → use intersection (respects both)
 *    c. If intersection is empty → use user's preferences (user preference wins)
 * 3. If user has preferred genres but station has none → use user's preferences
 */
function resolveEffectiveGenres(
  stationGenres: string[] | undefined,
  userPreferredGenres: string[]
): string[] {
  // No user preferences → use station genres
  if (userPreferredGenres.length === 0) {
    return stationGenres || [];
  }

  // No station genres → use user preferences
  if (!stationGenres || stationGenres.length === 0) {
    return userPreferredGenres;
  }

  // Both exist → find intersection (case-insensitive)
  const stationGenresLower = stationGenres.map((g) => g.toLowerCase());
  const intersection = userPreferredGenres.filter((userGenre) =>
    stationGenresLower.includes(userGenre.toLowerCase())
  );

  if (intersection.length > 0) {
    // Intersection found → use genres that satisfy both user and station
    console.log(
      `🎯 Genre intersection: ${intersection.join(", ")} (from station: ${stationGenres.join(", ")}, user: ${userPreferredGenres.join(", ")})`
    );
    return intersection;
  }

  // No overlap → user preferences win (they explicitly chose these genres)
  console.log(
    `🎯 No genre overlap - using user preferences: ${userPreferredGenres.join(", ")} (station had: ${stationGenres.join(", ")})`
  );
  return userPreferredGenres;
}

// MARK: - Prompt Builder

function buildArtistSeedPrompts(
  config: StationConfig & { originalPrompt: string },
  tasteSummary: string | undefined,
  avoidArtists: string[],
  count: number,
  temperature: number,
  preferredGenres: string[],
  nonPreferredGenres: string[]
): { system: string; user: string } {
  const ratios = getSimilarityRatios(temperature);
  const systemPrompt = `You are an expert music curator who suggests artists based on user preferences.
Your job is to suggest ARTIST NAMES (not songs) that would be great seeds for a music station.

Guidelines:
- Suggest REAL, EXISTING artists only
- Mix mainstream and lesser-known artists for variety
- Consider the user's taste history if provided
- Avoid artists the user has disliked
- Each artist should fit the station's mood/vibe

Similarity types:
- "direct": Artists that directly match the mood/genre
- "adjacent": Related artists with a slightly different angle
- "discovery": Stretch picks for variety and exploration

Always respond with valid JSON only. No markdown, no code blocks.`;

  // Resolve effective genres - user preferences override station genres
  const effectiveGenres = resolveEffectiveGenres(config.suggestedGenres, preferredGenres);

  let userPrompt = `Create artist seeds for this station:

Station: "${config.name}"
Original request: "${config.originalPrompt}"
Vibe: ${config.description}
Context: ${config.contextDescription}
`;

  // Use resolved effective genres (user preferences already factored in)
  if (effectiveGenres.length > 0) {
    userPrompt += `TARGET GENRES (artists MUST fit these genres): ${effectiveGenres.join(", ")}\n`;
  }

  if (config.suggestedDecades && config.suggestedDecades.length > 0) {
    userPrompt += `Target decades: ${config.suggestedDecades.map((d) => `${d}s`).join(", ")}\n`;
  }

  if (config.moodKeywords && config.moodKeywords.length > 0) {
    userPrompt += `Mood keywords: ${config.moodKeywords.join(", ")}\n`;
  }

  // Add feature guidance
  const featureGuidance: string[] = [];

  if (config.energyRange) {
    const target = (config.energyRange.min + config.energyRange.max) / 2;
    const desc = target > 0.7 ? "high energy" : target < 0.4 ? "low energy/calm" : "moderate energy";
    featureGuidance.push(`Energy: ${desc}`);
  }

  if (config.valenceRange) {
    const target = (config.valenceRange.min + config.valenceRange.max) / 2;
    const desc = target > 0.6 ? "positive/upbeat" : target < 0.4 ? "melancholic/moody" : "neutral";
    featureGuidance.push(`Mood: ${desc}`);
  }

  if (featureGuidance.length > 0) {
    userPrompt += `\nAudio characteristics: ${featureGuidance.join(", ")}\n`;
  }

  if (tasteSummary && tasteSummary.trim().length > 0) {
    userPrompt += `
User's taste profile:
${tasteSummary}
`;
  }

  if (avoidArtists.length > 0) {
    userPrompt += `
DO NOT suggest these artists (user has disliked them):
${avoidArtists.slice(0, 20).map((a) => `- ${a}`).join("\n")}
`;
  }

  // Add non-preferred genres (genres to avoid)
  if (nonPreferredGenres.length > 0) {
    userPrompt += `
AVOID THESE GENRES (user has deprioritized them):
${nonPreferredGenres.map((g) => `- ${g}`).join("\n")}
`;
  }

  // Calculate counts based on temperature-adjusted ratios
  const directCount = Math.round(count * ratios.direct);
  const adjacentCount = Math.round(count * ratios.adjacent);
  const discoveryCount = count - directCount - adjacentCount;

  userPrompt += `
Suggest ${count} artists. Include a mix of similarity types.
Prefer ${directCount} direct matches, ${adjacentCount} adjacent, and ${discoveryCount} discovery picks.

Respond with this JSON structure:
{
    "seeds": [
        {
            "name": "Artist Name",
            "reason": "Why this artist fits the station",
            "similarityType": "direct",
            "expectedGenres": ["genre1", "genre2"]
        }
    ]
}`;

  return { system: systemPrompt, user: userPrompt };
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
    console.log("📥 generate-artist-seeds: Request received");

    // Verify JWT authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return unauthorized("Missing or invalid Authorization header");
    }

    const token = authHeader.replace("Bearer ", "");

    // Create Supabase client to verify token
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !supabaseKey) {
      return internalError("Supabase configuration missing");
    }

    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    // Verify the JWT
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      console.log("❌ generate-artist-seeds: Auth failed", authError?.message);
      return unauthorized("Invalid or expired token");
    }

    console.log(`✅ generate-artist-seeds: Authenticated user ${user.id}`);

    // Parse request body
    const body: GenerateArtistSeedsRequest = await req.json();
    console.log(`📝 generate-artist-seeds: Station = "${body.config?.name}", count = ${body.count}`);

    // Validate required fields
    if (!body.config) {
      return missingField("config");
    }

    if (!body.config.originalPrompt) {
      return missingField("config.originalPrompt");
    }

    if (!body.count || body.count < 1 || body.count > 10) {
      return badRequest("count must be between 1 and 10");
    }

    // Build prompts
    const { system, user: userPrompt } = buildArtistSeedPrompts(
      body.config,
      body.tasteSummary,
      body.avoidArtists || [],
      body.count,
      body.temperature ?? 0.5, // Default to balanced
      body.preferredGenres || [],
      body.nonPreferredGenres || []
    );

    // Get LLM provider and generate content
    const provider = getLLMProvider();
    const rawResponse = await provider.generateContent(system, userPrompt);

    // Clean and parse JSON response
    const cleanedResponse = cleanJsonResponse(rawResponse);

    let parsed: GenerateArtistSeedsResponse;
    try {
      parsed = JSON.parse(cleanedResponse);
    } catch (parseError) {
      console.error("Failed to parse LLM response:", cleanedResponse);
      return unprocessable(
        "Failed to parse LLM response as JSON",
        parseError instanceof Error ? parseError.message : String(parseError)
      );
    }

    // Validate response structure
    if (!parsed.seeds || !Array.isArray(parsed.seeds)) {
      return unprocessable("Invalid response: missing seeds array");
    }

    // Validate and normalize each seed
    const validSeeds: ArtistSeed[] = [];
    for (const seed of parsed.seeds) {
      if (!seed.name || typeof seed.name !== "string") {
        continue;
      }

      validSeeds.push({
        name: seed.name.trim(),
        reason: seed.reason || "Fits the station vibe",
        similarityType: ["direct", "adjacent", "discovery"].includes(seed.similarityType)
          ? seed.similarityType
          : "direct",
        expectedGenres: Array.isArray(seed.expectedGenres)
          ? seed.expectedGenres.filter((g: unknown) => typeof g === "string")
          : undefined,
      });
    }

    if (validSeeds.length === 0) {
      return unprocessable("No valid artist seeds in response");
    }

    const response: GenerateArtistSeedsResponse = {
      seeds: validSeeds,
    };

    console.log(
      `✅ generate-artist-seeds: Success - ${validSeeds.length} seeds: ${validSeeds.map((s) => s.name).join(", ")}`
    );
    return successResponse(response);
  } catch (error) {
    console.error("Error in generate-artist-seeds:", error);

    if (error instanceof Error) {
      // Check if it's an LLM API error
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
