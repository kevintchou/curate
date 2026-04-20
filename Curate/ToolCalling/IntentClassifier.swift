//
//  IntentClassifier.swift
//  Curate
//
//  Deterministic intent classification for user prompts.
//  Maps natural language input to one of the 5 approach tools without requiring
//  an LLM call. Used primarily by LocalToolCallingBackend where the on-device
//  model is unreliable at tool selection.
//
//  Strategy:
//  1. Strong keyword/regex patterns identify high-confidence intents
//  2. Falls back to .mood (playlist mining) as the safest default —
//     Apple's editorial playlists are human-curated, so mining them produces
//     good results for any descriptive prompt.
//

import Foundation

// MARK: - Intent Category

/// The classified intent of a user prompt, with extracted parameters
/// ready to be passed as tool arguments.
enum IntentCategory: Equatable {
    case artist(name: String)
    case mood(intent: String, genreHints: [String])
    case song(title: String, artist: String?)
    case genre(name: String, decade: Int?)
    case personalized(moodHint: String?)
}

// MARK: - Classifier

struct IntentClassifier {

    /// Classify a user prompt. Always returns a category —
    /// `.mood` is the safe default for anything that doesn't match stronger patterns.
    static func classify(prompt: String, config: LLMStationConfig? = nil) -> IntentCategory {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        // 1. Very short / vague prompts → personalized
        //    "play me something", "surprise me", "anything", "random"
        if let personalized = matchPersonalized(lowercased) {
            return personalized
        }

        // 2. "like [Artist]" / "sounds like [Artist]" → artist graph
        if let artistName = extractArtist(from: trimmed) {
            return .artist(name: artistName)
        }

        // 3. "songs like [Song]" or "more like [Song]" → song-seeded
        //    (Must come after artist check since "like" is shared)
        if let song = extractSong(from: trimmed) {
            return .song(title: song.title, artist: song.artist)
        }

        // 4. Decade + optional genre → genre chart
        //    "90s alternative", "80s rock", "2000s hip-hop"
        if let decadeMatch = extractDecade(from: lowercased) {
            let genre = extractGenre(from: lowercased) ?? "popular"
            return .genre(name: genre, decade: decadeMatch)
        }

        // 5. Pure genre with chart-like qualifiers: "top jazz", "best indie rock"
        if let genre = extractExplicitGenre(from: lowercased) {
            return .genre(name: genre, decade: nil)
        }

        // 6. Safe default: mood/vibe → playlist mining
        //    The full prompt is the intent. Genre hints come from config if available.
        let genreHints = config?.suggestedGenres ?? []
        return .mood(intent: trimmed, genreHints: genreHints)
    }

    /// Convert a classified intent into a tool call (name + arguments JSON).
    static func toolCall(for intent: IntentCategory) -> (name: String, arguments: [String: Any]) {
        switch intent {
        case .artist(let name):
            return ("build_artist_graph_station", [
                "seed_artist": name,
                "temperature": 0.5,
                "track_count": 25
            ])

        case .mood(let intent, let genreHints):
            var args: [String: Any] = [
                "intent": intent,
                "track_count": 30
            ]
            if !genreHints.isEmpty {
                args["genre_hints"] = genreHints
            }
            return ("build_playlist_mining_station", args)

        case .song(let title, let artist):
            var args: [String: Any] = [
                "song_title": title,
                "track_count": 25
            ]
            if let artist = artist {
                args["artist_name"] = artist
            }
            return ("build_song_seeded_station", args)

        case .genre(let name, let decade):
            var args: [String: Any] = [
                "genre": name,
                "track_count": 25
            ]
            if let decade = decade {
                args["decade"] = decade
            }
            return ("build_genre_chart_station", args)

        case .personalized(let moodHint):
            var args: [String: Any] = ["track_count": 20]
            if let hint = moodHint {
                args["mood_hint"] = hint
            }
            return ("build_personalized_station", args)
        }
    }

    // MARK: - Pattern Extractors

