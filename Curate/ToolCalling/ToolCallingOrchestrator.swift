//
//  ToolCallingOrchestrator.swift
//  Curate
//
//  On-device orchestrator that runs the LLM tool-call loop.
//  Sends messages + tool definitions to the LLM proxy edge function,
//  receives tool calls, executes them locally via MusicKit, and loops
//  until the LLM returns a final answer.
//

import Foundation
import MusicKit

// MARK: - Orchestrator Configuration

struct OrchestratorConfig {
    /// Maximum tool-call turns before forcing completion
    var maxTurns: Int = 10

    /// System prompt describing the LLM's role
    var systemPrompt: String = Self.defaultSystemPrompt

    static let defaultSystemPrompt = """
        You are a music curation AI. Use the tools available to find tracks matching the user's request.

        TOOL CALLING RULES:
        - Single signal (one mood, one artist, or one genre): call the matching tool directly.
        - Multiple signals (e.g. a mood AND an artist, or a genre AND a vibe): call ALL relevant \
        tools in the same response simultaneously — do not wait for one result before calling the next.
        - Never chain tools sequentially when they can be called in parallel.

        Aim for 25-50 tracks. When finished, return ONLY this JSON object, no markdown:
        {
          "tracks": [{"id": "apple_music_id", "title": "...", "artist_name": "...", "reason": "..."}],
          "approach_used": "artist_graph | playlist_mining | song_seeded | personalized | genre_chart | hybrid",
          "reasoning": "Brief explanation"
        }
        """
}

// MARK: - Orchestrator Result

struct StationBuildResult {
    let tracks: [SelectedTrack]
    let approachUsed: String
    let reasoning: String
    let turnsUsed: Int
}

struct SelectedTrack: Codable {
    let id: String
    let title: String?
    let artistName: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, title, reason
        case artistName = "artist_name"
    }
}

// MARK: - Orchestrator

final class ToolCallingOrchestrator {
    private let registry: MusicToolRegistry
    private let executor: MusicToolExecutor
    private let cache: ToolResultCache
    private let llmBackend: ToolCallingLLMBackend
    private let config: OrchestratorConfig

    /// Progress callback — called each turn with a status message
    var onProgress: ((String) -> Void)?

    init(
        registry: MusicToolRegistry,
        cache: ToolResultCache,
        llmBackend: ToolCallingLLMBackend = SupabaseToolCallingBackend(),
        config: OrchestratorConfig = OrchestratorConfig()
    ) {
        self.registry = registry
        self.executor = MusicToolExecutor(registry: registry)
        self.cache = cache
        self.llmBackend = llmBackend
        self.config = config
    }

