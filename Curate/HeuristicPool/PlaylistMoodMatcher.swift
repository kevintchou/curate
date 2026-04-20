//
//  PlaylistMoodMatcher.swift
//  Curate
//
//  Scores playlists against a parsed vibe by analyzing
//  playlist titles and descriptions for mood/genre relevance.
//

import Foundation

// MARK: - Protocol

protocol PlaylistMoodMatcherProtocol {
    /// Score a single playlist against a parsed vibe
    func score(
        playlist: ProviderPlaylist,
        against vibe: ParsedVibe,
        genres: [String]
    ) -> ScoredPlaylist

    /// Rank multiple playlists by relevance to a vibe
    func rankPlaylists(
        _ playlists: [ProviderPlaylist],
        against vibe: ParsedVibe,
        genres: [String]
    ) -> [ScoredPlaylist]
}

// MARK: - Implementation

final class PlaylistMoodMatcher: PlaylistMoodMatcherProtocol {

    // MARK: - Dependencies

    private let moodKeywords: MoodKeywordMappings
    private let genreSynonyms: GenreSynonymMappings

    // MARK: - Configuration

    /// Weight for mood keyword matching
    private let moodWeight: Float = 0.45

    /// Weight for genre matching
    private let genreWeight: Float = 0.35

    /// Bonus for editorial playlists
    private let editorialBonus: Float = 0.15

    /// Bonus for activity match
    private let activityBonus: Float = 0.05

    // MARK: - Initialization

    init(
        moodKeywords: MoodKeywordMappings? = nil,
        genreSynonyms: GenreSynonymMappings? = nil
    ) {
        self.moodKeywords = moodKeywords ?? MoodKeywordMappings.loadFromBundle()
        self.genreSynonyms = genreSynonyms ?? GenreSynonymMappings.loadFromBundle()
    }

    // MARK: - Scoring

    func score(
        playlist: ProviderPlaylist,
        against vibe: ParsedVibe,
        genres: [String]
    ) -> ScoredPlaylist {
        // Combine title and description for searching
        let searchableText = buildSearchableText(from: playlist)

        // 1. Calculate mood score
        let moodScore = calculateMoodScore(
            text: searchableText,
            moods: vibe.moods
        )

        // 2. Calculate genre score
        let genreScore = calculateGenreScore(
            text: searchableText,
            genres: genres
        )

        // 3. Editorial bonus
        let editorial: Float = playlist.isEditorial ? editorialBonus : 0.0

        // 4. Activity bonus
        let activityScore = calculateActivityBonus(
            text: searchableText,
            activity: vibe.activity
        )

        // 5. Calculate total score
        let totalScore = min(1.0,
            (moodWeight * moodScore) +
            (genreWeight * genreScore) +
            editorial +
            activityScore
        )

        return ScoredPlaylist(
            playlist: playlist,
            moodScore: moodScore,
            genreScore: genreScore,
            editorialBonus: editorial,
            totalScore: totalScore
        )
    }

    func rankPlaylists(
        _ playlists: [ProviderPlaylist],
        against vibe: ParsedVibe,
        genres: [String]
    ) -> [ScoredPlaylist] {
        playlists
            .map { score(playlist: $0, against: vibe, genres: genres) }
            .sorted { $0.totalScore > $1.totalScore }
    }

    // MARK: - Score Components

    /// Build searchable text from playlist metadata
    private func buildSearchableText(from playlist: ProviderPlaylist) -> String {
        var components: [String] = [playlist.name.lowercased()]

        if let description = playlist.description {
            components.append(description.lowercased())
        }

        if let curator = playlist.curatorName {
            components.append(curator.lowercased())
        }

        return components.joined(separator: " ")
    }

    /// Calculate mood score based on keyword matches
    private func calculateMoodScore(text: String, moods: [MoodCategory]) -> Float {
        guard !moods.isEmpty else { return 0.3 }  // Neutral score if no moods

        var totalMatches = 0
        var totalKeywords = 0

        for mood in moods {
            let keywords = moodKeywords.keywords(for: mood)
            totalKeywords += keywords.count

            for keyword in keywords {
                if text.contains(keyword.lowercased()) {
                    totalMatches += 1
                }
            }
        }

        guard totalKeywords > 0 else { return 0.3 }

        // Calculate base score
        let baseScore = Float(totalMatches) / Float(min(totalKeywords, 10))

        // Apply sigmoid-like scaling to avoid extremes
        let scaled = smoothScore(baseScore)

        return scaled
    }

    /// Calculate genre score based on genre/synonym matches
    private func calculateGenreScore(text: String, genres: [String]) -> Float {
        guard !genres.isEmpty else { return 0.5 }  // Neutral if no genre preference

        var matchCount = 0

        for genre in genres {
            if genreSynonyms.containsGenre(genre, in: text) {
                matchCount += 1
            }
        }

        let baseScore = Float(matchCount) / Float(genres.count)
        return smoothScore(baseScore)
    }

    /// Calculate activity bonus if activity matches
    private func calculateActivityBonus(text: String, activity: ActivityContext?) -> Float {
        guard let activity = activity else { return 0.0 }

        let activityKeywords = ActivityKeywords.mappings[activity] ?? []

        for keyword in activityKeywords {
            if text.contains(keyword.lowercased()) {
                return activityBonus
            }
        }

        return 0.0
    }

    /// Smooth a raw score to avoid extreme values
    private func smoothScore(_ raw: Float) -> Float {
        // Apply a mild sigmoid to keep scores in a reasonable range
        // This prevents a single strong match from dominating
        let clamped = max(0, min(1, raw))

        // Boost low scores slightly, cap high scores
        if clamped < 0.3 {
            return clamped + 0.1
        } else if clamped > 0.8 {
            return 0.8 + (clamped - 0.8) * 0.5
        }

        return clamped
    }
}

// MARK: - Mock Implementation for Testing

final class MockPlaylistMoodMatcher: PlaylistMoodMatcherProtocol {
    var mockScores: [String: ScoredPlaylist] = [:]
    var scoreCallCount = 0

    func score(
        playlist: ProviderPlaylist,
        against vibe: ParsedVibe,
        genres: [String]
    ) -> ScoredPlaylist {
        scoreCallCount += 1

        if let mock = mockScores[playlist.id] {
            return mock
        }

        return ScoredPlaylist(
            playlist: playlist,
            moodScore: 0.5,
            genreScore: 0.5,
            editorialBonus: playlist.isEditorial ? 0.15 : 0.0,
            totalScore: 0.6
        )
    }

    func rankPlaylists(
        _ playlists: [ProviderPlaylist],
        against vibe: ParsedVibe,
        genres: [String]
    ) -> [ScoredPlaylist] {
        playlists
            .map { score(playlist: $0, against: vibe, genres: genres) }
            .sorted { $0.totalScore > $1.totalScore }
    }
}
