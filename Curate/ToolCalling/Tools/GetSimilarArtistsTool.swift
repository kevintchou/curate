//
//  GetSimilarArtistsTool.swift
//  Curate
//
//  Fetches similar artists via MusicKit's similarArtists relationship.
//  The graph traversal edge for expanding stations beyond the seed artist.
//

import Foundation
import MusicKit

final class GetSimilarArtistsTool: MusicTool {
    let name = "get_similar_artists"
    let description = """
        Get artists similar to a given artist by their Apple Music ID. \
        Use this to expand a station beyond a seed artist. \
        Each similar artist can then be passed to get_artist_top_songs.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "artist_id": .string("Apple Music artist ID"),
            "limit": .integer("Maximum number of similar artists to return (default 10, max 20)")
        ],
        required: ["artist_id"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let artistId = try args.requireString("artist_id")
        let limit = args.optionalInt("limit", default: 10)

        let musicId = MusicItemID(rawValue: artistId)

        var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: musicId)
        request.properties = [.similarArtists]

        let response = try await request.response()

        guard let artist = response.items.first,
              let similarArtists = artist.similarArtists else {
            return .encode(SimilarArtistsResult(sourceArtistId: artistId, artists: []))
        }

        let artists = Array(similarArtists.prefix(min(limit, 20))).map { ArtistResult(from: $0) }

        return .encode(SimilarArtistsResult(
            sourceArtistId: artistId,
            artists: artists
        ))
    }
}

struct SimilarArtistsResult: Codable {
    let sourceArtistId: String
    let artists: [ArtistResult]
}
