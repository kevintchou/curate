/**
 * LLM Prompts for Curate
 *
 * Ported from iOS LLMPromptBuilder.swift
 * These prompts are kept server-side for security and easy iteration.
 */

import {
  TasteProfile,
  StationConfig,
  FeedbackSummary,
  SuggestSongsRequest,
} from "./types.ts";

// MARK: - Station Config Generation

export function buildConfigPrompts(
  prompt: string,
  tasteProfile?: TasteProfile
): { system: string; user: string } {
  const systemPrompt = `You are an expert music curator with deep knowledge of all genres, eras, and styles.
Your job is to interpret a user's natural language description and create a music station configuration.

You understand the technical aspects of music:
- BPM (tempo): 60-200 range, normalized to 0-1
- Energy: 0 (calm, ambient) to 1 (intense, powerful)
- Valence: 0 (sad, melancholic) to 1 (happy, uplifting)
- Danceability: 0 (still, contemplative) to 1 (very danceable)
- Acousticness: 0 (electronic, produced) to 1 (acoustic, organic)
- Instrumentalness: 0 (vocals prominent) to 1 (purely instrumental)

Always respond with valid JSON only. No markdown formatting, no code blocks, no explanations outside the JSON.`;

  let userPrompt = `Create a music station for this request: "${prompt}"

`;

  if (tasteProfile && tasteProfile.preferredGenres.length > 0) {
    userPrompt += `
User's known preferences:
- Preferred genres: ${tasteProfile.preferredGenres.join(", ")}
- Avoided genres: ${tasteProfile.avoidedGenres.join(", ")}
- Energy preference: ${tasteProfile.energyPreference}
- Mood preference: ${tasteProfile.moodPreference}

`;
  }

  userPrompt += `
Respond with this exact JSON structure:
{
    "name": "Short catchy station name (2-5 words)",
    "description": "One sentence describing what to expect",
    "contextDescription": "Your interpretation of the vibe and setting",
    "valenceRange": {"min": 0.0, "max": 1.0},
    "energyRange": {"min": 0.0, "max": 1.0},
    "danceabilityRange": {"min": 0.0, "max": 1.0},
    "bpmRange": {"min": 0.0, "max": 1.0},
    "acousticnessRange": {"min": 0.0, "max": 1.0},
    "instrumentalnessRange": {"min": 0.0, "max": 1.0},
    "valenceWeight": 1.0,
    "energyWeight": 1.0,
    "danceabilityWeight": 0.8,
    "bpmWeight": 0.8,
    "acousticnessWeight": 0.5,
    "instrumentalnessWeight": 0.5,
    "suggestedGenres": ["genre1", "genre2"],
    "suggestedDecades": [1990, 2000, 2010],
    "moodKeywords": ["keyword1", "keyword2", "keyword3"]
}

Set feature ranges to null if not relevant to the request.
Adjust weights to emphasize what matters most for this station (0.0-2.0 scale).`;

  return { system: systemPrompt, user: userPrompt };
}

// MARK: - Song Suggestions

