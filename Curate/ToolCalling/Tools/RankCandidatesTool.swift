//
//  RankCandidatesTool.swift
//  Curate
//
//  Ranks candidate tracks by configurable criteria: popularity, source diversity,
//  genre balance, and recency. Returns a sorted list the LLM can select from.
//

import Foundation

final class RankCandidatesTool: MusicTool {
    let name = "rank_candidates"
    let description = """
        Rank a list of candidate tracks by weighted criteria. \
        Supports ranking by popularity (based on position in source), \
        source diversity (tracks from different playlists/artists ranked higher), \
        and genre balance. Returns a sorted list with rank scores. \
        Use this to get a pre-sorted list before making your final selection.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "tracks": .stringArray("JSON array of track objects with: id, title, artist_name, genres, source (string)"),
            "popularity_weight": .number("Weight for popularity/position ranking (default 0.3)"),
            "diversity_weight": .number("Weight for source diversity (default 0.4)"),
            "genre_balance_weight": .number("Weight for genre balance (default 0.3)"),
            "limit": .integer("Return only top N ranked tracks (default: all)")
        ],
        required: ["tracks"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        guard let json = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let tracksArray = json["tracks"] as? [[String: Any]] else {
            throw ToolError.invalidArguments("Required: tracks (array of objects)")
        }

        let popularityWeight = (json["popularity_weight"] as? Double) ?? 0.3
        let diversityWeight = (json["diversity_weight"] as? Double) ?? 0.4
        let genreBalanceWeight = (json["genre_balance_weight"] as? Double) ?? 0.3
        let limit = (json["limit"] as? Int) ?? tracksArray.count

        let candidates = tracksArray.enumerated().compactMap { index, dict -> RankCandidate? in
            guard let id = dict["id"] as? String else { return nil }
            return RankCandidate(
                id: id,
                title: (dict["title"] as? String) ?? "",
                artistName: (dict["artist_name"] as? String) ?? "",
                genres: (dict["genres"] as? [String]) ?? [],
                source: (dict["source"] as? String) ?? "unknown",
                originalPosition: index
            )
        }

        guard !candidates.isEmpty else {
            return .encode(RankResult(rankedTracks: [], totalCandidates: 0))
        }

        // Score each candidate
        var sourceCounts: [String: Int] = [:]
        var genreCounts: [String: Int] = [:]
        let totalCount = Double(candidates.count)

        var scored: [(RankCandidate, Double)] = []

        for candidate in candidates {
            // Popularity: higher position = lower score (inverted)
            let positionScore = 1.0 - (Double(candidate.originalPosition) / totalCount)

            // Source diversity: penalize over-represented sources
            let sourceCount = Double(sourceCounts[candidate.source, default: 0])
            let diversityScore = 1.0 / (1.0 + sourceCount)
            sourceCounts[candidate.source, default: 0] += 1

            // Genre balance: penalize over-represented genres
            let genreScores = candidate.genres.map { genre -> Double in
                let count = Double(genreCounts[genre.lowercased(), default: 0])
                return 1.0 / (1.0 + count)
            }
            let genreScore = genreScores.isEmpty ? 0.5 : genreScores.reduce(0, +) / Double(genreScores.count)
            for genre in candidate.genres {
                genreCounts[genre.lowercased(), default: 0] += 1
            }

            let finalScore = (positionScore * popularityWeight) +
                             (diversityScore * diversityWeight) +
                             (genreScore * genreBalanceWeight)

            scored.append((candidate, finalScore))
        }

        // Sort by score descending
        scored.sort { $0.1 > $1.1 }

        let rankedTracks = scored.prefix(limit).map { candidate, score in
            RankedTrack(
                id: candidate.id,
                title: candidate.title,
                artistName: candidate.artistName,
                genres: candidate.genres,
                source: candidate.source,
                rankScore: score
            )
        }

        return .encode(RankResult(
            rankedTracks: Array(rankedTracks),
            totalCandidates: candidates.count
        ))
    }
}

private struct RankCandidate {
    let id: String
    let title: String
    let artistName: String
    let genres: [String]
    let source: String
    let originalPosition: Int
}

struct RankedTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let genres: [String]
    let source: String
    let rankScore: Double
}

struct RankResult: Codable {
    let rankedTracks: [RankedTrack]
    let totalCandidates: Int
}
