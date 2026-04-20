//
//  SearchExpander.swift
//  Curate
//
//  Expands a ParsedVibe + user genre preferences into search queries
//  for playlist discovery. Handles genre injection strategy.
//

import Foundation

// MARK: - Protocol

protocol SearchExpanderProtocol {
    /// Expand a parsed vibe and genre preferences into search queries
    func expand(vibe: ParsedVibe, genres: [String]) -> [HeuristicSearchQuery]
}

// MARK: - Implementation

final class SearchExpander: SearchExpanderProtocol {

    // MARK: - Configuration

    /// Ratio of queries that should include genre (when genres are specified)
    private let genreInjectionRatio: Float = 0.7

    /// Maximum number of search queries to generate
    private let maxQueries: Int = 10

    /// Maximum genres to use in queries
    private let maxGenresPerExpansion: Int = 2

    // MARK: - Expand

    func expand(vibe: ParsedVibe, genres: [String]) -> [HeuristicSearchQuery] {
        var queries: [HeuristicSearchQuery] = []
        var priority = 1

        let hasGenres = !genres.isEmpty
        let topGenres = Array(genres.prefix(maxGenresPerExpansion))

        // RULE 1: Genre + raw input (highest priority when genre specified)
        if hasGenres {
            for genre in topGenres {
                queries.append(HeuristicSearchQuery(
                    term: "\(genre.lowercased()) \(vibe.rawInput)",
                    priority: priority,
                    hasGenre: true,
                    sourceRule: "genre_raw"
                ))
                priority += 1
            }
        }

        // RULE 2: Genre + primary mood
        if hasGenres, let primaryMood = vibe.moods.first {
            for genre in topGenres {
                queries.append(HeuristicSearchQuery(
                    term: "\(genre.lowercased()) \(primaryMood.searchTerm)",
                    priority: priority,
                    hasGenre: true,
                    sourceRule: "genre_mood"
                ))
                priority += 1
            }
        }

        // RULE 3: Genre + activity (if activity present)
        if hasGenres, let activity = vibe.activity {
            queries.append(HeuristicSearchQuery(
                term: "\(topGenres[0].lowercased()) \(activity.searchTerm) music",
                priority: priority,
                hasGenre: true,
                sourceRule: "genre_activity"
            ))
            priority += 1
        }

        // RULE 4: Genre + activity + mood combination
        if hasGenres, let activity = vibe.activity, let mood = vibe.moods.first {
            queries.append(HeuristicSearchQuery(
                term: "\(topGenres[0].lowercased()) \(activity.searchTerm) \(mood.searchTerm)",
                priority: priority,
                hasGenre: true,
                sourceRule: "genre_activity_mood"
            ))
            priority += 1
        }

        // RULE 5: Genre + "vibes" / "playlist" patterns
        if hasGenres {
            queries.append(HeuristicSearchQuery(
                term: "\(topGenres[0].lowercased()) vibes",
                priority: priority,
                hasGenre: true,
                sourceRule: "genre_vibes"
            ))
            priority += 1
        }

        // RULE 6: Genre-free mood queries (for cross-genre discovery)
        for mood in vibe.moods.prefix(2) {
            if let time = vibe.timeContext {
                queries.append(HeuristicSearchQuery(
                    term: "\(time.searchTerm) \(mood.searchTerm) music",
                    priority: priority,
                    hasGenre: false,
                    sourceRule: "time_mood"
                ))
            } else {
                queries.append(HeuristicSearchQuery(
                    term: "\(mood.searchTerm) playlist",
                    priority: priority,
                    hasGenre: false,
                    sourceRule: "mood_playlist"
                ))
            }
            priority += 1
        }

        // RULE 7: Activity-only query (genre-free)
        if let activity = vibe.activity {
            queries.append(HeuristicSearchQuery(
                term: "\(activity.searchTerm) music playlist",
                priority: priority,
                hasGenre: false,
                sourceRule: "activity_only"
            ))
            priority += 1
        }

        // RULE 8: Time context + vibes (genre-free)
        if let time = vibe.timeContext {
            queries.append(HeuristicSearchQuery(
                term: "\(time.searchTerm) vibes",
                priority: priority,
                hasGenre: false,
                sourceRule: "time_vibes"
            ))
            priority += 1
        }

        // RULE 9: Raw input as-is (fallback)
        if vibe.rawInput.count >= 3 {
            queries.append(HeuristicSearchQuery(
                term: vibe.rawInput,
                priority: priority,
                hasGenre: false,
                sourceRule: "raw_fallback"
            ))
            priority += 1
        }

        // Deduplicate and cap
        let deduped = deduplicateQueries(queries)
        let capped = Array(deduped.prefix(maxQueries))

        print("🔍 SearchExpander: Generated \(capped.count) queries from vibe")
        for query in capped {
            print("   [\(query.priority)] \(query.term) (\(query.sourceRule))")
        }

        return capped
    }

    // MARK: - Helpers

    /// Remove duplicate search terms while preserving priority order
    private func deduplicateQueries(_ queries: [HeuristicSearchQuery]) -> [HeuristicSearchQuery] {
        var seen = Set<String>()
        var result: [HeuristicSearchQuery] = []

        for query in queries {
            let normalized = query.term.lowercased().trimmingCharacters(in: .whitespaces)
            if !seen.contains(normalized) {
                seen.insert(normalized)
                result.append(query)
            }
        }

        return result
    }
}

// MARK: - Mock Implementation for Testing

final class MockSearchExpander: SearchExpanderProtocol {
    var mockQueries: [HeuristicSearchQuery]?
    var expandCallCount = 0
    var lastVibe: ParsedVibe?
    var lastGenres: [String]?

    func expand(vibe: ParsedVibe, genres: [String]) -> [HeuristicSearchQuery] {
        expandCallCount += 1
        lastVibe = vibe
        lastGenres = genres

        if let mock = mockQueries {
            return mock
        }

        // Return default mock queries
        return [
            HeuristicSearchQuery(term: "mock query 1", priority: 1, hasGenre: true, sourceRule: "mock"),
            HeuristicSearchQuery(term: "mock query 2", priority: 2, hasGenre: false, sourceRule: "mock")
        ]
    }
}