export function buildSongSuggestionPrompts(
  request: SuggestSongsRequest
): { system: string; user: string } {
  const systemPrompt = `You are an expert music curator. Your job is to suggest specific songs that fit a station's vibe.

For each song, you must provide:
1. The exact song title and artist name
2. Your best estimate of the song's audio features (BPM, energy, valence, etc.)
3. A brief reason why this song fits

Guidelines:
- Suggest real, existing songs only
- Mix well-known tracks with deeper cuts
- Consider the user's feedback (what they liked/disliked)
- Avoid recently played songs
- Be diverse in artists (don't repeat artists too often)

Always respond with valid JSON only. No markdown, no code blocks.`;

  let userPrompt = `Station: "${request.config.name}"
Original request: "${request.config.originalPrompt}"
Vibe: ${request.config.contextDescription}
Suggested genres: ${request.config.suggestedGenres.join(", ")}
Mood keywords: ${request.config.moodKeywords.join(", ")}

`;

  // Add feature range guidance if available
  const featureGuidance: string[] = [];

  if (request.config.valenceRange) {
    const target =
      (request.config.valenceRange.min + request.config.valenceRange.max) / 2;
    const desc =
      target > 0.6
        ? "happy/positive"
        : target < 0.4
        ? "melancholic/sad"
        : "neutral";
    featureGuidance.push(
      `Valence: ${desc} (${request.config.valenceRange.min.toFixed(
        1
      )}-${request.config.valenceRange.max.toFixed(1)})`
    );
  }

  if (request.config.energyRange) {
    const target =
      (request.config.energyRange.min + request.config.energyRange.max) / 2;
    const desc =
      target > 0.7
        ? "high energy"
        : target < 0.4
        ? "low energy/calm"
        : "moderate energy";
    featureGuidance.push(
      `Energy: ${desc} (${request.config.energyRange.min.toFixed(
        1
      )}-${request.config.energyRange.max.toFixed(1)})`
    );
  }

  if (request.config.danceabilityRange) {
    const target =
      (request.config.danceabilityRange.min +
        request.config.danceabilityRange.max) /
      2;
    const desc =
      target > 0.7
        ? "very danceable"
        : target < 0.4
        ? "less danceable"
        : "moderately danceable";
    featureGuidance.push(
      `Danceability: ${desc} (${request.config.danceabilityRange.min.toFixed(
        1
      )}-${request.config.danceabilityRange.max.toFixed(1)})`
    );
  }

  if (request.config.bpmRange) {
    // Convert normalized BPM (0-1) to actual BPM (60-200)
    const actualBpmMin = Math.round(request.config.bpmRange.min * 140 + 60);
    const actualBpmMax = Math.round(request.config.bpmRange.max * 140 + 60);
    featureGuidance.push(`BPM: ${actualBpmMin}-${actualBpmMax}`);
  }

  if (request.config.acousticnessRange) {
    const target =
      (request.config.acousticnessRange.min +
        request.config.acousticnessRange.max) /
      2;
    const desc =
      target > 0.6
        ? "acoustic/organic"
        : target < 0.3
        ? "electronic/produced"
        : "mixed";
    featureGuidance.push(`Acousticness: ${desc}`);
  }

  if (request.config.instrumentalnessRange) {
    const target =
      (request.config.instrumentalnessRange.min +
        request.config.instrumentalnessRange.max) /
      2;
    const desc = target > 0.5 ? "instrumental preferred" : "with vocals";
    featureGuidance.push(`Instrumentalness: ${desc}`);
  }

  if (featureGuidance.length > 0) {
    userPrompt += `Audio feature targets:
- ${featureGuidance.join("\n- ")}

`;
  }

  // Add decade guidance if available
  if (request.config.suggestedDecades && request.config.suggestedDecades.length > 0) {
    userPrompt += `Target decades: ${request.config.suggestedDecades
      .map((d) => `${d}s`)
      .join(", ")}

`;
  }

  if (request.likedSongs.length > 0) {
    userPrompt += `
Songs the user LIKED (suggest similar):
`;
    for (const song of request.likedSongs.slice(0, 10)) {
      userPrompt += `- ${song.title} by ${song.artist}\n`;
    }
  }

  if (request.dislikedSongs.length > 0) {
    userPrompt += `
Songs the user DISLIKED (avoid similar):
`;
    for (const song of request.dislikedSongs.slice(0, 10)) {
      userPrompt += `- ${song.title} by ${song.artist}\n`;
    }
  }

  if (request.recentlyPlayed.length > 0) {
    userPrompt += `
Recently played (DO NOT suggest these again):
`;
    for (const title of request.recentlyPlayed.slice(0, 20)) {
      userPrompt += `- ${title}\n`;
    }
  }

  userPrompt += `
Suggest ${request.count} songs. Respond with this JSON structure:
{
    "songs": [
        {
            "title": "Song Title",
            "artist": "Artist Name",
            "album": "Album Name",
            "year": 2020,
            "reason": "Why this fits the station",
            "estimatedBpm": 120,
            "estimatedEnergy": 0.7,
            "estimatedValence": 0.6,
            "estimatedDanceability": 0.65,
            "estimatedAcousticness": 0.3,
            "estimatedInstrumentalness": 0.1
        }
    ]
}

Feature values should be 0.0-1.0 scale. BPM should be actual BPM (60-200 range).`;

  return { system: systemPrompt, user: userPrompt };
}

// MARK: - Taste Analysis

export function buildTasteAnalysisPrompts(
  originalPrompt: string,
  currentProfile: TasteProfile | undefined,
  feedbackSummary: FeedbackSummary
): { system: string; user: string } {
  const systemPrompt = `You are a music taste analyst. Analyze the user's feedback patterns to understand their preferences.

Look for patterns in:
- Genre preferences
- Artist preferences
- Energy levels they prefer
- Mood (valence) preferences
- Any notable patterns (e.g., "prefers female vocals", "likes piano ballads")

Always respond with valid JSON only.`;

  let userPrompt = `Original station request: "${originalPrompt}"

Feedback summary:
- Total likes: ${feedbackSummary.totalLikes}
- Total dislikes: ${feedbackSummary.totalDislikes}
- Total skips: ${feedbackSummary.totalSkips}

Liked songs:`;

  for (const song of feedbackSummary.likedSongs) {
    userPrompt += `\n- ${song.title} by ${song.artist}`;
    if (song.genre) {
      userPrompt += ` (${song.genre})`;
    }
  }

  userPrompt += "\n\nDisliked songs:";

  for (const song of feedbackSummary.dislikedSongs) {
    userPrompt += `\n- ${song.title} by ${song.artist}`;
    if (song.genre) {
      userPrompt += ` (${song.genre})`;
    }
  }

  if (currentProfile) {
    userPrompt += `

Current taste profile:
- Preferred genres: ${currentProfile.preferredGenres.join(", ")}
- Avoided genres: ${currentProfile.avoidedGenres.join(", ")}
- Energy preference: ${currentProfile.energyPreference}
- Notable patterns: ${currentProfile.notablePatterns.join(", ")}`;
  }

  userPrompt += `

Analyze the feedback and respond with this JSON structure:
{
    "preferredGenres": ["genre1", "genre2"],
    "avoidedGenres": ["genre3"],
    "preferredArtists": ["artist1", "artist2"],
    "avoidedArtists": ["artist3"],
    "preferredDecades": [2000, 2010],
    "energyPreference": "medium",
    "moodPreference": "happy",
    "notablePatterns": ["pattern1", "pattern2"]
}

Energy and mood preferences should be one of: "low", "medium", "high", "varied"
For mood: "happy", "melancholic", "intense", "calm", "varied"`;

  return { system: systemPrompt, user: userPrompt };
}
