//
//  GetArtistTopSongsTool.swift
//  Curate
//
//  Fetches an artist's top songs via MusicKit. Core tool for artist graph traversal.
//

import Foundation
import MusicKit

final class GetArtistTopSongsTool: MusicTool {
    let name = "get_artist_top_songs"
    let description = """
        Get the top songs for an artist by their Apple Music ID. \
        Returns the most popular tracks. Use after search_catalog to get an artist ID.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "artist_id": .string("Apple Music artist ID (from search_catalog results)"),
            "limit": .integer("Maximum number of songs to return (default 15, max 30)")
        ],
        required: ["artist_id"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let artistId = try args.requireString("artist_id")
        let limit = args.optionalInt("limit", default: 15)

        let musicId = MusicItemID(rawValue: artistId)

        var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: musicId)
        request.properties = [.topSongs]

        let response = try await request.response()

        guard let artist = response.items.first,
              let topSongs = artist.topSongs else {
            return .encode(ArtistTopSongsResult(artistId: artistId, artistName: nil, songs: []))
        }

        let songs = Array(topSongs.prefix(min(limit, 30))).map { SongResult(from: $0) }

        return .encode(ArtistTopSongsResult(
            artistId: artistId,
            artistName: artist.name,
            songs: songs
        ))
    }
}

struct ArtistTopSongsResult: Codable {
    let artistId: String
    let artistName: String?
    let songs: [SongResult]
}
