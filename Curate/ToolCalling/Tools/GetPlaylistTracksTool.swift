//
//  GetPlaylistTracksTool.swift
//  Curate
//
//  Fetches tracks from an Apple Music playlist. Workhorse for playlist mining approach.
//

import Foundation
import MusicKit

final class GetPlaylistTracksTool: MusicTool {
    let name = "get_playlist_tracks"
    let description = """
        Get all tracks from an Apple Music playlist by its ID. \
        Use after search_catalog(types: playlists) to get playlist IDs. \
        Editorial playlists curated by Apple are especially high quality for mood/genre stations.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "playlist_id": .string("Apple Music playlist ID (from search_catalog results)"),
            "limit": .integer("Maximum number of tracks to return (default 50, max 100)")
        ],
        required: ["playlist_id"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let playlistId = try args.requireString("playlist_id")
        let limit = args.optionalInt("limit", default: 50)

        let musicId = MusicItemID(rawValue: playlistId)

        var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: musicId)
        request.properties = [.tracks]

        let response = try await request.response()

        guard let playlist = response.items.first,
              let tracks = playlist.tracks else {
            return .encode(PlaylistTracksResult(playlistId: playlistId, playlistName: nil, songs: []))
        }

        let songs: [SongResult] = Array(tracks.prefix(min(limit, 100))).map { track in
            SongResult(
                id: track.id.rawValue,
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                durationMs: track.duration.map { Int($0 * 1000) },
                releaseDate: track.releaseDate?.ISO8601Format(),
                isrc: track.isrc,
                genreNames: track.genreNames
            )
        }

        return .encode(PlaylistTracksResult(
            playlistId: playlistId,
            playlistName: playlist.name,
            songs: songs
        ))
    }
}

struct PlaylistTracksResult: Codable {
    let playlistId: String
    let playlistName: String?
    let songs: [SongResult]
}
