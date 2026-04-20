//
//  GetGenreChartsTool.swift
//  Curate
//
//  Fetches top charts for a genre via MusicKit.
//  Useful for genre/decade stations and popularity anchoring.
//

import Foundation
import MusicKit

final class GetGenreChartsTool: MusicTool {
    let name = "get_genre_charts"
    let description = """
        Get the top charts (most popular songs or albums) for a specific genre. \
        Pass a genre ID from search_catalog(types: genres) or use known genre names. \
        Useful for building genre stations or anchoring a station with recognizable tracks.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "genre": .string("Genre name to search charts for (e.g., 'Alternative', 'Hip-Hop')"),
            "chart_type": .stringEnum("Type of chart", values: ["songs", "albums"]),
            "limit": .integer("Maximum chart entries to return (default 25, max 50)")
        ],
        required: ["genre"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let genre = try args.requireString("genre")
        let chartType = args.optionalString("chart_type") ?? "songs"
        let limit = args.optionalInt("limit", default: 25)

        if chartType == "songs" {
            var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self])
            request.limit = min(limit, 50)

            let response = try await request.response()

            var songs: [SongResult] = []
            for chart in response.songCharts {
                for item in chart.items.prefix(limit) {
                    let songResult = SongResult(from: item)
                    // Filter by genre name match if possible
                    if item.genreNames.contains(where: { $0.localizedCaseInsensitiveContains(genre) }) || genre.isEmpty {
                        songs.append(songResult)
                    }
                }
            }

            // If genre filtering removed everything, return unfiltered results
            if songs.isEmpty {
                for chart in response.songCharts {
                    songs = chart.items.prefix(limit).map { SongResult(from: $0) }
                }
            }

            return .encode(GenreChartsResult(genre: genre, chartType: chartType, songs: songs, albums: nil))
        } else {
            var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Album.self])
            request.limit = min(limit, 50)

            let response = try await request.response()

            var albums: [AlbumResult] = []
            for chart in response.albumCharts {
                albums = chart.items.prefix(limit).map { AlbumResult(from: $0) }
            }

            return .encode(GenreChartsResult(genre: genre, chartType: chartType, songs: nil, albums: albums))
        }
    }
}

struct GenreChartsResult: Codable {
    let genre: String
    let chartType: String
    let songs: [SongResult]?
    let albums: [AlbumResult]?
}
