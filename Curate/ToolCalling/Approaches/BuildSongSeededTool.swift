//
//  BuildSongSeededTool.swift
//  Curate
//
//  High-level approach tool: builds a station seeded from a specific song.
//  Uses Apple's radio seed + artist expansion for a "more like this" flow.
//

import Foundation
import MusicKit

final class BuildSongSeededTool: MusicTool {
    let name = "build_song_seeded_station"
    let description = """
        Build a station seeded from a specific song. \
        Finds the song, uses its artist and genre to discover similar tracks, \
        and combines with the artist's catalog for depth. \
        Best for "more like this song" requests. \
        Returns deduplicated candidates.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "song_title": .string("Title of the seed song"),
            "artist_name": .string("Artist name (helps disambiguation)"),
            "track_count": .integer("Target number of tracks to return (default 25)")
        ],
        required: ["song_title"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let songTitle = try args.requireString("song_title")
        let artistHint = args.optionalString("artist_name")
        let trackCount = args.optionalInt("track_count", default: 25)

        let query = artistHint != nil ? "\(songTitle) \(artistHint!)" : songTitle

        // Step 1: Find the seed song
        var searchRequest = MusicCatalogSearchRequest(term: query, types: [Song.self])
        searchRequest.limit = 5
        let searchResponse = try await searchRequest.response()

        guard let seedSong = searchResponse.songs.first else {
            throw ToolError.executionFailed("Could not find song: \(query)")
        }

        var allTracks: [SongSeededTrack] = []
        var seenIds: Set<String> = [seedSong.id.rawValue]

        // Step 2: Search for similar songs by genre + artist
        let genres = seedSong.genreNames
        let searchQueries = [
            "\(seedSong.artistName) \(genres.first ?? "")",
            genres.first ?? seedSong.artistName,
            "\(seedSong.title) similar",
        ]

        for searchQuery in searchQueries {
            var request = MusicCatalogSearchRequest(term: searchQuery, types: [Song.self])
            request.limit = 15
            let response = try await request.response()

            for song in response.songs {
                guard !seenIds.contains(song.id.rawValue) else { continue }
                seenIds.insert(song.id.rawValue)
                allTracks.append(SongSeededTrack(
                    id: song.id.rawValue,
                    title: song.title,
                    artistName: song.artistName,
                    albumTitle: song.albumTitle,
                    isrc: song.isrc,
                    genreNames: song.genreNames,
                    releaseDate: song.releaseDate?.ISO8601Format(),
                    source: "search"
                ))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Step 3: Get seed artist's similar artists for expansion
        var artistRequest = MusicCatalogSearchRequest(term: seedSong.artistName, types: [Artist.self])
        artistRequest.limit = 1
        let artistResponse = try await artistRequest.response()

        if let artist = artistResponse.artists.first {
            var similarRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: artist.id)
            similarRequest.properties = [.topSongs, .similarArtists]
            let similarResponse = try await similarRequest.response()

            if let fullArtist = similarResponse.items.first {
                // Add artist's own top songs
                if let topSongs = fullArtist.topSongs {
                    for song in topSongs.prefix(8) {
                        guard !seenIds.contains(song.id.rawValue) else { continue }
                        seenIds.insert(song.id.rawValue)
                        allTracks.append(SongSeededTrack(
                            id: song.id.rawValue,
                            title: song.title,
                            artistName: song.artistName,
                            albumTitle: song.albumTitle,
                            isrc: song.isrc,
                            genreNames: song.genreNames,
                            releaseDate: song.releaseDate?.ISO8601Format(),
                            source: "seed_artist"
                        ))
                    }
                }

                // Add similar artists' top songs
                if let similarArtists = fullArtist.similarArtists {
                    for simArtist in similarArtists.prefix(3) {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        var simRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: simArtist.id)
                        simRequest.properties = [.topSongs]
                        if let simResponse = try? await simRequest.response(),
                           let simSongs = simResponse.items.first?.topSongs {
                            for song in simSongs.prefix(5) {
                                guard !seenIds.contains(song.id.rawValue) else { continue }
                                seenIds.insert(song.id.rawValue)
                                allTracks.append(SongSeededTrack(
                                    id: song.id.rawValue,
                                    title: song.title,
                                    artistName: song.artistName,
                                    albumTitle: song.albumTitle,
                                    isrc: song.isrc,
                                    genreNames: song.genreNames,
                                    releaseDate: song.releaseDate?.ISO8601Format(),
                                    source: "similar_artist"
                                ))
                            }
                        }
                    }
                }
            }
        }

        // Step 4: Diversity enforcement
        var selected: [SongSeededTrack] = []
        var artistCounts: [String: Int] = [:]
        for track in allTracks {
            let key = track.artistName.lowercased()
            if (artistCounts[key] ?? 0) >= 3 { continue }
            selected.append(track)
            artistCounts[key, default: 0] += 1
            if selected.count >= trackCount { break }
        }

        return .encode(SongSeededResult(
            seedSong: seedSong.title,
            seedArtist: seedSong.artistName,
            seedGenres: seedSong.genreNames,
            totalCandidates: allTracks.count,
            tracks: selected
        ))
    }
}

struct SongSeededTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let genreNames: [String]
    let releaseDate: String?
    let source: String  // "search", "seed_artist", "similar_artist"
}

struct SongSeededResult: Codable {
    let seedSong: String
    let seedArtist: String
    let seedGenres: [String]
    let totalCandidates: Int
    let tracks: [SongSeededTrack]
}
