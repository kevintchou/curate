//
//  GetRecommendationsTool.swift
//  Curate
//
//  Fetches Apple Music personalized recommendations for the current user.
//  Requires user authorization.
//

import Foundation
import MusicKit

final class GetRecommendationsTool: MusicTool {
    let name = "get_recommendations"
    let description = """
        Get personalized music recommendations from Apple Music for the current user. \
        Returns albums, playlists, and stations Apple thinks the user will enjoy. \
        Useful for low-context prompts or to seed a station with familiar content. \
        Requires user to be signed into Apple Music.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "limit": .integer("Maximum number of recommendation groups to return (default 10)")
        ],
        required: []
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let limit = args.optionalInt("limit", default: 10)

        let request = MusicPersonalRecommendationsRequest()
        let response = try await request.response()

        var groups: [RecommendationGroup] = []

        for item in response.recommendations.prefix(limit) {
            var group = RecommendationGroup(title: item.title ?? "Untitled")

            // Extract playlists
            for playlist in item.playlists {
                group.playlists.append(PlaylistResult(from: playlist))
            }

            // Extract albums
            for album in item.albums {
                group.albums.append(AlbumResult(from: album))
            }

            // Extract stations
            for station in item.stations {
                group.stations.append(StationResult(
                    id: station.id.rawValue,
                    name: station.name
                ))
            }

            groups.append(group)
        }

        return .encode(RecommendationsResult(groups: groups))
    }
}

struct RecommendationGroup: Codable {
    let title: String
    var playlists: [PlaylistResult] = []
    var albums: [AlbumResult] = []
    var stations: [StationResult] = []
}

struct StationResult: Codable {
    let id: String
    let name: String
}

struct RecommendationsResult: Codable {
    let groups: [RecommendationGroup]
}
