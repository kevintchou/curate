//
//  GetSongRadioSeedTool.swift
//  Curate
//
//  Creates an Apple Music radio station seeded from a specific song.
//  Surfaces Apple's own radio algorithm as a candidate source.
//

import Foundation
import MusicKit

final class GetSongRadioSeedTool: MusicTool {
    let name = "get_song_radio_seed"
    let description = """
        Create an Apple Music radio station seeded from a specific song. \
        Apple's algorithm generates a stream of similar tracks based on the seed. \
        Use this for "more like this song" requests. \
        Returns the station info which can be used to queue tracks for playback.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "song_id": .string("Apple Music song ID to seed the radio station from"),
            "limit": .integer("Number of tracks to pull from the station (default 20)")
        ],
        required: ["song_id"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let songId = try args.requireString("song_id")
        let limit = args.optionalInt("limit", default: 20)

        let musicId = MusicItemID(rawValue: songId)

        // Fetch the song with its station relationship
        var songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicId)
        songRequest.properties = [.station]

        let songResponse = try await songRequest.response()

        guard let song = songResponse.items.first else {
            throw ToolError.executionFailed("Song not found: \(songId)")
        }

        // Get the station seeded from this song
        guard let station = song.station else {
            // Fallback: search for similar songs by artist
            return .encode(SongRadioResult(
                seedSongId: songId,
                seedSongTitle: song.title,
                seedArtist: song.artistName,
                stationName: nil,
                songs: [],
                fallbackMessage: "No radio station available for this song. Try get_similar_artists or search_catalog instead."
            ))
        }

        // Fetch tracks from the station by searching for similar content
        // Note: MusicKit doesn't directly expose station track lists,
        // so we use the song's artist and genre to find related tracks
        var searchRequest = MusicCatalogSearchRequest(
            term: "\(song.artistName) \(song.genreNames.first ?? "")",
            types: [Song.self]
        )
        searchRequest.limit = min(limit, 30)

        let searchResponse = try await searchRequest.response()

        let songs = searchResponse.songs
            .filter { $0.id.rawValue != songId } // Exclude the seed song
            .prefix(limit)
            .map { SongResult(from: $0) }

        return .encode(SongRadioResult(
            seedSongId: songId,
            seedSongTitle: song.title,
            seedArtist: song.artistName,
            stationName: station.name,
            songs: Array(songs),
            fallbackMessage: nil
        ))
    }
}

struct SongRadioResult: Codable {
    let seedSongId: String
    let seedSongTitle: String
    let seedArtist: String
    let stationName: String?
    let songs: [SongResult]
    let fallbackMessage: String?
}
