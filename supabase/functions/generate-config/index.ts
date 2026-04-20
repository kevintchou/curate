/**
 * Generate Station Config Edge Function
 *
 * POST /functions/v1/generate-config
 *
 * Generates a station configuration from a natural language prompt
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
import { buildConfigPrompts } from "../_shared/prompts.ts";
import {
  GenerateConfigRequest,
  GenerateConfigResponse,
  StationConfig,
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
    console.log("📥 generate-config: Request received");

    // Parse request body
    const body: GenerateConfigRequest = await req.json();
    console.log(`📝 generate-config: Prompt = "${body.prompt?.substring(0, 50)}..."`);

    // Validate required fields
    if (!body.prompt || typeof body.prompt !== "string") {
      return missingField("prompt");
    }

    if (body.prompt.trim().length === 0) {
      return badRequest("prompt cannot be empty");
    }

    // Build prompts
    const { system, user } = buildConfigPrompts(body.prompt, body.tasteProfile);

    // Get LLM provider and generate content
    const provider = getLLMProvider();
    const rawResponse = await provider.generateContent(system, user);

    // Clean and parse JSON response
    const cleanedResponse = cleanJsonResponse(rawResponse);

    let config: StationConfig;
    try {
      config = JSON.parse(cleanedResponse);
    } catch (parseError) {
      console.error("Failed to parse LLM response:", cleanedResponse);
      return unprocessable(
        "Failed to parse LLM response as JSON",
        parseError instanceof Error ? parseError.message : String(parseError)
      );
    }

    // Apply defaults for missing optional fields
    const response: GenerateConfigResponse = {
      name: config.name || "My Station",
      description: config.description || "",
      contextDescription: config.contextDescription || "",
      valenceRange: config.valenceRange,
      energyRange: config.energyRange,
      danceabilityRange: config.danceabilityRange,
      bpmRange: config.bpmRange,
      acousticnessRange: config.acousticnessRange,
      instrumentalnessRange: config.instrumentalnessRange,
      valenceWeight: config.valenceWeight ?? 1.0,
      energyWeight: config.energyWeight ?? 1.0,
      danceabilityWeight: config.danceabilityWeight ?? 0.8,
      bpmWeight: config.bpmWeight ?? 0.8,
      acousticnessWeight: config.acousticnessWeight ?? 0.5,
      instrumentalnessWeight: config.instrumentalnessWeight ?? 0.5,
      suggestedGenres: config.suggestedGenres || [],
      suggestedDecades: config.suggestedDecades,
      moodKeywords: config.moodKeywords || [],
    };

    console.log(`✅ generate-config: Success - Station name: "${response.name}"`);
    return successResponse(response);
  } catch (error) {
    console.error("Error in generate-config:", error);

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
