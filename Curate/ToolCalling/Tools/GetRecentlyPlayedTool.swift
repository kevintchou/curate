//
//  GetRecentlyPlayedTool.swift
//  Curate
//
//  Fetches the user's recently played tracks/albums/playlists.
//  Useful for avoiding repeats and understanding context.
//

import Foundation
import MusicKit

final class GetRecentlyPlayedTool: MusicTool {
    let name = "get_recently_played"
    let description = """
        Get the user's recently played items from Apple Music. \
        Returns the last N songs, albums, or playlists the user listened to. \
        Use this to avoid recommending tracks the user just heard.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "limit": .integer("Maximum items to return (default 10, max 30)")
        ],
        required: []
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let limit = args.optionalInt("limit", default: 10)

        // Fetch recently played songs
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = min(limit, 30)

        let response = try await request.response()

        var items: [RecentlyPlayedItem] = []

        for song in response.items.prefix(limit) {
            items.append(RecentlyPlayedItem(
                id: song.id.rawValue,
                type: "song",
                name: song.title,
                artistName: song.artistName
            ))
        }

        return .encode(RecentlyPlayedResult(items: items))
    }
}

struct RecentlyPlayedItem: Codable {
    let id: String
    let type: String
    let name: String
    let artistName: String?
}

struct RecentlyPlayedResult: Codable {
    let items: [RecentlyPlayedItem]
}
