/**
 * LLM Provider Abstraction
 *
 * Allows easy switching between LLM providers (Gemini, OpenAI, Anthropic)
 * via environment variable: LLM_PROVIDER=gemini|openai|anthropic
 */

// MARK: - Provider Interface

export interface LLMProvider {
  /**
   * Generate content from system and user prompts
   */
  generateContent(systemPrompt: string, userPrompt: string): Promise<string>;
}

// MARK: - Gemini Provider

class GeminiProvider implements LLMProvider {
  private apiKey: string;
  private model: string;

  constructor() {
    const apiKey = Deno.env.get("GEMINI_API_KEY");
    if (!apiKey) {
      throw new Error("GEMINI_API_KEY environment variable is not set");
    }
    this.apiKey = apiKey;
    this.model = Deno.env.get("GEMINI_MODEL") || "gemini-2.0-flash";
  }

  async generateContent(
    systemPrompt: string,
    userPrompt: string
  ): Promise<string> {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent?key=${this.apiKey}`;

    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        contents: [
          {
            parts: [
              {
                text: `${systemPrompt}\n\n${userPrompt}`,
              },
            ],
          },
        ],
        generationConfig: {
          temperature: 0.7,
          topP: 0.95,
          topK: 40,
          maxOutputTokens: 8192,
        },
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Gemini API error: ${response.status} - ${errorText}`);
    }

    const data = await response.json();

    // Extract text from Gemini response
    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!text) {
      throw new Error("No text content in Gemini response");
    }

    return text;
  }
}

// MARK: - OpenAI Provider (Future)

class OpenAIProvider implements LLMProvider {
  private apiKey: string;
  private model: string;

  constructor() {
    const apiKey = Deno.env.get("OPENAI_API_KEY");
    if (!apiKey) {
      throw new Error("OPENAI_API_KEY environment variable is not set");
    }
    this.apiKey = apiKey;
    this.model = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini";
  }

  async generateContent(
    systemPrompt: string,
    userPrompt: string
  ): Promise<string> {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify({
        model: this.model,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        temperature: 0.7,
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`OpenAI API error: ${response.status} - ${errorText}`);
    }

    const data = await response.json();
    const text = data?.choices?.[0]?.message?.content;
    if (!text) {
      throw new Error("No text content in OpenAI response");
    }

    return text;
  }
}

// MARK: - Anthropic Provider (Future)

class AnthropicProvider implements LLMProvider {
  private apiKey: string;
  private model: string;

  constructor() {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      throw new Error("ANTHROPIC_API_KEY environment variable is not set");
    }
    this.apiKey = apiKey;
    this.model = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-4-20250514";
  }

  async generateContent(
    systemPrompt: string,
    userPrompt: string
  ): Promise<string> {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": this.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: this.model,
        max_tokens: 8192,
        system: systemPrompt,
        messages: [{ role: "user", content: userPrompt }],
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Anthropic API error: ${response.status} - ${errorText}`);
    }

    const data = await response.json();
    const text = data?.content?.[0]?.text;
    if (!text) {
      throw new Error("No text content in Anthropic response");
    }

    return text;
  }
}

// MARK: - Provider Factory

type ProviderType = "gemini" | "openai" | "anthropic";

let cachedProvider: LLMProvider | null = null;

/**
 * Get the configured LLM provider
 * Defaults to Gemini if LLM_PROVIDER is not set
 */
export function getLLMProvider(): LLMProvider {
  if (cachedProvider) {
    return cachedProvider;
  }

  const providerType = (Deno.env.get("LLM_PROVIDER") || "openai") as ProviderType;

  switch (providerType) {
    case "gemini":
      cachedProvider = new GeminiProvider();
      break;
    case "openai":
      cachedProvider = new OpenAIProvider();
      break;
    case "anthropic":
      cachedProvider = new AnthropicProvider();
      break;
    default:
      throw new Error(`Unknown LLM provider: ${providerType}`);
  }

  return cachedProvider;
}

/**
 * Clean JSON response from LLM (remove markdown code blocks if present)
 */
export function cleanJsonResponse(text: string): string {
  let cleaned = text.trim();

  // Remove markdown code blocks
  if (cleaned.startsWith("```json")) {
    cleaned = cleaned.slice(7);
  } else if (cleaned.startsWith("```")) {
    cleaned = cleaned.slice(3);
  }

  if (cleaned.endsWith("```")) {
    cleaned = cleaned.slice(0, -3);
  }

  return cleaned.trim();
}
