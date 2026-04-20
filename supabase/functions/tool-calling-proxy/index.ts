/**
 * Tool-Calling LLM Proxy Edge Function
 *
 * Thin proxy that forwards tool-calling conversations to the configured LLM provider.
 * Translates between a normalized message format and provider-specific tool-calling APIs.
 * API keys stay server-side; the client only sends messages and tool definitions.
 *
 * Supports: Gemini, OpenAI, Anthropic (configurable via LLM_PROVIDER env var)
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// MARK: - Normalized Types (from client)

interface ToolCallingMessage {
  role: "system" | "user" | "assistant" | "tool";
  content?: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

interface ToolCall {
  id: string;
  name: string;
  arguments: string; // JSON string
}

interface ToolDefinition {
  name: string;
  description: string;
  parameters: {
    type: string;
    properties: Record<string, any>;
    required: string[];
  };
}

interface ProxyRequest {
  messages: ToolCallingMessage[];
  tools: ToolDefinition[];
}

interface ProxyResponse {
  stop_reason: "tool_use" | "end_turn" | "max_tokens";
  content?: string;
  tool_calls?: ToolCall[];
}

// MARK: - Anthropic Provider

async function callAnthropic(
  messages: ToolCallingMessage[],
  tools: ToolDefinition[]
): Promise<ProxyResponse> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY not set");
  const model = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-4-20250514";

  // Extract system message
  const systemMsg = messages.find((m) => m.role === "system");
  const conversationMsgs = messages.filter((m) => m.role !== "system");

  // Convert to Anthropic format
  const anthropicMessages = conversationMsgs.map((msg) => {
    if (msg.role === "assistant" && msg.tool_calls?.length) {
      return {
        role: "assistant" as const,
        content: msg.tool_calls.map((tc) => ({
          type: "tool_use" as const,
          id: tc.id,
          name: tc.name,
          input: JSON.parse(tc.arguments),
        })),
      };
    }
    if (msg.role === "tool") {
      return {
        role: "user" as const,
        content: [
          {
            type: "tool_result" as const,
            tool_use_id: msg.tool_call_id,
            content: msg.content || "",
          },
        ],
      };
    }
    return { role: msg.role as "user" | "assistant", content: msg.content || "" };
  });

  // Merge consecutive user messages (Anthropic requires alternating roles)
  const mergedMessages: any[] = [];
  for (const msg of anthropicMessages) {
    if (
      mergedMessages.length > 0 &&
      mergedMessages[mergedMessages.length - 1].role === msg.role &&
      msg.role === "user"
    ) {
      const prev = mergedMessages[mergedMessages.length - 1];
      // Merge content arrays or strings
      const prevContent = Array.isArray(prev.content) ? prev.content : [{ type: "text", text: prev.content }];
      const currContent = Array.isArray(msg.content) ? msg.content : [{ type: "text", text: msg.content }];
      prev.content = [...prevContent, ...currContent];
    } else {
      mergedMessages.push({ ...msg });
    }
  }

  const anthropicTools = tools.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: t.parameters,
  }));

  const body: any = {
    model,
    max_tokens: 8192,
    messages: mergedMessages,
  };
  if (systemMsg?.content) {
    body.system = systemMsg.content;
  }
  if (anthropicTools.length > 0) {
    body.tools = anthropicTools;
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Anthropic API error: ${response.status} - ${errorText}`);
  }

  const data = await response.json();

  // Parse response
  const toolUseBlocks = data.content?.filter((b: any) => b.type === "tool_use") || [];
  const textBlocks = data.content?.filter((b: any) => b.type === "text") || [];

  if (toolUseBlocks.length > 0) {
    return {
      stop_reason: "tool_use",
      tool_calls: toolUseBlocks.map((b: any) => ({
        id: b.id,
        name: b.name,
        arguments: JSON.stringify(b.input),
      })),
      content: textBlocks.map((b: any) => b.text).join("\n") || undefined,
    };
  }

  return {
    stop_reason: data.stop_reason === "max_tokens" ? "max_tokens" : "end_turn",
    content: textBlocks.map((b: any) => b.text).join("\n") || "",
  };
}

// MARK: - OpenAI Provider

async function callOpenAI(
  messages: ToolCallingMessage[],
  tools: ToolDefinition[]
): Promise<ProxyResponse> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("OPENAI_API_KEY not set");
  const model = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini";

  // Convert to OpenAI format
  const openaiMessages = messages.map((msg) => {
    if (msg.role === "assistant" && msg.tool_calls?.length) {
      return {
        role: "assistant" as const,
        content: msg.content || null,
        tool_calls: msg.tool_calls.map((tc) => ({
          id: tc.id,
          type: "function" as const,
          function: { name: tc.name, arguments: tc.arguments },
        })),
      };
    }
    if (msg.role === "tool") {
      return {
        role: "tool" as const,
        tool_call_id: msg.tool_call_id,
        content: msg.content || "",
      };
    }
    return { role: msg.role, content: msg.content || "" };
  });

  const openaiTools = tools.map((t) => ({
    type: "function" as const,
    function: {
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    },
  }));

  const body: any = {
    model,
    messages: openaiMessages,
    temperature: 0.7,
  };
  if (openaiTools.length > 0) {
    body.tools = openaiTools;
  }

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`OpenAI API error: ${response.status} - ${errorText}`);
  }

  const data = await response.json();
  const choice = data.choices?.[0];

  if (choice?.finish_reason === "tool_calls" || choice?.message?.tool_calls?.length) {
    return {
      stop_reason: "tool_use",
      tool_calls: choice.message.tool_calls.map((tc: any) => ({
        id: tc.id,
        name: tc.function.name,
        arguments: tc.function.arguments,
      })),
      content: choice.message.content || undefined,
    };
  }

  return {
    stop_reason: choice?.finish_reason === "length" ? "max_tokens" : "end_turn",
    content: choice?.message?.content || "",
  };
}

// MARK: - Gemini Provider

async function callGemini(
  messages: ToolCallingMessage[],
  tools: ToolDefinition[]
): Promise<ProxyResponse> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("GEMINI_API_KEY not set");
  const model = Deno.env.get("GEMINI_MODEL") || "gemini-2.0-flash";

  // Extract system instruction
  const systemMsg = messages.find((m) => m.role === "system");
  const conversationMsgs = messages.filter((m) => m.role !== "system");

  // Convert to Gemini format
  const contents: any[] = [];
  for (const msg of conversationMsgs) {
    if (msg.role === "user") {
      contents.push({ role: "user", parts: [{ text: msg.content || "" }] });
    } else if (msg.role === "assistant" && msg.tool_calls?.length) {
      contents.push({
        role: "model",
        parts: msg.tool_calls.map((tc) => ({
          functionCall: { name: tc.name, args: JSON.parse(tc.arguments) },
        })),
      });
    } else if (msg.role === "assistant") {
      contents.push({ role: "model", parts: [{ text: msg.content || "" }] });
    } else if (msg.role === "tool") {
      contents.push({
        role: "user",
        parts: [
          {
            functionResponse: {
              name: "tool_result",
              response: { content: msg.content || "" },
            },
          },
        ],
      });
    }
  }

  const geminiTools =
    tools.length > 0
      ? [
          {
            function_declarations: tools.map((t) => ({
              name: t.name,
              description: t.description,
              parameters: t.parameters,
            })),
          },
        ]
      : undefined;

  const body: any = {
    contents,
    generationConfig: {
      temperature: 0.7,
      topP: 0.95,
      maxOutputTokens: 8192,
    },
  };
  if (systemMsg?.content) {
    body.system_instruction = { parts: [{ text: systemMsg.content }] };
  }
  if (geminiTools) {
    body.tools = geminiTools;
  }

  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Gemini API error: ${response.status} - ${errorText}`);
  }

  const data = await response.json();
  const candidate = data.candidates?.[0];
  const parts = candidate?.content?.parts || [];

  const functionCalls = parts.filter((p: any) => p.functionCall);
  const textParts = parts.filter((p: any) => p.text);

  if (functionCalls.length > 0) {
    return {
      stop_reason: "tool_use",
      tool_calls: functionCalls.map((p: any, i: number) => ({
        id: `gemini_call_${Date.now()}_${i}`,
        name: p.functionCall.name,
        arguments: JSON.stringify(p.functionCall.args),
      })),
      content: textParts.map((p: any) => p.text).join("\n") || undefined,
    };
  }

  return {
    stop_reason: candidate?.finishReason === "MAX_TOKENS" ? "max_tokens" : "end_turn",
    content: textParts.map((p: any) => p.text).join("\n") || "",
  };
}

// MARK: - Provider Router

async function callLLM(
  messages: ToolCallingMessage[],
  tools: ToolDefinition[]
): Promise<ProxyResponse> {
  const provider = Deno.env.get("LLM_PROVIDER") || "openai";

  switch (provider) {
    case "anthropic":
      return callAnthropic(messages, tools);
    case "openai":
      return callOpenAI(messages, tools);
    case "gemini":
      return callGemini(messages, tools);
    default:
      throw new Error(`Unknown LLM_PROVIDER: ${provider}`);
  }
}

// MARK: - Edge Function Handler

serve(async (req) => {
  // CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const body: ProxyRequest = await req.json();

    if (!body.messages || !Array.isArray(body.messages)) {
      return new Response(
        JSON.stringify({ error: { code: "invalid_request", message: "messages array required" } }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    const result = await callLLM(body.messages, body.tools || []);

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Tool-calling proxy error:", error);

    const status = error.message?.includes("API error: 429") ? 429 : 500;
    return new Response(
      JSON.stringify({
        error: {
          code: status === 429 ? "rate_limited" : "server_error",
          message: error.message || "Unknown error",
        },
      }),
      { status, headers: { "Content-Type": "application/json" } }
    );
  }
});