    /// Build a station from a user prompt. Runs the full tool-call loop.
    func buildStation(prompt: String, userPreferences: UserPreferences? = nil) async throws -> StationBuildResult {
        // Build system prompt with preferences context
        var systemPrompt = config.systemPrompt
        if let prefs = userPreferences {
            systemPrompt += "\n\nUSER PREFERENCES:"
            if !prefs.preferredGenres.isEmpty {
                systemPrompt += "\n- Preferred genres: \(prefs.preferredGenres.joined(separator: ", "))"
            }
            systemPrompt += "\n- Exploration level: \(prefs.temperature) (0=familiar, 1=adventurous)"
        }

        // Cloud AI path: expose all 5 approach tools and let the LLM classify intent freely.
        // The LLM (GPT-4o-mini) is a better classifier than the deterministic IntentClassifier
        // for hybrid prompts (e.g. "rainy afternoon songs like The 1975") and can call multiple
        // tools in parallel when the request warrants it.
        //
        // COMMENTED OUT: Intent-gated tool scoping (kept for reference / local AI path)
        // let intent = IntentClassifier.classify(prompt: prompt)
        // let scopedToolNames = IntentClassifier.relevantToolNames(for: intent)
        // let scopedTools = registry.definitions.filter { scopedToolNames.contains($0.name) }
        // let toolsForFirstTurn = scopedTools.isEmpty ? registry.definitions : scopedTools

        let toolsForFirstTurn = registry.definitions.filter { $0.name.hasPrefix("build_") }

        let toolListDesc = toolsForFirstTurn.map(\.name).joined(separator: ", ")
        print("🎯 Orchestrator tools=[\(toolListDesc)] (of \(registry.definitions.count) total)")
        onProgress?("Tools: \(toolListDesc)")

        // Initialize conversation
        var messages: [ToolCallingMessage] = [
            .system(systemPrompt),
            .user(prompt)
        ]

        var turnsUsed = 0
        var approachToolSucceeded = false
        /// Collects (toolName, compressedContent) for every approach tool that returned tracks.
        /// Used to build the final result directly without a separate LLM formatting turn.
        var directReturnContent: [(toolName: String, content: String)] = []

        // Tool-call loop
        while turnsUsed < config.maxTurns {
            turnsUsed += 1

            // Always send all 5 approach tool schemas — we return directly when a tool
            // succeeds so there is no separate "format final JSON" turn that needs schemas.
            let toolsForThisTurn = toolsForFirstTurn
            print("🎯 Turn \(turnsUsed): sending \(toolsForThisTurn.count) tool schemas")

            // Call LLM via edge function
            let llmResponse = try await callLLMProxy(
                messages: messages,
                tools: toolsForThisTurn
            )

            // If LLM returned text (final answer), parse and return
            if llmResponse.isComplete || !llmResponse.isToolUse {
                guard let content = llmResponse.content else {
                    throw ToolError.executionFailed("LLM returned empty response")
                }
                return try parseFinalResponse(content: content, turnsUsed: turnsUsed)
            }

            // LLM wants to call tools
            guard let toolCalls = llmResponse.toolCalls, !toolCalls.isEmpty else {
                throw ToolError.executionFailed("LLM indicated tool_use but returned no tool calls")
            }

            // Add assistant message with tool calls to conversation
            messages.append(.assistant(toolCalls: toolCalls))

            // Execute each tool call (with caching)
            for call in toolCalls {
                onProgress?("Calling \(call.name)...")

                let result: ToolResult
                if let cached = cache.get(tool: call.name, arguments: call.argumentsData) {
                    result = cached
                } else {
                    result = await executor.execute(call)
                    cache.set(tool: call.name, arguments: call.argumentsData, result: result)
                }

                // Compress heavy approach tool results before re-injecting into context —
                // the LLM only needs id/title/artist_name to reference tracks in its final selection.
                let injectedContent = Self.compressToolResult(result.contentString, toolName: call.name)
                messages.append(.toolResult(id: call.id, content: injectedContent))

                // Log raw track count before compression so we can see exactly
                // what each approach tool returned, independent of LLM selection.
                if call.name.hasPrefix("build_") {
                    let rawCount = Self.trackCount(from: result.contentString)
                    print("🎯 \(call.name) returned \(rawCount) tracks (pre-compression)")
                    if !result.isError && Self.toolResultHasTracks(injectedContent) {
                        approachToolSucceeded = true
                        directReturnContent.append((toolName: call.name, content: injectedContent))
                    }
                }
            }

            // Auto-fallback: if any approach tool returned 0 tracks, try tool-specific
            // recovery strategies without an LLM round-trip. Each tool has a targeted
            // fallback that makes semantic sense for its failure mode.
            // If all tool-specific fallbacks also fail, escalate to LLM knowledge fallback.
            if !approachToolSucceeded {
                let failedApproachCalls = toolCalls.filter { $0.name.hasPrefix("build_") }

                outerLoop: for failedCall in failedApproachCalls {
                    let fallbacks = Self.toolSpecificFallback(for: failedCall, prompt: prompt)

                    for (fallbackName, fallbackArgs) in fallbacks {
                        guard let argsData = try? JSONSerialization.data(withJSONObject: fallbackArgs),
                              let argsString = String(data: argsData, encoding: .utf8) else { continue }

                        let fallbackCall = ToolCall(
                            id: "fallback_\(fallbackName)_\(turnsUsed)",
                            name: fallbackName,
                            arguments: argsString
                        )

                        onProgress?("Fallback: \(fallbackName)...")
                        print("🎯 Fallback for \(failedCall.name) → \(fallbackName)")

                        let fallbackResult: ToolResult
                        if let cached = cache.get(tool: fallbackName, arguments: argsData) {
                            fallbackResult = cached
                        } else {
                            fallbackResult = await executor.execute(fallbackCall)
                            cache.set(tool: fallbackName, arguments: argsData, result: fallbackResult)
                        }

                        let compressedFallback = Self.compressToolResult(
                            fallbackResult.contentString, toolName: fallbackName
                        )
                        // Append as synthetic assistant + tool result pair so the LLM
                        // sees the fallback result in context for its final response.
                        messages.append(.assistant(toolCalls: [fallbackCall]))
                        messages.append(.toolResult(id: fallbackCall.id, content: compressedFallback))

                        let fallbackCount = Self.trackCount(from: fallbackResult.contentString)
                        print("🎯 Fallback \(fallbackName) returned \(fallbackCount) tracks (pre-compression)")
                        if !fallbackResult.isError && Self.toolResultHasTracks(compressedFallback) {
                            approachToolSucceeded = true
                            directReturnContent.append((toolName: fallbackName, content: compressedFallback))
                            break outerLoop
                        }
                    }
                }

                // All tool-specific fallbacks exhausted with 0 tracks.
                // Last resort: ask the LLM to generate songs from training knowledge,
                // then resolve them via MusicKit catalog search. Terminal — returns directly.
                if !approachToolSucceeded {
                    return try await llmKnowledgeFallback(prompt: prompt, turnsUsed: turnsUsed)
                }
            }

            // Approach tool succeeded — return directly from tool output, bypassing
            // the LLM formatting turn. The tool already did the curation; letting the
            // LLM re-select causes cherry-picking (4 tracks instead of 50) and wrong
            // selections based on title keywords rather than actual vibe.
            if approachToolSucceeded {
                return try buildResultFromToolOutputs(directReturnContent, turnsUsed: turnsUsed)
            }
        }

        // Hit max turns — ask LLM to wrap up
        messages.append(.user("You've used all available turns. Please return your final track selection now as the JSON object."))
        let finalResponse = try await callLLMProxy(messages: messages, tools: [])
        guard let content = finalResponse.content else {
            throw ToolError.executionFailed("LLM could not produce final selection within \(config.maxTurns) turns")
        }
        return try parseFinalResponse(content: content, turnsUsed: turnsUsed)
    }

