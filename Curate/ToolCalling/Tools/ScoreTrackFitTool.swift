//
//  ScoreTrackFitTool.swift
//  Curate
//
//  Scores how well a set of tracks fit a given intent.
//  Rule-based on genre, title keywords, and metadata matching.
//

import Foundation

final class ScoreTrackFitTool: MusicTool {
    let name = "score_track_fit"
    let description = """
        Score how well a list of tracks fit a given intent/mood description. \
        Returns each track with a 0-1 fit score based on genre match, \
        title keyword overlap, and artist relevance. \
        Use this to filter a large candidate pool down to the best matches.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "intent": .string("The target mood/vibe description (e.g., 'sad acoustic indie')"),
            "target_genres": .stringArray("Target genres the tracks should match"),
            "tracks": .stringArray("JSON array of track objects with: id, title, artist_name, genres (array)")
        ],
        required: ["intent", "tracks"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        guard let json = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let tracksArray = json["tracks"] as? [[String: Any]],
              let intent = json["intent"] as? String else {
            throw ToolError.invalidArguments("Required: intent (string), tracks (array of objects)")
        }

        let targetGenres = (json["target_genres"] as? [String]) ?? []
        let intentWords = Set(intent.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let targetGenresLower = Set(targetGenres.map { $0.lowercased() })

        var scored: [ScoredTrack] = []

        for track in tracksArray {
            guard let id = track["id"] as? String else { continue }
            let title = (track["title"] as? String) ?? ""
            let artistName = (track["artist_name"] as? String) ?? ""
            let genres = (track["genres"] as? [String]) ?? []

            var score: Double = 0.0
            var reasons: [String] = []

            // Genre match (0-0.4)
            if !targetGenresLower.isEmpty {
                let trackGenresLower = Set(genres.map { $0.lowercased() })
                let genreOverlap = targetGenresLower.intersection(trackGenresLower)
                if !genreOverlap.isEmpty {
                    let genreScore = min(Double(genreOverlap.count) / Double(targetGenresLower.count), 1.0) * 0.4
                    score += genreScore
                    reasons.append("genre_match")
                }
            } else {
                // No target genres specified — give partial credit
                score += 0.2
            }

            // Title keyword overlap (0-0.3)
            let titleWords = Set(title.lowercased().components(separatedBy: .whitespaces))
            let titleOverlap = intentWords.intersection(titleWords)
            if !titleOverlap.isEmpty {
                let titleScore = min(Double(titleOverlap.count) / Double(intentWords.count), 1.0) * 0.3
                score += titleScore
                reasons.append("title_keyword")
            }

            // Artist name in intent (0-0.2)
            if intentWords.contains(where: { artistName.lowercased().contains($0) }) {
                score += 0.2
                reasons.append("artist_match")
            }

            // Base score for existing in candidate pool (0.1)
            score += 0.1

            scored.append(ScoredTrack(
                id: id,
                title: title,
                artistName: artistName,
                genres: genres,
                score: min(score, 1.0),
                matchReasons: reasons
            ))
        }

        // Sort by score descending
        scored.sort { $0.score > $1.score }

        return .encode(ScoreTrackFitResult(
            intent: intent,
            scoredTracks: scored,
            averageScore: scored.isEmpty ? 0 : scored.map(\.score).reduce(0, +) / Double(scored.count)
        ))
    }
}

struct ScoredTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let genres: [String]
    let score: Double
    let matchReasons: [String]
}

struct ScoreTrackFitResult: Codable {
    let intent: String
    let scoredTracks: [ScoredTrack]
    let averageScore: Double
}
