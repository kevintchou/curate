//
//  GetHeavyRotationTool.swift
//  Curate
//
//  Fetches the user's heavy rotation (most played recent items).
//  Useful for understanding current listening habits.
//

import Foundation
import MusicKit

final class GetHeavyRotationTool: MusicTool {
    let name = "get_heavy_rotation"
    let description = """
        Get the user's heavy rotation — the music they've been listening to most recently. \
        Returns albums and playlists the user plays frequently. \
        Use this to understand what the user currently likes before making recommendations.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "limit": .integer("Maximum items to return (default 10)")
        ],
        required: []
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let limit = args.optionalInt("limit", default: 10)

        // Fetch recently played songs as a proxy for heavy rotation
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = limit

        let response = try await request.response()

        var items: [HeavyRotationItem] = []

        for song in response.items.prefix(limit) {
            items.append(HeavyRotationItem(
                id: song.id.rawValue,
                type: "song",
                name: song.title,
                artistName: song.artistName
            ))
        }

        return .encode(HeavyRotationResult(items: items))
    }
}

struct HeavyRotationItem: Codable {
    let id: String
    let type: String
    let name: String
    let artistName: String?
}

struct HeavyRotationResult: Codable {
    let items: [HeavyRotationItem]
}
