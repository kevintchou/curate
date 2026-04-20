//
//  BuildArtistGraphTool.swift
//  Curate
//
//  High-level approach tool: builds a station by traversing the artist similarity graph.
//  Seed artist → similar artists → top songs → filter → ranked candidates.
//

import Foundation
import MusicKit

final class BuildArtistGraphTool: MusicTool {
    let name = "build_artist_graph_station"
    let description = """
        Build a station by traversing the artist similarity graph. \
        Takes a seed artist name, finds similar artists, and collects their top songs. \
        Temperature controls exploration depth: low = stay close to seed, high = go wide. \
        Returns a deduplicated, diversity-enforced candidate list ready for selection. \
        Use this for artist-anchored requests like "station like Radiohead".
        """

    let parameters = ToolParameterSchema(
        properties: [
            "seed_artist": .string("Seed artist name (e.g., 'Radiohead')"),
            "temperature": .number("Exploration level 0-1 (default 0.5). Low = close to seed, high = adventurous"),
            "track_count": .integer("Target number of tracks to return (default 25)"),
            "max_per_artist": .integer("Maximum tracks from any single artist (default 3)")
        ],
        required: ["seed_artist"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let seedArtistName = try args.requireString("seed_artist")
        let temperature = args.optionalDouble("temperature", default: 0.5)
        let trackCount = args.optionalInt("track_count", default: 25)
        let maxPerArtist = args.optionalInt("max_per_artist", default: 3)

        // Step 1: Resolve seed artist
        var searchRequest = MusicCatalogSearchRequest(term: seedArtistName, types: [Artist.self])
        searchRequest.limit = 3
        let searchResponse = try await searchRequest.response()

        guard let seedArtist = searchResponse.artists.first else {
            throw ToolError.executionFailed("Could not find artist: \(seedArtistName)")
        }

        var allSongs: [ArtistGraphSong] = []
        var processedArtistIds: Set<String> = []

        // Step 2: Get seed artist's top songs
        let seedSongs = try await fetchTopSongs(artistId: seedArtist.id.rawValue, artistName: seedArtist.name, source: "seed")
        allSongs.append(contentsOf: seedSongs)
        processedArtistIds.insert(seedArtist.id.rawValue)

        // Step 3: Get similar artists (depth based on temperature)
        let similarCount = max(3, Int(temperature * 10))
        var artistRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: seedArtist.id)
        artistRequest.properties = [.similarArtists]
        let artistResponse = try await artistRequest.response()

        let similarArtists = artistResponse.items.first?.similarArtists ?? MusicItemCollection<Artist>()

        // Step 4: Fetch top songs for similar artists
        for artist in similarArtists.prefix(similarCount) {
            guard !processedArtistIds.contains(artist.id.rawValue) else { continue }
            processedArtistIds.insert(artist.id.rawValue)

            try await Task.sleep(nanoseconds: 100_000_000) // Rate limit

            let songs = try await fetchTopSongs(artistId: artist.id.rawValue, artistName: artist.name, source: "similar")
            allSongs.append(contentsOf: songs)
        }

        // Step 5: Optionally go one more hop for high temperature
        if temperature > 0.7 && similarArtists.count > 0 {
            let secondHopArtist = similarArtists.first!
            var secondRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: secondHopArtist.id)
            secondRequest.properties = [.similarArtists]

            if let secondResponse = try? await secondRequest.response(),
               let secondSimilar = secondResponse.items.first?.similarArtists {
                for artist in secondSimilar.prefix(3) {
                    guard !processedArtistIds.contains(artist.id.rawValue) else { continue }
                    processedArtistIds.insert(artist.id.rawValue)

                    try await Task.sleep(nanoseconds: 100_000_000)
                    let songs = try await fetchTopSongs(artistId: artist.id.rawValue, artistName: artist.name, source: "discovery")
                    allSongs.append(contentsOf: songs)
                }
            }
        }

        // Step 6: Enforce diversity
        var selected: [ArtistGraphSong] = []
        var artistCounts: [String: Int] = [:]

        for song in allSongs {
            let key = song.artistName.lowercased()
            if (artistCounts[key] ?? 0) >= maxPerArtist { continue }
            selected.append(song)
            artistCounts[key, default: 0] += 1
            if selected.count >= trackCount { break }
        }

        return .encode(ArtistGraphResult(
            seedArtist: seedArtist.name,
            artistsExplored: processedArtistIds.count,
            totalCandidates: allSongs.count,
            tracks: selected
        ))
    }

    private func fetchTopSongs(artistId: String, artistName: String, source: String) async throws -> [ArtistGraphSong] {
        let musicId = MusicItemID(rawValue: artistId)

        var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: musicId)
        request.properties = [.topSongs]
        let response = try await request.response()

        guard let topSongs = response.items.first?.topSongs else { return [] }

        return topSongs.prefix(10).map { song in
            ArtistGraphSong(
                id: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                isrc: song.isrc,
                genreNames: song.genreNames,
                releaseDate: song.releaseDate?.ISO8601Format(),
                source: source
            )
        }
    }
}

struct ArtistGraphSong: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let genreNames: [String]
    let releaseDate: String?
    let source: String  // "seed", "similar", "discovery"
}

struct ArtistGraphResult: Codable {
    let seedArtist: String
    let artistsExplored: Int
    let totalCandidates: Int
    let tracks: [ArtistGraphSong]
}