    /// Very short, vague, or generic prompts → personalized.
    /// Examples: "surprise me", "play something", "anything", "random", "whatever"
    private static func matchPersonalized(_ lowercased: String) -> IntentCategory? {
        let personalizedSignals = [
            "surprise me", "play me something", "play something", "anything good",
            "anything", "random", "whatever", "pick something", "shuffle",
            "recommend", "suggest something"
        ]
        for signal in personalizedSignals {
            if lowercased.contains(signal) {
                // Extract any mood hint after the signal (e.g., "play something chill")
                let hint = lowercased
                    .replacingOccurrences(of: signal, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .personalized(moodHint: hint.isEmpty ? nil : hint)
            }
        }
        // Ultra-short prompts (≤2 words) with no other signal → personalized
        let wordCount = lowercased.split(separator: " ").count
        if wordCount <= 1 && lowercased.count < 8 {
            return .personalized(moodHint: nil)
        }
        return nil
    }

    /// Match artist patterns: "like [Artist]", "similar to [Artist]", "sounds like [Artist]".
    /// Returns the artist name or nil.
    private static func extractArtist(from prompt: String) -> String? {
        let patterns = [
            #"(?i)\b(?:station|music|songs?|tracks?)\s+(?:like|similar\s+to|by)\s+([\w\s&'.-]+?)(?:\s+but\b|\s+(?:and|or)\b|$)"#,
            #"(?i)^(?:sounds?\s+like|music\s+like|like)\s+([\w\s&'.-]+?)$"#,
            #"(?i)\b(?:more|give\s+me)\s+(?:of\s+)?([\w\s&'.-]+?)$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: prompt) {
                let candidate = prompt[range].trimmingCharacters(in: .whitespaces)
                // Filter out phrases that are clearly not artists
                if isLikelyArtistName(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Match song patterns: "songs like [Title]", "more like [Title] by [Artist]".
    private static func extractSong(from prompt: String) -> (title: String, artist: String?)? {
        // Pattern: "more like X by Y" or "songs like X by Y"
        let withArtistPattern = #"(?i)\b(?:songs?\s+like|more\s+like|similar\s+to)\s+([\w\s&'.-]+?)\s+by\s+([\w\s&'.-]+?)$"#
        if let regex = try? NSRegularExpression(pattern: withArtistPattern),
           let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
           match.numberOfRanges > 2,
           let titleRange = Range(match.range(at: 1), in: prompt),
           let artistRange = Range(match.range(at: 2), in: prompt) {
            return (String(prompt[titleRange]).trimmingCharacters(in: .whitespaces),
                    String(prompt[artistRange]).trimmingCharacters(in: .whitespaces))
        }
        // Explicit "song" keyword required to disambiguate from mood
        if prompt.lowercased().contains("song") {
            let pattern = #"(?i)\b(?:songs?\s+like|more\s+like|similar\s+to)\s+([\w\s&'.-]+?)$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: prompt) {
                return (String(prompt[range]).trimmingCharacters(in: .whitespaces), nil)
            }
        }
        return nil
    }

    /// Extract decade. "90s" → 1990, "80s" → 1980, "2000s" → 2000.
    private static func extractDecade(from lowercased: String) -> Int? {
        let patterns: [(String, Int)] = [
            (#"\b(?:19)?50s\b"#, 1950),
            (#"\b(?:19)?60s\b"#, 1960),
            (#"\b(?:19)?70s\b"#, 1970),
            (#"\b(?:19)?80s\b"#, 1980),
            (#"\b(?:19)?90s\b"#, 1990),
            (#"\b2000s\b"#, 2000),
            (#"\b2010s\b"#, 2010),
            (#"\b2020s\b"#, 2020)
        ]
        for (pattern, decade) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)) != nil {
                return decade
            }
        }
        return nil
    }

    /// Extract a known genre from the prompt.
    private static func extractGenre(from lowercased: String) -> String? {
        let genres = [
            "alternative", "indie rock", "indie pop", "indie", "rock", "pop",
            "hip-hop", "hip hop", "rap", "r&b", "soul", "funk", "disco",
            "jazz", "blues", "country", "folk", "classical", "electronic",
            "edm", "house", "techno", "ambient", "metal", "punk", "reggae",
            "latin", "k-pop", "j-pop", "singer-songwriter"
        ]
        for genre in genres {
            if lowercased.contains(genre) {
                return genre
            }
        }
        return nil
    }

    /// Genre + chart-like qualifier: "top jazz", "best alternative", "popular hip-hop".
    private static func extractExplicitGenre(from lowercased: String) -> String? {
        let chartQualifiers = ["top ", "best ", "popular ", "greatest "]
        guard chartQualifiers.contains(where: { lowercased.contains($0) }) else {
            return nil
        }
        return extractGenre(from: lowercased)
    }

    /// Filter out non-artist phrases that might match the regex
    /// (e.g. "a rainy day", "morning coffee").
    private static func isLikelyArtistName(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        // Generic descriptive phrases that shouldn't be treated as artists
        let nonArtistPhrases = [
            "morning", "evening", "night", "coffee", "rainy", "sunny",
            "day", "workout", "studying", "sleeping", "relaxing", "this",
            "that", "something", "vibes", "music"
        ]
        // If the candidate consists mostly of descriptive words, it's not an artist
        let words = lower.split(separator: " ")
        guard !words.isEmpty, words.count <= 5 else { return false }
        let descriptiveCount = words.filter { nonArtistPhrases.contains(String($0)) }.count
        return descriptiveCount == 0
    }
}
