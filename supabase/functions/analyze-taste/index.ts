/**
 * Analyze Taste Edge Function
 *
 * POST /functions/v1/analyze-taste
 *
 * Analyzes user feedback to update their taste profile
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
import { buildTasteAnalysisPrompts } from "../_shared/prompts.ts";
import {
  AnalyzeTasteRequest,
  AnalyzeTasteResponse,
  TasteProfile,
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
    console.log("📥 analyze-taste: Request received");

    // Parse request body
    const body: AnalyzeTasteRequest = await req.json();
    console.log(`📝 analyze-taste: Prompt = "${body.originalPrompt?.substring(0, 50)}..."`);

    // Validate required fields
    if (!body.originalPrompt || typeof body.originalPrompt !== "string") {
      return missingField("originalPrompt");
    }

    if (!body.feedbackSummary) {
      return missingField("feedbackSummary");
    }

    // Ensure feedbackSummary has defaults
    const feedbackSummary = {
      totalLikes: body.feedbackSummary.totalLikes || 0,
      totalDislikes: body.feedbackSummary.totalDislikes || 0,
      totalSkips: body.feedbackSummary.totalSkips || 0,
      likedSongs: body.feedbackSummary.likedSongs || [],
      dislikedSongs: body.feedbackSummary.dislikedSongs || [],
    };

    // Build prompts
    const { system, user } = buildTasteAnalysisPrompts(
      body.originalPrompt,
      body.currentProfile,
      feedbackSummary
    );

    // Get LLM provider and generate content
    const provider = getLLMProvider();
    const rawResponse = await provider.generateContent(system, user);

    // Clean and parse JSON response
    const cleanedResponse = cleanJsonResponse(rawResponse);

    let parsed: TasteProfile;
    try {
      parsed = JSON.parse(cleanedResponse);
    } catch (parseError) {
      console.error("Failed to parse LLM response:", cleanedResponse);
      return unprocessable(
        "Failed to parse LLM response as JSON",
        parseError instanceof Error ? parseError.message : String(parseError)
      );
    }

    // Apply defaults and normalize response
    const response: AnalyzeTasteResponse = {
      preferredGenres: parsed.preferredGenres || [],
      avoidedGenres: parsed.avoidedGenres || [],
      preferredArtists: parsed.preferredArtists || [],
      avoidedArtists: parsed.avoidedArtists || [],
      preferredDecades: parsed.preferredDecades || [],
      energyPreference: parsed.energyPreference || "varied",
      moodPreference: parsed.moodPreference || "varied",
      notablePatterns: parsed.notablePatterns || [],
    };

    console.log(`✅ analyze-taste: Success - Found ${response.preferredGenres.length} preferred genres`);
    return successResponse(response);
  } catch (error) {
    console.error("Error in analyze-taste:", error);

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
