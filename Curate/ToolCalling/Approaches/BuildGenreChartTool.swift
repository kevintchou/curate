//
//  BuildGenreChartTool.swift
//  Curate
//
//  High-level approach tool: builds a station from genre charts + editorial playlists.
//  Best for genre/decade-anchored requests.
//

import Foundation
import MusicKit

final class BuildGenreChartTool: MusicTool {
    let name = "build_genre_chart_station"
    let description = """
        Build a station from genre charts and editorial playlists. \
        Finds top songs in a genre, supplements with genre-matching playlists, \
        and optionally filters by decade. \
        Best for requests like "90s alternative" or "top jazz". \
        Returns popularity-ranked, diversity-enforced candidates.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "genre": .string("Genre name (e.g., 'Alternative', 'Jazz', 'Hip-Hop')"),
            "decade": .integer("Optional decade filter (e.g., 1990, 2000, 2010)"),
            "track_count": .integer("Target number of tracks to return (default 25)")
        ],
        required: ["genre"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let genre = try args.requireString("genre")
        let decade = args.optionalInt("decade", default: 0)
        let trackCount = args.optionalInt("track_count", default: 25)

        var allTracks: [GenreChartTrack] = []
        var seenIds: Set<String> = []

        // Step 1: Search for genre charts via top songs
        var chartRequest = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self])
        chartRequest.limit = 50
        let chartResponse = try await chartRequest.response()

        for chart in chartResponse.songCharts {
            for song in chart.items {
                guard !seenIds.contains(song.id.rawValue) else { continue }
                // Genre filter
                let matchesGenre = song.genreNames.contains { $0.localizedCaseInsensitiveContains(genre) }
                guard matchesGenre else { continue }

                seenIds.insert(song.id.rawValue)
                allTracks.append(GenreChartTrack(
                    id: song.id.rawValue,
                    title: song.title,
                    artistName: song.artistName,
                    albumTitle: song.albumTitle,
                    isrc: song.isrc,
                    genreNames: song.genreNames,
                    releaseDate: song.releaseDate?.ISO8601Format(),
                    source: "chart"
                ))
            }
        }

        // Step 2: Supplement with genre playlist search
        let playlistQueries = [genre, "\(genre) essentials", "\(genre) hits"]
        for query in playlistQueries {
            var searchRequest = MusicCatalogSearchRequest(term: query, types: [Playlist.self])
            searchRequest.limit = 3
            let searchResponse = try await searchRequest.response()

            for playlist in searchResponse.playlists.prefix(2) {
                var plRequest = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: playlist.id)
                plRequest.properties = [.tracks]

                if let plResponse = try? await plRequest.response(),
                   let tracks = plResponse.items.first?.tracks {
                    for track in tracks.prefix(20) {
                        guard !seenIds.contains(track.id.rawValue) else { continue }
                        seenIds.insert(track.id.rawValue)
                        allTracks.append(GenreChartTrack(
                            id: track.id.rawValue,
                            title: track.title,
                            artistName: track.artistName,
                            albumTitle: track.albumTitle,
                            isrc: track.isrc,
                            genreNames: track.genreNames,
                            releaseDate: track.releaseDate?.ISO8601Format(),
                            source: "playlist:\(playlist.name)"
                        ))
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Step 3: Decade filter
        if decade > 0 {
            let decadeStart = decade
            let decadeEnd = decade + 9
            allTracks = allTracks.filter { track in
                guard let dateStr = track.releaseDate,
                      let year = Int(dateStr.prefix(4)) else {
                    return true // Keep tracks without date info
                }
                return year >= decadeStart && year <= decadeEnd
            }
        }

        // Step 4: Diversity enforcement
        var selected: [GenreChartTrack] = []
        var artistCounts: [String: Int] = [:]
        for track in allTracks {
            let key = track.artistName.lowercased()
            if (artistCounts[key] ?? 0) >= 2 { continue }
            selected.append(track)
            artistCounts[key, default: 0] += 1
            if selected.count >= trackCount { break }
        }

        return .encode(GenreChartResult(
            genre: genre,
            decade: decade > 0 ? decade : nil,
            totalCandidates: allTracks.count,
            tracks: selected
        ))
    }
}

struct GenreChartTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let genreNames: [String]
    let releaseDate: String?
    let source: String
}

struct GenreChartResult: Codable {
    let genre: String
    let decade: Int?
    let totalCandidates: Int
    let tracks: [GenreChartTrack]
}
