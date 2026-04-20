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

// MARK: - Orchestrator Configuration

struct OrchestratorConfig {
    /// Maximum tool-call turns before forcing completion
    var maxTurns: Int = 10

    /// System prompt describing the LLM's role
    var systemPrompt: String = Self.defaultSystemPrompt

    static let defaultSystemPrompt = """
        You are a music curation AI. You have access to Apple Music tools to search for music, \
        explore artists, browse playlists, and build stations.

        Your job: given a user's prompt describing what kind of music they want, use the tools \
        to find and select tracks that match. Think carefully about the user's intent — mood, \
        genre, era, energy level — and use the appropriate strategy.

        APPROACH TOOLS (HIGH-LEVEL — use when the intent clearly matches):
        - build_artist_graph_station: For "station like [Artist]" requests. Traverses the artist \
          similarity graph. Use temperature to control exploration depth.
        - build_playlist_mining_station: For mood/vibe/activity prompts like "sad indie for a rainy day". \
          Mines Apple editorial playlists for high-quality mood-matched tracks.
        - build_song_seeded_station: For "more like this song" requests. Seeds from a specific song \
          and expands via artist and genre similarity.
        - build_personalized_station: For low-context requests like "play me something good". \
          Uses the user's Apple Music listening history and recommendations.
        - build_genre_chart_station: For genre/decade requests like "90s alternative" or "top jazz". \
          Combines chart data with genre-filtered editorial playlists.

        LOW-LEVEL TOOLS (use for custom strategies or to refine approach tool results):
        - search_catalog: Search songs, artists, albums, playlists by name or keyword.
        - get_artist_top_songs: Get an artist's most popular tracks.
        - get_similar_artists: Find similar artists (graph traversal edge).
        - get_playlist_tracks: Get all tracks from a playlist.
        - get_recommendations: User's personalized Apple Music recommendations.
        - get_heavy_rotation: User's most-played recent items.
        - get_recently_played: What the user just listened to.
        - get_genre_charts: Top songs/albums in a genre.
        - get_related_albums: Albums similar to a given album.
        - get_song_radio_seed: Apple's radio station seeded from a song.

        CUSTOM LOGIC TOOLS:
        - generate_search_queries: Expand an intent into multiple search queries.
        - score_track_fit: Score tracks against an intent description.
        - rank_candidates: Rank tracks by popularity, diversity, and genre balance.
        - filter_recently_played: Remove tracks the user already heard.
        - enforce_diversity: Limit per-artist and per-genre concentration.
        - summarize_feedback: Get the user's like/dislike/skip history summary.
        - get_user_preferences: Get stored genre preferences and exploration level.

        STRATEGY:
        1. Start by identifying the user's intent type (artist, mood, song, genre, or general).
        2. If it clearly matches an approach tool, call it directly — this is fastest.
        3. If the intent is complex or hybrid, compose low-level tools for a custom strategy.
        4. You can also use an approach tool first, then refine with low-level tools.
        5. Always aim for 15-25 tracks in your final selection.

        FINAL RESPONSE:
        When you have enough candidates, return your final selection as a JSON object:
        {
          "tracks": [
            {"id": "apple_music_id", "title": "...", "artist_name": "...", "reason": "why this track fits"}
          ],
          "approach_used": "artist_graph | playlist_mining | song_seeded | personalized | genre_chart | hybrid",
          "reasoning": "Brief explanation of your curation strategy"
        }

        Return ONLY the JSON object as your final response, no markdown or extra text.
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

        // Initialize conversation
        var messages: [ToolCallingMessage] = [
            .system(systemPrompt),
            .user(prompt)
        ]

        var turnsUsed = 0

        // Tool-call loop
        while turnsUsed < config.maxTurns {
            turnsUsed += 1

            // Call LLM via edge function
            let llmResponse = try await callLLMProxy(
                messages: messages,
                tools: registry.definitions
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

                // Add tool result to conversation
                messages.append(.toolResult(id: call.id, content: result.contentString))
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

    // MARK: - Parse Final Response

    private func parseFinalResponse(content: String, turnsUsed: Int) throws -> StationBuildResult {
        // Clean markdown code blocks if present
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
