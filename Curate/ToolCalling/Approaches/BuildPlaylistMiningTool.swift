//
//  BuildPlaylistMiningTool.swift
//  Curate
//
//  High-level approach tool: builds a station by mining Apple Music editorial playlists.
//  Expands intent to queries → finds playlists → extracts and ranks tracks.
//

import Foundation
import MusicKit

final class BuildPlaylistMiningTool: MusicTool {
    let name = "build_playlist_mining_station"
    let description = """
        Build a station by mining Apple Music editorial playlists. \
        Takes a mood/vibe description, expands it into search queries, \
        finds matching playlists, extracts tracks, and ranks by diversity. \
        Best for mood/vibe/activity requests like "sad indie for a rainy day". \
        Returns deduplicated, ranked candidates.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "intent": .string("Natural language description (e.g., 'chill electronic for late night coding')"),
            "genre_hints": .stringArray("Optional genre hints to focus the search"),
            "track_count": .integer("Target number of tracks to return (default 30)"),
            "max_playlists": .integer("Maximum playlists to mine (default 5)")
        ],
        required: ["intent"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let intent = try args.requireString("intent")
        let genreHints = args.stringArray("genre_hints")
        let trackCount = args.optionalInt("track_count", default: 30)
        let maxPlaylists = args.optionalInt("max_playlists", default: 5)

        // Step 1: Generate search queries
        let queries = generateQueries(intent: intent, genres: genreHints)

        // Step 2: Search for playlists
        var playlistMap: [String: (Playlist, String)] = [:] // id -> (playlist, query)
        for query in queries.prefix(6) {
            var request = MusicCatalogSearchRequest(term: query, types: [Playlist.self])
            request.limit = 3
            let response = try await request.response()

            for playlist in response.playlists {
                if playlistMap[playlist.id.rawValue] == nil {
                    playlistMap[playlist.id.rawValue] = (playlist, query)
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000) // Rate limit
        }

        // Step 3: Score playlists by relevance (prefer editorial)
        let scoredPlaylists = playlistMap.values.map { playlist, query -> (Playlist, Double, String) in
            var score = 0.0
            let isEditorial = playlist.curatorName?.lowercased().contains("apple") ?? false
            if isEditorial { score += 0.3 }
            let nameWords = Set(playlist.name.lowercased().components(separatedBy: .whitespaces))
            let intentWords = Set(intent.lowercased().components(separatedBy: .whitespaces))
            let overlap = nameWords.intersection(intentWords)
            score += Double(overlap.count) * 0.15
            if playlist.name.lowercased().contains(intent.lowercased()) { score += 0.2 }
            return (playlist, score, query)
        }.sorted { $0.1 > $1.1 }

        // Step 4: Extract tracks from top playlists
        var allTracks: [PlaylistMinedTrack] = []
        var seenISRCs: Set<String> = []

        for (playlist, _, query) in scoredPlaylists.prefix(maxPlaylists) {
            var trackRequest = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: playlist.id)
            trackRequest.properties = [.tracks]
            let trackResponse = try await trackRequest.response()

            guard let tracks = trackResponse.items.first?.tracks else { continue }

            for track in tracks.prefix(30) {
                let isrc = track.isrc ?? ""
                if !isrc.isEmpty && seenISRCs.contains(isrc) { continue }
                if !isrc.isEmpty { seenISRCs.insert(isrc) }

                allTracks.append(PlaylistMinedTrack(
                    id: track.id.rawValue,
                    title: track.title,
                    artistName: track.artistName,
                    albumTitle: track.albumTitle,
                    isrc: track.isrc,
                    genreNames: track.genreNames,
                    releaseDate: track.releaseDate?.ISO8601Format(),
                    sourcePlaylist: playlist.name,
                    sourceQuery: query
                ))
            }

            try await Task.sleep(nanoseconds: 100_000_000) // Rate limit
        }

        // Step 5: Diversity enforcement
        var selected: [PlaylistMinedTrack] = []
        var artistCounts: [String: Int] = [:]
        for track in allTracks {
            let key = track.artistName.lowercased()
            if (artistCounts[key] ?? 0) >= 2 { continue }
            selected.append(track)
            artistCounts[key, default: 0] += 1
            if selected.count >= trackCount { break }
        }

        return .encode(PlaylistMiningResult(
            intent: intent,
            playlistsSearched: scoredPlaylists.count,
            playlistsMined: min(scoredPlaylists.count, maxPlaylists),
            totalCandidates: allTracks.count,
            tracks: selected
        ))
    }

    private func generateQueries(intent: String, genres: [String]) -> [String] {
        var queries: [String] = [intent]
        queries.append("\(intent) playlist")
        for genre in genres.prefix(2) {
            queries.append("\(genre) \(intent)")
        }
        let words = intent.lowercased().components(separatedBy: .whitespaces)
        if words.count > 2 {
            queries.append(words.prefix(2).joined(separator: " "))
        }
        queries.append("\(intent) vibes")
        return queries
    }
}

struct PlaylistMinedTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let genreNames: [String]
    let releaseDate: String?
    let sourcePlaylist: String
    let sourceQuery: String
}

struct PlaylistMiningResult: Codable {
    let intent: String
    let playlistsSearched: Int
    let playlistsMined: Int
    let totalCandidates: Int
    let tracks: [PlaylistMinedTrack]
}
