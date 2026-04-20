//
//  ToolCallingLLMBackend.swift
//  Curate
//
//  Abstracts the LLM call in the tool-calling loop so we can swap
//  between Supabase edge function proxy and local on-device models.
//

import Foundation
import Supabase

// MARK: - Protocol

/// Abstraction for the LLM call within the tool-calling orchestrator loop.
/// Each turn, the orchestrator sends the full conversation + tool definitions
/// and gets back either a text response (final answer) or tool call requests.
protocol ToolCallingLLMBackend {
    func callLLM(
        messages: [ToolCallingMessage],
        tools: [ToolDefinition]
    ) async throws -> ToolCallingLLMResponse
}

// MARK: - Supabase Backend (production)

/// Proxies LLM calls through a Supabase Edge Function ("tool-calling-proxy").
/// The edge function forwards to Claude/GPT server-side, keeping API keys secure.
struct SupabaseToolCallingBackend: ToolCallingLLMBackend {
    private let supabaseClient: SupabaseClient

    init(supabaseClient: SupabaseClient = SupabaseConfig.client) {
        self.supabaseClient = supabaseClient
    }

    func callLLM(
        messages: [ToolCallingMessage],
        tools: [ToolDefinition]
    ) async throws -> ToolCallingLLMResponse {
        let requestBody = ToolCallingProxyRequest(
            messages: messages,
            tools: tools
        )

        let response: ToolCallingLLMResponse = try await supabaseClient.functions.invoke(
            "tool-calling-proxy",
            options: FunctionInvokeOptions(body: requestBody)
        )

        return response
    }
}

// MARK: - Local Backend (on-device)

/// Uses a LocalLLMProvider (e.g. Apple Intelligence) to drive the tool-calling loop.
/// Since local models don't have native function-calling APIs, we simulate it:
/// the model outputs JSON that we parse into tool calls or a final response.
@MainActor
struct LocalToolCallingBackend: ToolCallingLLMBackend {
    private let provider: LocalLLMProvider

    init(provider: LocalLLMProvider) {
        self.provider = provider
    }

    /// Token budget for the local model. Leave 512 tokens headroom for the response.
    private static let tokenBudget = 4096 - 512

    func callLLM(
        messages: [ToolCallingMessage],
        tools: [ToolDefinition]
    ) async throws -> ToolCallingLLMResponse {
        // If tool results are already in the conversation, extract tracks directly.
        // The local model is unreliable at transcribing structured IDs from tool results —
        // it tends to output empty tracks arrays. Since the approach tools already return
        // complete, resolved track data, we can parse it ourselves and skip the LLM entirely.
        if let directResponse = buildFinalResponseFromToolResults(messages) {
            return directResponse
        }

        // First turn: classify the user's intent deterministically and build the tool call.
        // This is faster and more reliable than asking the on-device model to pick a tool —
        // it can't output literal template values or pick the wrong tool this way.
        if let classifiedResponse = classifyAndBuildToolCall(messages: messages) {
            return classifiedResponse
        }

        // Fallback: if classification fails (e.g. unexpected message shape),
        // ask the model to pick one of the 5 high-level approach tools.
        // Only send approach tools (build_*) to stay well within the 4096 token limit.
        let approachTools = tools.filter { $0.name.hasPrefix("build_") }
        let effectiveTools = approachTools.isEmpty ? tools : approachTools

        let systemMessage = localSystemPrompt(tools: effectiveTools)
        let userMessage = buildConversationBody(messages: messages, tokenBudget: Self.tokenBudget - estimateTokens(systemMessage))

        let rawResponse = try await provider.generate(system: systemMessage, user: userMessage)
        return parseResponse(rawResponse)
    }

    /// Use the intent classifier to deterministically pick a tool + arguments.
    /// Bypasses the LLM entirely on turn 1.
    private func classifyAndBuildToolCall(messages: [ToolCallingMessage]) -> ToolCallingLLMResponse? {
        // Extract the user's original prompt (first user message)
        guard let userPrompt = messages
            .first(where: { $0.role == .user })?
            .content, !userPrompt.isEmpty else {
            return nil
        }

        // Classify and build tool call
        let intent = IntentClassifier.classify(prompt: userPrompt)
        let (toolName, argumentsDict) = IntentClassifier.toolCall(for: intent)

        // Serialize arguments to JSON string (ToolCall.arguments is a string)
        guard let argsData = try? JSONSerialization.data(withJSONObject: argumentsDict),
              let argsString = String(data: argsData, encoding: .utf8) else {
            return nil
        }

        let toolCall = ToolCall(
            id: "call_classified_1",
            name: toolName,
            arguments: argsString
        )

        return ToolCallingLLMResponse(
            stopReason: "tool_use",
            content: nil,
            toolCalls: [toolCall]
        )
    }

    /// Parse tracks directly from approach tool results, bypassing the second LLM turn.
    /// Approach tools return JSON with a `tracks` array containing `id`, `title`, `artistName`.
    private func buildFinalResponseFromToolResults(_ messages: [ToolCallingMessage]) -> ToolCallingLLMResponse? {
        let toolResultMessages = messages.filter { $0.role == .tool }
        guard !toolResultMessages.isEmpty else { return nil }

        for message in toolResultMessages {
            guard let content = message.content,
                  let data = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [[String: Any]],
                  !tracks.isEmpty else { continue }

            // ToolResult uses .convertToSnakeCase encoding, so keys are already snake_case
            let mappedTracks: [[String: Any]] = tracks.compactMap { track in
                guard let id = track["id"] as? String, !id.isEmpty else { return nil }
                return [
                    "id": id,
                    "title": track["title"] as? String ?? "",
                    "artist_name": track["artist_name"] as? String ?? "",
                    "reason": "Source: \(track["source"] as? String ?? "recommendation")"
                ]
            }

            guard !mappedTracks.isEmpty else { continue }

            // Infer approach name from the preceding assistant tool call
            let approachName = messages
                .filter { $0.role == .assistant }
                .compactMap { $0.toolCalls?.first?.name }
                .last ?? "approach"

            let finalJSON: [String: Any] = [
                "tracks": mappedTracks,
                "approach_used": approachName,
                "reasoning": "Tracks curated via \(approachName)"
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: finalJSON),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return ToolCallingLLMResponse(stopReason: "end_turn", content: jsonString, toolCalls: nil)
            }
        }

