/**
 * Suggest Songs Edge Function
 *
 * POST /functions/v1/suggest-songs
 *
 * Generates song suggestions based on station config and user feedback
 * using an LLM (Gemini by default).
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { handleCors, corsHeaders } from "../_shared/cors.ts";
import {
  badRequest,
  missingField,
  llmError,
  unprocessable,
  internalError,
  successResponse,
} from "../_shared/errors.ts";
import { getLLMProvider, cleanJsonResponse } from "../_shared/llm-provider.ts";
import { buildSongSuggestionPrompts } from "../_shared/prompts.ts";
import {
  SuggestSongsRequest,
  SuggestSongsResponse,
  SongSuggestion,
} from "../_shared/types.ts";

serve(async (req: Request) => {
  // Handle CORS preflight
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  // Only allow POST
  if (req.method !== "POST") {
    return badRequest("Method not allowed. Use POST.");
  }

  try {
    console.log("📥 suggest-songs: Request received");

    // Parse request body
    const body: SuggestSongsRequest = await req.json();
    console.log(`📝 suggest-songs: Station = "${body.config?.name}", count = ${body.count}`);

    // Validate required fields
    if (!body.config) {
      return missingField("config");
    }

    if (!body.config.name) {
      return missingField("config.name");
    }

    if (!body.config.originalPrompt) {
      return missingField("config.originalPrompt");
    }

    if (typeof body.count !== "number" || body.count < 1) {
      return badRequest("count must be a positive number");
    }

    // Ensure arrays have defaults
    const request: SuggestSongsRequest = {
      config: body.config,
      likedSongs: body.likedSongs || [],
      dislikedSongs: body.dislikedSongs || [],
      recentlyPlayed: body.recentlyPlayed || [],
      count: body.count,
    };

    // Build prompts
    const { system, user } = buildSongSuggestionPrompts(request);

    // Get LLM provider and generate content
    const provider = getLLMProvider();
    const rawResponse = await provider.generateContent(system, user);

    // Clean and parse JSON response
    const cleanedResponse = cleanJsonResponse(rawResponse);

    let parsed: { songs: SongSuggestion[] };
    try {
      parsed = JSON.parse(cleanedResponse);
    } catch (parseError) {
      console.error("Failed to parse LLM response:", cleanedResponse);
      return unprocessable(
        "Failed to parse LLM response as JSON",
        parseError instanceof Error ? parseError.message : String(parseError)
      );
    }

    // Validate and normalize songs
    if (!Array.isArray(parsed.songs)) {
      return unprocessable("LLM response missing songs array");
    }

    const songs: SongSuggestion[] = parsed.songs.map((song) => ({
      title: song.title || "Unknown Title",
      artist: song.artist || "Unknown Artist",
      album: song.album,
      year: song.year,
      reason: song.reason || "",
      estimatedBpm: song.estimatedBpm,
      estimatedEnergy: song.estimatedEnergy,
      estimatedValence: song.estimatedValence,
      estimatedDanceability: song.estimatedDanceability,
      estimatedAcousticness: song.estimatedAcousticness,
      estimatedInstrumentalness: song.estimatedInstrumentalness,
    }));

    const response: SuggestSongsResponse = { songs };

    console.log(`✅ suggest-songs: Success - Returning ${songs.length} songs`);
    return successResponse(response);
  } catch (error) {
    console.error("Error in suggest-songs:", error);

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
