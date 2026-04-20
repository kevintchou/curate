//
//  EnforceDiversityTool.swift
//  Curate
//
//  Enforces diversity constraints on a candidate track list.
//  Limits per-artist and per-genre concentration, ensures variety.
//

import Foundation

final class EnforceDiversityTool: MusicTool {
    let name = "enforce_diversity"
    let description = """
        Enforce diversity constraints on a list of candidate tracks. \
        Limits how many tracks can come from a single artist or genre. \
        Pass the full candidate list; returns a filtered list respecting constraints. \
        Tracks are passed as JSON objects with id, artist_name, and genre fields.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "tracks": .stringArray("JSON array of track objects, each with: id, title, artist_name, genres (array)"),
            "max_per_artist": .integer("Maximum tracks from any single artist (default 2)"),
            "max_per_genre": .integer("Maximum tracks from any single genre (default 8)"),
            "min_unique_artists": .integer("Minimum unique artists required (default 5)")
        ],
        required: ["tracks"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let maxPerArtist = args.optionalInt("max_per_artist", default: 2)
        let maxPerGenre = args.optionalInt("max_per_genre", default: 8)
        let minUniqueArtists = args.optionalInt("min_unique_artists", default: 5)

        // Decode the tracks array from raw JSON
        guard let json = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let tracksArray = json["tracks"] as? [[String: Any]] else {
            throw ToolError.invalidArguments("'tracks' must be an array of track objects")
        }

        let candidates = tracksArray.compactMap { DiversityCandidate(from: $0) }

        guard !candidates.isEmpty else {
            return .encode(DiversityResult(tracks: [], removedCount: 0, uniqueArtists: 0))
        }

        var selected: [DiversityCandidate] = []
        var artistCounts: [String: Int] = [:]
        var genreCounts: [String: Int] = [:]
        var uniqueArtists: Set<String> = []

        for candidate in candidates {
            let artistKey = candidate.artistName.lowercased()

            // Check artist limit
            if (artistCounts[artistKey] ?? 0) >= maxPerArtist {
                continue
            }

            // Check genre limit
            let genreOverLimit = candidate.genres.contains { genre in
                (genreCounts[genre.lowercased()] ?? 0) >= maxPerGenre
            }
            if genreOverLimit && !candidate.genres.isEmpty {
                continue
            }

            selected.append(candidate)
            artistCounts[artistKey, default: 0] += 1
            uniqueArtists.insert(artistKey)
            for genre in candidate.genres {
                genreCounts[genre.lowercased(), default: 0] += 1
            }
        }

        // If we don't have enough unique artists, warn but return what we have
        let meetsMinArtists = uniqueArtists.count >= minUniqueArtists

        return .encode(DiversityResult(
            tracks: selected.map(\.asOutput),
            removedCount: candidates.count - selected.count,
            uniqueArtists: uniqueArtists.count,
            meetsMinArtistRequirement: meetsMinArtists
        ))
    }
}

// MARK: - Internal Types

private struct DiversityCandidate {
    let id: String
    let title: String
    let artistName: String
    let genres: [String]

    init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let artistName = dict["artist_name"] as? String else {
            return nil
        }
        self.id = id
        self.title = (dict["title"] as? String) ?? ""
        self.artistName = artistName
        self.genres = (dict["genres"] as? [String]) ?? []
    }

    var asOutput: DiversityTrackOutput {
        DiversityTrackOutput(id: id, title: title, artistName: artistName, genres: genres)
    }
}

struct DiversityResult: Codable {
    let tracks: [DiversityTrackOutput]
    let removedCount: Int
    let uniqueArtists: Int
    var meetsMinArtistRequirement: Bool?
}

struct DiversityTrackOutput: Codable {
    let id: String
    let title: String
    let artistName: String
    let genres: [String]
}
