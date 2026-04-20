//
//  GenerateSearchQueriesTool.swift
//  Curate
//
//  Expands a natural language intent into multiple search queries optimized
//  for MusicKit catalog search. Rule-based template expansion.
//

import Foundation

final class GenerateSearchQueriesTool: MusicTool {
    let name = "generate_search_queries"
    let description = """
        Expand a natural language music intent into multiple optimized search queries. \
        Takes a vibe/mood description and returns 5-10 search strings designed to \
        find relevant playlists and songs in Apple Music. Use these queries with \
        search_catalog for broader coverage than a single search.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "intent": .string("Natural language description of the desired music (e.g., 'sad rainy day acoustic')"),
            "genres": .stringArray("Optional genre hints to incorporate into queries"),
            "max_queries": .integer("Maximum number of queries to generate (default 8)")
        ],
        required: ["intent"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let intent = try args.requireString("intent")
        let genres = args.stringArray("genres")
        let maxQueries = args.optionalInt("max_queries", default: 8)

        let queries = generateQueries(intent: intent, genres: genres, limit: maxQueries)

        return .encode(SearchQueriesResult(
            intent: intent,
            queries: queries
        ))
    }

    private func generateQueries(intent: String, genres: [String], limit: Int) -> [GeneratedQuery] {
        var queries: [GeneratedQuery] = []
        let words = intent.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // 1. Raw intent as-is
        queries.append(GeneratedQuery(query: intent, strategy: "raw_intent"))

        // 2. Intent + "playlist" suffix for editorial matching
        queries.append(GeneratedQuery(query: "\(intent) playlist", strategy: "playlist_suffix"))

        // 3. Genre + intent combinations
        for genre in genres.prefix(2) {
            queries.append(GeneratedQuery(query: "\(genre) \(intent)", strategy: "genre_intent"))
        }

        // 4. Extract mood keywords and search for them directly
        let moodKeywords = extractMoodKeywords(from: words)
        for mood in moodKeywords.prefix(2) {
            queries.append(GeneratedQuery(query: "\(mood) music", strategy: "mood_keyword"))
            if let genre = genres.first {
                queries.append(GeneratedQuery(query: "\(mood) \(genre)", strategy: "mood_genre"))
            }
        }

        // 5. Activity extraction
        let activityKeywords = extractActivityKeywords(from: words)
        for activity in activityKeywords.prefix(1) {
            queries.append(GeneratedQuery(query: "\(activity) music", strategy: "activity"))
        }

        // 6. Time-of-day extraction
        let timeKeywords = extractTimeKeywords(from: words)
        for time in timeKeywords.prefix(1) {
            if let mood = moodKeywords.first {
                queries.append(GeneratedQuery(query: "\(time) \(mood)", strategy: "time_mood"))
            } else {
                queries.append(GeneratedQuery(query: "\(time) vibes", strategy: "time_vibes"))
            }
        }

        // Deduplicate by query text
        var seen: Set<String> = []
        queries = queries.filter { q in
            let key = q.query.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        return Array(queries.prefix(limit))
    }

    // MARK: - Keyword Extraction

    private let moodWords: Set<String> = [
        "sad", "happy", "chill", "relaxing", "upbeat", "melancholy", "dark",
        "bright", "dreamy", "aggressive", "peaceful", "intense", "mellow",
        "energetic", "calm", "angry", "romantic", "nostalgic", "euphoric",
        "moody", "somber", "joyful", "bittersweet", "ethereal", "groovy",
        "funky", "soulful", "ambient", "lo-fi", "lofi"
    ]

    private let activityWords: Set<String> = [
        "workout", "running", "driving", "studying", "cooking", "sleeping",
        "working", "coding", "reading", "meditation", "yoga", "party",
        "dancing", "walking", "hiking", "commuting", "cleaning", "gaming",
        "focus", "concentration"
    ]

    private let timeWords: Set<String> = [
        "morning", "afternoon", "evening", "night", "late-night", "latenight",
        "midnight", "sunrise", "sunset", "dawn", "dusk"
    ]

    private func extractMoodKeywords(from words: [String]) -> [String] {
        words.filter { moodWords.contains($0) }
    }

    private func extractActivityKeywords(from words: [String]) -> [String] {
        words.filter { activityWords.contains($0) }
    }

    private func extractTimeKeywords(from words: [String]) -> [String] {
        words.filter { timeWords.contains($0) }
    }
}

struct GeneratedQuery: Codable {
    let query: String
    let strategy: String
}

struct SearchQueriesResult: Codable {
    let intent: String
    let queries: [GeneratedQuery]
}
