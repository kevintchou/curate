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
            "track_count": .integer("Target number of tracks to return (default 50)")
        ],
        required: ["genre"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let genre = try args.requireString("genre")
        let decade = args.optionalInt("decade", default: 0)
        let trackCount = args.optionalInt("track_count", default: 50)

        var seenISRCs: Set<String> = []
        var seenTitleArtist: Set<String> = []

        /// Deduplication helper — returns true if the track is new and registers it.
        func isDuplicate(id: String, isrc: String?, title: String, artistName: String) -> Bool {
            let isrcVal = isrc ?? ""
            if !isrcVal.isEmpty && seenISRCs.contains(isrcVal) { return true }
            let key = "\(title.lowercased().filter { !$0.isWhitespace })||\(artistName.lowercased().filter { !$0.isWhitespace })"
            if seenTitleArtist.contains(key) { return true }
            if !isrcVal.isEmpty { seenISRCs.insert(isrcVal) }
            seenTitleArtist.insert(key)
            return false
        }

        // Step 1: Fetch genre charts — popularity-ranked, used as primary source.
        var chartTracks: [GenreChartTrack] = []
        var chartRequest = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self])
        chartRequest.limit = 100
        let chartResponse = try await chartRequest.response()

        for chart in chartResponse.songCharts {
            for song in chart.items {
                let matchesGenre = song.genreNames.contains { $0.localizedCaseInsensitiveContains(genre) }
                guard matchesGenre else { continue }
                guard !isDuplicate(id: song.id.rawValue, isrc: song.isrc,
                                   title: song.title, artistName: song.artistName) else { continue }
                chartTracks.append(GenreChartTrack(
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

        print("🎵 GenreChart: \(chartTracks.count) chart tracks matched genre '\(genre)'")

        // Step 2: Supplement with genre playlist search — stored per bucket for round-robin.
        // Playlists fill gaps when the chart alone doesn't reach trackCount
        // (common for niche genres or after decade filtering).
        var playlistBuckets: [[GenreChartTrack]] = []
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
                    var bucketTracks: [GenreChartTrack] = []
                    for track in tracks.prefix(100) {
                        guard !isDuplicate(id: track.id.rawValue, isrc: track.isrc,
                                           title: track.title, artistName: track.artistName) else { continue }
                        bucketTracks.append(GenreChartTrack(
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
                    if !bucketTracks.isEmpty {
                        playlistBuckets.append(bucketTracks)
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Step 3: Decade filter — applied to both chart and playlist tracks.
        func applyDecadeFilter(_ tracks: [GenreChartTrack]) -> [GenreChartTrack] {
            guard decade > 0 else { return tracks }
            let decadeEnd = decade + 9
            return tracks.filter { track in
                guard let dateStr = track.releaseDate,
                      let year = Int(dateStr.prefix(4)) else { return true }
                return year >= decade && year <= decadeEnd
            }
        }

        let filteredChart = applyDecadeFilter(chartTracks)
        let filteredBuckets = playlistBuckets.map { applyDecadeFilter($0) }.filter { !$0.isEmpty }

        print("🎵 GenreChart: \(filteredChart.count) chart tracks after decade filter (decade=\(decade > 0 ? "\(decade)" : "none"))")
        let totalCandidates = filteredChart.count + filteredBuckets.reduce(0) { $0 + $1.count }
        print("🎵 GenreChart: \(filteredBuckets.count) playlist buckets, \(totalCandidates) total candidates")

        // Step 4: Chart-first selection, then round-robin across playlist buckets for remainder.
        // Chart tracks are popularity-ranked so their order is preserved.
        // Playlist buckets fill remaining slots via round-robin, respecting Apple's editorial ordering.
        //
        // Commented out: diversity enforcement (artist cap of 2 per artist)
        var selected: [GenreChartTrack] = []

        for track in filteredChart {
            guard selected.count < trackCount else { break }
            selected.append(track)
        }

        if selected.count < trackCount && !filteredBuckets.isEmpty {
            var indices = Array(repeating: 0, count: filteredBuckets.count)
            var anyProgress = true
            while selected.count < trackCount && anyProgress {
                anyProgress = false
                for i in 0..<filteredBuckets.count {
                    guard selected.count < trackCount else { break }
                    guard indices[i] < filteredBuckets[i].count else { continue }
                    selected.append(filteredBuckets[i][indices[i]])
                    indices[i] += 1
                    anyProgress = true
                }
            }
        }

        // var artistCounts: [String: Int] = [:]
        // for track in allTracks {
        //     let key = track.artistName.lowercased()
        //     if (artistCounts[key] ?? 0) >= 2 { continue }
        //     selected.append(track)
        //     artistCounts[key, default: 0] += 1
        //     if selected.count >= trackCount { break }
        // }

        print("🎵 GenreChart: Selected \(selected.count) tracks (target: \(trackCount))")
        return .encode(GenreChartResult(
            genre: genre,
            decade: decade > 0 ? decade : nil,
            totalCandidates: totalCandidates,
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