    // MARK: - LLM Call

    private func callLLMProxy(
        messages: [ToolCallingMessage],
        tools: [ToolDefinition]
    ) async throws -> ToolCallingLLMResponse {
        try await llmBackend.callLLM(messages: messages, tools: tools)
    }

    /// Build reasonable default arguments for an auto-fallback tool call.
    /// NOTE: Not used by the cloud AI path (which returns directly from tool output).
    /// Retained for the local AI path (LocalToolCallingBackend) where intent is still classified.
    static func fallbackArguments(
        for toolName: String,
        prompt: String,
        intent: IntentCategory
    ) -> [String: Any] {
        switch toolName {
        case "build_playlist_mining_station":
            return ["intent": prompt, "track_count": 50]

        case "build_personalized_station":
            return ["track_count": 50]

        case "build_artist_graph_station":
            if case .artist(let name) = intent {
                return ["seed_artist": name, "temperature": 0.5, "track_count": 50]
            }
            return ["seed_artist": prompt, "temperature": 0.5, "track_count": 50]

        case "build_song_seeded_station":
            if case .song(let title, let artist) = intent {
                var args: [String: Any] = ["song_title": title, "track_count": 50]
                if let a = artist { args["artist_name"] = a }
                return args
            }
            return ["song_title": prompt, "track_count": 50]

        case "build_genre_chart_station":
            if case .genre(let name, let decade) = intent {
                var args: [String: Any] = ["genre": name, "track_count": 50]
                if let d = decade { args["decade"] = d }
                return args
            }
            return ["genre": prompt, "track_count": 50]

        default:
            return ["track_count": 50]
        }
    }

