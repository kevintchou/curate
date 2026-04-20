# Curate Edge Functions

Supabase Edge Functions for LLM-based music station generation.

## Functions

| Function | Description |
|----------|-------------|
| `generate-config` | Creates station config from natural language prompt |
| `suggest-songs` | Suggests songs based on station config and feedback |
| `analyze-taste` | Analyzes user feedback to build taste profile |

## Setup

### 1. Install Supabase CLI

```bash
brew install supabase/tap/supabase
```

### 2. Link to Your Project

```bash
cd /path/to/Curate
supabase link --project-ref yaykqmambliikwqirenx
```

### 3. Set Required Secrets

```bash
# Gemini API Key (required)
supabase secrets set GEMINI_API_KEY=your-gemini-api-key

# Optional: Configure LLM provider (defaults to gemini)
supabase secrets set LLM_PROVIDER=gemini

# Optional: Configure model (defaults to gemini-2.0-flash)
supabase secrets set GEMINI_MODEL=gemini-2.0-flash
```

### 4. Deploy Functions

```bash
# Deploy all functions
supabase functions deploy

# Or deploy individually
supabase functions deploy generate-config
supabase functions deploy suggest-songs
supabase functions deploy analyze-taste
```

## Local Development

### Start Local Supabase

```bash
supabase start
```

### Serve Functions Locally

```bash
supabase functions serve --env-file ./supabase/.env.local
```

Create `supabase/.env.local` with:

```
GEMINI_API_KEY=your-api-key
LLM_PROVIDER=gemini
```

### Test Functions

```bash
# Test generate-config
curl -X POST http://localhost:54321/functions/v1/generate-config \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{"prompt": "chill music for studying"}'

# Test suggest-songs
curl -X POST http://localhost:54321/functions/v1/suggest-songs \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "config": {
      "name": "Study Vibes",
      "originalPrompt": "chill music for studying",
      "contextDescription": "Relaxed focus music",
      "suggestedGenres": ["Lo-fi", "Ambient"],
      "moodKeywords": ["calm", "focus"],
      "valenceWeight": 1.0,
      "energyWeight": 1.0,
      "danceabilityWeight": 0.8,
      "bpmWeight": 0.8,
      "acousticnessWeight": 0.5,
      "instrumentalnessWeight": 0.5
    },
    "likedSongs": [],
    "dislikedSongs": [],
    "recentlyPlayed": [],
    "count": 5
  }'
```

## Switching LLM Providers

The functions support multiple LLM providers. Set via secrets:

```bash
# Use OpenAI
supabase secrets set LLM_PROVIDER=openai
supabase secrets set OPENAI_API_KEY=your-openai-key
supabase secrets set OPENAI_MODEL=gpt-4o

# Use Anthropic
supabase secrets set LLM_PROVIDER=anthropic
supabase secrets set ANTHROPIC_API_KEY=your-anthropic-key
supabase secrets set ANTHROPIC_MODEL=claude-sonnet-4-20250514
```

## Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `INVALID_REQUEST` | 400 | Invalid input from client |
| `MISSING_FIELD` | 400 | Required field not provided |
| `UNAUTHORIZED` | 401 | Missing or invalid auth |
| `PARSE_ERROR` | 422 | LLM response couldn't be parsed |
| `RATE_LIMITED` | 429 | Too many requests |
| `LLM_ERROR` | 502 | Error from LLM provider |
| `INTERNAL_ERROR` | 500 | Server error |

## Architecture

```
iOS App
   │
   ▼
BackendStationService.swift
   │
   ▼ HTTP POST (JSON)
   │
Supabase Edge Functions
   │
   ├── _shared/
   │   ├── cors.ts          # CORS handling
   │   ├── errors.ts        # Error responses
   │   ├── types.ts         # Shared types
   │   ├── prompts.ts       # LLM prompts
   │   └── llm-provider.ts  # Provider abstraction
   │
   ├── generate-config/
   ├── suggest-songs/
   └── analyze-taste/
          │
          ▼
     LLM Provider (Gemini/OpenAI/Anthropic)
```