        return nil
    }

    // MARK: - Prompt Building

    /// Compact system prompt + tool list designed to stay well under 4096 tokens.
    /// Schemas are omitted — local model only needs name + description to pick a tool.
    /// No final-response template — buildFinalResponseFromToolResults handles that.
    private func localSystemPrompt(tools: [ToolDefinition]) -> String {
        var text = """
        You are a music curation AI. The user will describe what music they want. \
        Pick the ONE tool below that best matches and call it. \
        Respond with ONLY valid JSON in this exact format: \
        {"tool_calls":[{"id":"call_1","name":"TOOL_NAME","arguments":{"seed_artist":"ARTIST"}}]}
        Replace TOOL_NAME with the tool name and fill in the arguments. Do not output anything else.

        Tools:
        """

        for tool in tools {
            let shortDesc = tool.description.components(separatedBy: ".").first?.trimmingCharacters(in: .whitespaces) ?? tool.description
            text += "\n- \(tool.name): \(shortDesc)."
        }

        return text
    }

    /// Rough token estimate: 1 token ≈ 4 characters.
    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Build the conversation body, trimming oldest tool results to stay within budget.
    private func buildConversationBody(messages: [ToolCallingMessage], tokenBudget: Int) -> String {
        // Render each non-system message into a labelled string
        var parts: [(isTrimmable: Bool, text: String)] = []

        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                if let content = message.content {
                    parts.append((false, "User: \(content)"))
                }
            case .assistant:
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    let calls = toolCalls.map { "  - \($0.name)(\($0.arguments))" }.joined(separator: "\n")
                    parts.append((false, "Assistant called tools:\n\(calls)"))
                } else if let content = message.content {
                    parts.append((false, "Assistant: \(content)"))
                }
            case .tool:
                if let content = message.content, let id = message.toolCallId {
                    // Cap each tool result at 600 chars before budget check
                    let capped = content.count > 600
                        ? String(content.prefix(600)) + "\n...(truncated)"
                        : content
                    parts.append((true, "Tool result (\(id)): \(capped)"))
                }
            case .system:
                break
            }
        }

        // Proactively drop oldest trimmable (tool result) entries until under budget
        var joined = parts.map(\.text).joined(separator: "\n\n")
        var trimIndex = 0
        while estimateTokens(joined) > tokenBudget, trimIndex < parts.count {
            if parts[trimIndex].isTrimmable {
                parts[trimIndex] = (false, "") // blank it out
                joined = parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            trimIndex += 1
        }

        return joined
    }

    // MARK: - Response Parsing

    private func parseResponse(_ text: String) -> ToolCallingLLMResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON from potential markdown code blocks
        let json = extractJSON(from: trimmed)

        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // If we can't parse, treat as final text response
            return ToolCallingLLMResponse(stopReason: "end_turn", content: trimmed, toolCalls: nil)
        }

        // Check if it contains tool_calls
        if let toolCallsArray = dict["tool_calls"] as? [[String: Any]], !toolCallsArray.isEmpty {
            let toolCalls = toolCallsArray.compactMap { callDict -> ToolCall? in
                guard let id = callDict["id"] as? String,
                      let name = callDict["name"] as? String else { return nil }

                let arguments: String
                if let argsString = callDict["arguments"] as? String {
                    arguments = argsString
                } else if let argsDict = callDict["arguments"] as? [String: Any],
                          let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                          let argsStr = String(data: argsData, encoding: .utf8) {
                    arguments = argsStr
                } else {
                    arguments = "{}"
                }

                return ToolCall(id: id, name: name, arguments: arguments)
            }

            if !toolCalls.isEmpty {
                return ToolCallingLLMResponse(stopReason: "tool_use", content: nil, toolCalls: toolCalls)
            }
        }

        // Check if it contains "tracks" (final selection)
        if dict["tracks"] != nil {
            return ToolCallingLLMResponse(stopReason: "end_turn", content: json, toolCalls: nil)
        }

        // Fallback: treat as text
        return ToolCallingLLMResponse(stopReason: "end_turn", content: trimmed, toolCalls: nil)
    }

    private func extractJSON(from text: String) -> String {
        // Strip markdown code blocks
        var cleaned = text
        if let start = cleaned.range(of: "```json\n", options: .caseInsensitive),
           let end = cleaned.range(of: "\n```", options: .caseInsensitive, range: start.upperBound..<cleaned.endIndex) {
            return String(cleaned[start.upperBound..<end.lowerBound])
        }
        if let start = cleaned.range(of: "```\n"),
           let end = cleaned.range(of: "\n```", range: start.upperBound..<cleaned.endIndex) {
            return String(cleaned[start.upperBound..<end.lowerBound])
        }

        // Find first { to last }
        if let first = cleaned.firstIndex(of: "{"),
           let last = cleaned.lastIndex(of: "}") {
            return String(cleaned[first...last])
        }

        return text
    }
}