    /// Returns an ordered list of (toolName, args) fallback attempts for a failed approach tool.
    /// Tried in sequence without LLM involvement — stops at first success.
    static func toolSpecificFallback(
        for failedCall: ToolCall,
        prompt: String
    ) -> [(name: String, args: [String: Any])] {
        let originalArgs = (try? JSONSerialization.jsonObject(
            with: failedCall.argumentsData, options: []
        )) as? [String: Any] ?? [:]

        switch failedCall.name {

        case "build_playlist_mining_station":
            let intent = originalArgs["intent"] as? String ?? prompt
            let stopWords: Set<String> = [
                "a", "an", "the", "for", "and", "or", "to", "in", "on", "at", "of", "with", "some"
            ]
            let keywords = intent.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { $0.count > 3 && !stopWords.contains($0) }
            return keywords.map { keyword in
                (name: "build_playlist_mining_station",
                 args: ["intent": keyword, "track_count": 50])
            }

        case "build_artist_graph_station":
            let artist = originalArgs["seed_artist"] as? String ?? prompt
            return [(
                name: "build_playlist_mining_station",
                args: ["intent": "music like \(artist)", "track_count": 50]
            )]

        case "build_song_seeded_station":
            let songTitle = originalArgs["song_title"] as? String ?? prompt
            let artistName = originalArgs["artist_name"] as? String
            var fallbacks: [(name: String, args: [String: Any])] = []
            if let artist = artistName {
                fallbacks.append((
                    name: "build_artist_graph_station",
                    args: ["seed_artist": artist, "temperature": 0.5, "track_count": 50]
                ))
            }
            let miningIntent = [songTitle, artistName].compactMap { $0 }.joined(separator: " ")
            fallbacks.append((
                name: "build_playlist_mining_station",
                args: ["intent": miningIntent, "track_count": 50]
            ))
            return fallbacks

        case "build_genre_chart_station":
            let genre = originalArgs["genre"] as? String ?? prompt
            let decade = originalArgs["decade"] as? Int
            var fallbacks: [(name: String, args: [String: Any])] = []
            if decade != nil {
                fallbacks.append((
                    name: "build_genre_chart_station",
                    args: ["genre": genre, "track_count": 50]
                ))
            }
            fallbacks.append((
                name: "build_playlist_mining_station",
                args: ["intent": "\(genre) music", "track_count": 50]
            ))
            return fallbacks

        default:
            return []
        }
    }

