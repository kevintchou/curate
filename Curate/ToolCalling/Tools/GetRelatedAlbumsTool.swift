//
//  GetRelatedAlbumsTool.swift
//  Curate
//
//  Fetches albums related to a given album. Useful for deep-cut discovery.
//

import Foundation
import MusicKit

final class GetRelatedAlbumsTool: MusicTool {
    let name = "get_related_albums"
    let description = """
        Get albums related to a given album by its Apple Music ID. \
        Returns similar albums that listeners of the source album also enjoy. \
        Useful for deep-cut discovery and expanding beyond top hits.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "album_id": .string("Apple Music album ID"),
            "limit": .integer("Maximum related albums to return (default 10)")
        ],
        required: ["album_id"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let albumId = try args.requireString("album_id")
        let limit = args.optionalInt("limit", default: 10)

        let musicId = MusicItemID(rawValue: albumId)

        var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: musicId)
        request.properties = [.relatedAlbums]

        let response = try await request.response()

        guard let album = response.items.first,
              let relatedAlbums = album.relatedAlbums else {
            return .encode(RelatedAlbumsResult(sourceAlbumId: albumId, albums: []))
        }

        let albums = Array(relatedAlbums.prefix(limit)).map { AlbumResult(from: $0) }

        return .encode(RelatedAlbumsResult(
            sourceAlbumId: albumId,
            albums: albums
        ))
    }
}

struct RelatedAlbumsResult: Codable {
    let sourceAlbumId: String
    let albums: [AlbumResult]
}
