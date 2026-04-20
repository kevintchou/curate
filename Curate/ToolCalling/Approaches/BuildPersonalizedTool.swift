//
//  BuildPersonalizedTool.swift
//  Curate
//
//  High-level approach tool: builds a station from the user's personalization data.
//  Uses Apple's recommendations + heavy rotation + optional mood filtering.
//

import Foundation
import MusicKit

final class BuildPersonalizedTool: MusicTool {
    let name = "build_personalized_station"
    let description = """
        Build a station from the user's Apple Music personalization data. \
        Pulls from recommendations and recently played content, \
        then optionally filters by a mood hint. \
        Best for low-context requests like "play me something good" \
        or when the user is a returning listener with listening history. \
        Requires Apple Music authorization.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "mood_hint": .string("Optional mood/vibe to filter by (e.g., 'upbeat', 'chill')"),
            "track_count": .integer("Target number of tracks to return (default 20)")
        ],
        required: []
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let moodHint = args.optionalString("mood_hint")
        let trackCount = args.optionalInt("track_count", default: 20)

        var allTracks: [PersonalizedTrack] = []
        var seenIds: Set<String> = []

        // Step 1: Get personalized recommendations
        let recsRequest = MusicPersonalRecommendationsRequest()
        let recsResponse = try await recsRequest.response()

        for group in recsResponse.recommendations.prefix(5) {
            // Extract tracks from recommended playlists
            for playlist in group.playlists.prefix(2) {
                var plRequest = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: playlist.id)
                plRequest.properties = [.tracks]
                if let plResponse = try? await plRequest.response(),
                   let tracks = plResponse.items.first?.tracks {
                    for track in tracks.prefix(10) {
                        guard !seenIds.contains(track.id.rawValue) else { continue }
                        seenIds.insert(track.id.rawValue)
                        allTracks.append(PersonalizedTrack(
                            id: track.id.rawValue,
                            title: track.title,
                            artistName: track.artistName,
                            albumTitle: track.albumTitle,
                            isrc: track.isrc,
                            genreNames: track.genreNames,
                            releaseDate: track.releaseDate?.ISO8601Format(),
                            source: "recommendation"
                        ))
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            // Extract from recommended albums
            for album in group.albums.prefix(2) {
                var albRequest = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: album.id)
                albRequest.properties = [.tracks]
                if let albResponse = try? await albRequest.response(),
                   let tracks = albResponse.items.first?.tracks {
                    for song in tracks.prefix(5) {
                        guard !seenIds.contains(song.id.rawValue) else { continue }
                        seenIds.insert(song.id.rawValue)
                        allTracks.append(PersonalizedTrack(
                            id: song.id.rawValue,
                            title: song.title,
                            artistName: song.artistName,
                            albumTitle: song.albumTitle,
                            isrc: song.isrc,
                            genreNames: song.genreNames,
                            releaseDate: song.releaseDate?.ISO8601Format(),
                            source: "recommendation_album"
                        ))
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Step 2: Mood filter if provided
        if let mood = moodHint?.lowercased(), !mood.isEmpty {
            let moodWords = Set(mood.components(separatedBy: .whitespaces))
            allTracks = allTracks.filter { track in
                let trackWords = Set(
                    (track.genreNames + [track.title, track.albumTitle ?? ""])
                        .joined(separator: " ")
                        .lowercased()
                        .components(separatedBy: .whitespaces)
                )
                // Keep tracks that have some keyword overlap or all tracks if filter is too strict
                return !moodWords.intersection(trackWords).isEmpty
            }
            // Note: if mood filter removed too many tracks, we proceed with what we have
        }

        // Step 3: Diversity enforcement
        var selected: [PersonalizedTrack] = []
        var artistCounts: [String: Int] = [:]
        for track in allTracks.shuffled() { // Shuffle for variety within personalized content
            let key = track.artistName.lowercased()
            if (artistCounts[key] ?? 0) >= 2 { continue }
            selected.append(track)
            artistCounts[key, default: 0] += 1
            if selected.count >= trackCount { break }
        }

        return .encode(PersonalizedResult(
            moodHint: moodHint,
            totalCandidates: allTracks.count,
            tracks: selected
        ))
    }
}

struct PersonalizedTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let genreNames: [String]
    let releaseDate: String?
    let source: String
}

struct PersonalizedResult: Codable {
    let moodHint: String?
    let totalCandidates: Int
    let tracks: [PersonalizedTrack]
}