    /// Count tracks in a raw tool result JSON string (before compression).
    static func trackCount(from content: String) -> Int {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]] else { return 0 }
        return tracks.count
    }

    /// Check whether a tool result JSON actually contains a non-empty tracks array.
    static func toolResultHasTracks(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]] else {
            return false
        }
        return !tracks.isEmpty
    }

    // MARK: - Tool Result Compression

    /// Strip heavy fields from approach tool JSON before re-injecting into the conversation.
    static func compressToolResult(_ content: String, toolName: String) -> String {
        guard toolName.hasPrefix("build_") else { return content }

        guard let data = content.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              var json = raw as? [String: Any] else {
            return content
        }

        if let tracks = json["tracks"] as? [[String: Any]] {
            let trimmed: [[String: Any]] = tracks.compactMap { track in
                guard let id = track["id"] as? String, !id.isEmpty else { return nil }
                var compact: [String: Any] = ["id": id]
                if let title = track["title"] as? String { compact["title"] = title }
                if let artist = track["artist_name"] as? String { compact["artist_name"] = artist }
                return compact
            }
            json["tracks"] = trimmed
        }

        for key in ["total_candidates", "playlists_searched", "playlists_mined",
                    "artists_explored", "seed_genres"] {
            json.removeValue(forKey: key)
        }

        guard let out = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: out, encoding: .utf8) else {
            return content
        }
        return str
    }

    // MARK: - Direct Result Builder

    /// Build a StationBuildResult directly from approach tool outputs,
    /// bypassing the LLM formatting turn. Merges multiple results for
    /// parallel tool calls, deduplicates by ID.
    private func buildResultFromToolOutputs(
        _ results: [(toolName: String, content: String)],
        turnsUsed: Int
    ) throws -> StationBuildResult {
        var allTracks: [SelectedTrack] = []
        var seenIds: Set<String> = []

        for (_, content) in results {
            guard let data = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [[String: Any]] else { continue }

            for track in tracks {
                guard let id = track["id"] as? String, !id.isEmpty,
                      seenIds.insert(id).inserted else { continue }
                allTracks.append(SelectedTrack(
                    id: id,
                    title: track["title"] as? String,
                    artistName: track["artist_name"] as? String,
                    reason: nil
                ))
            }
        }

        guard !allTracks.isEmpty else {
            throw ToolError.executionFailed("buildResultFromToolOutputs: no tracks in results")
        }

        let approachUsed = results.count == 1
            ? Self.toolNameToApproach(results[0].toolName)
            : "hybrid"
        let toolNames = results.map(\.toolName).joined(separator: " + ")
        print("🎯 Direct result: \(allTracks.count) tracks from \(toolNames)")

        return StationBuildResult(
            tracks: allTracks,
            approachUsed: approachUsed,
            reasoning: "Tracks sourced directly from \(toolNames)",
            turnsUsed: turnsUsed
        )
    }

    /// Maps approach tool name to the approach_used string in StationBuildResult.
    static func toolNameToApproach(_ toolName: String) -> String {
        switch toolName {
        case "build_artist_graph_station":    return "artist_graph"
        case "build_playlist_mining_station": return "playlist_mining"
        case "build_song_seeded_station":     return "song_seeded"
        case "build_personalized_station":    return "personalized"
        case "build_genre_chart_station":     return "genre_chart"
        default:                              return "unknown"
        }
    }

    // MARK: - LLM Knowledge Fallback

    /// Last resort when all approach tools and their fallbacks returned 0 tracks.
    /// Asks the LLM to generate 25 songs from training knowledge, resolves via MusicKit.
    private func llmKnowledgeFallback(
        prompt: String,
        turnsUsed: Int
    ) async throws -> StationBuildResult {
        onProgress?("Searching AI knowledge...")
        print("🎯 LLM knowledge fallback for: \(prompt)")

        let generationMessages: [ToolCallingMessage] = [
            .system("""
                You are a music expert. Suggest 25 real songs that best match the request.
                Return ONLY a JSON array, no markdown:
                [{"title": "Song Title", "artist": "Artist Name"}, ...]
                """),
            .user(prompt)
        ]

        let response = try await callLLMProxy(messages: generationMessages, tools: [])
        guard let content = response.content else {
            throw ToolError.executionFailed("LLM knowledge fallback returned empty response")
        }

        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        else if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8),
              let suggestions = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else {
            throw ToolError.executionFailed("Could not parse LLM knowledge suggestions as JSON")
        }

        var resolvedTracks: [SelectedTrack] = []
        for (index, suggestion) in suggestions.enumerated() {
            guard let title = suggestion["title"], let artist = suggestion["artist"] else { continue }

            if index > 0 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
            request.limit = 5

            guard let searchResponse = try? await request.response() else { continue }

            let match = searchResponse.songs.first(where: {
                $0.title.localizedCaseInsensitiveContains(title) &&
                $0.artistName.localizedCaseInsensitiveContains(artist)
            }) ?? searchResponse.songs.first

            guard let song = match else { continue }

            resolvedTracks.append(SelectedTrack(
                id: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                reason: "Matched from AI music knowledge"
            ))
        }

        print("🎯 LLM knowledge fallback: \(resolvedTracks.count)/\(suggestions.count) resolved")

        guard resolvedTracks.count >= 10 else {
            throw ToolError.executionFailed(
                "Knowledge fallback: only \(resolvedTracks.count) tracks resolved for '\(prompt)'"
            )
        }

        return StationBuildResult(
            tracks: resolvedTracks,
            approachUsed: "llm_knowledge",
            reasoning: "AI-generated recommendations resolved via Apple Music catalog",
            turnsUsed: turnsUsed
        )
    }

    // MARK: - Parse Final Response

    private func parseFinalResponse(content: String, turnsUsed: Int) throws -> StationBuildResult {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw ToolError.executionFailed("Could not parse LLM final response as UTF-8")
        }

        let parsed = try JSONDecoder().decode(FinalSelectionResponse.self, from: data)

        return StationBuildResult(
            tracks: parsed.tracks,
            approachUsed: parsed.approachUsed ?? "unknown",
            reasoning: parsed.reasoning ?? "",
            turnsUsed: turnsUsed
        )
    }
}

// MARK: - Request/Response Types for Edge Function

struct ToolCallingProxyRequest: Encodable {
    let messages: [ToolCallingMessage]
    let tools: [ToolDefinition]
}

private struct FinalSelectionResponse: Decodable {
    let tracks: [SelectedTrack]
    let approachUsed: String?
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case tracks
        case approachUsed = "approach_used"
        case reasoning
    }
}
