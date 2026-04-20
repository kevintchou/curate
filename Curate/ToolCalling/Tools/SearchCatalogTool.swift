//
//  SearchCatalogTool.swift
//  Curate
//
//  MusicKit catalog search tool. Searches for songs, artists, albums, and playlists.
//  The most frequently called tool — almost every flow starts here.
//

import Foundation
import MusicKit

final class SearchCatalogTool: MusicTool {
    let name = "search_catalog"
    let description = """
        Search the Apple Music catalog for songs, artists, albums, or playlists. \
        Use this to find music by name, discover editorial playlists by mood/genre, \
        or resolve an artist name to their catalog entry.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "query": .string("Search query (e.g., 'Radiohead', 'sad indie playlist', 'Kind of Blue')"),
            "types": .stringArray("Types to search for. One or more of: songs, artists, albums, playlists"),
            "limit": .integer("Maximum results per type (default 10, max 25)")
        ],
        required: ["query", "types"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let query = try args.requireString("query")
        let types = args.stringArray("types")
        let limit = args.optionalInt("limit", default: 10)

        guard !types.isEmpty else {
            throw ToolError.invalidArguments("'types' must contain at least one of: songs, artists, albums, playlists")
        }

        var result = SearchCatalogResult()

        if types.contains("songs") {
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = min(limit, 25)
            let response = try await request.response()
            result.songs = response.songs.map { SongResult(from: $0) }
        }

        if types.contains("artists") {
            var request = MusicCatalogSearchRequest(term: query, types: [Artist.self])
            request.limit = min(limit, 25)
            let response = try await request.response()
            result.artists = response.artists.map { ArtistResult(from: $0) }
        }

        if types.contains("albums") {
            var request = MusicCatalogSearchRequest(term: query, types: [Album.self])
            request.limit = min(limit, 25)
            let response = try await request.response()
            result.albums = response.albums.map { AlbumResult(from: $0) }
        }

        if types.contains("playlists") {
            var request = MusicCatalogSearchRequest(term: query, types: [Playlist.self])
            request.limit = min(limit, 25)
            let response = try await request.response()
            result.playlists = response.playlists.map { PlaylistResult(from: $0) }
        }

        return .encode(result)
    }
}

// MARK: - Result Types

struct SearchCatalogResult: Codable {
    var songs: [SongResult]?
    var artists: [ArtistResult]?
    var albums: [AlbumResult]?
    var playlists: [PlaylistResult]?
}

struct SongResult: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let durationMs: Int?
    let releaseDate: String?
    let isrc: String?
    let genreNames: [String]

    init(id: String, title: String, artistName: String, albumTitle: String?, durationMs: Int?, releaseDate: String?, isrc: String?, genreNames: [String]) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationMs = durationMs
        self.releaseDate = releaseDate
        self.isrc = isrc
        self.genreNames = genreNames
    }

    init(from song: Song) {
        self.init(
            id: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            durationMs: song.duration.map { Int($0 * 1000) },
            releaseDate: song.releaseDate?.ISO8601Format(),
            isrc: song.isrc,
            genreNames: song.genreNames
        )
    }
}

struct ArtistResult: Codable {
    let id: String
    let name: String
    let genreNames: [String]

    init(from artist: Artist) {
        self.id = artist.id.rawValue
        self.name = artist.name
        self.genreNames = artist.genreNames ?? []
    }
}

struct AlbumResult: Codable {
    let id: String
    let title: String
    let artistName: String
    let releaseDate: String?
    let trackCount: Int?
    let genreNames: [String]

    init(from album: Album) {
        self.id = album.id.rawValue
        self.title = album.title
        self.artistName = album.artistName
        self.releaseDate = album.releaseDate?.ISO8601Format()
        self.trackCount = album.trackCount
        self.genreNames = album.genreNames
    }
}

struct PlaylistResult: Codable {
    let id: String
    let name: String
    let description: String?
    let curatorName: String?

    init(from playlist: Playlist) {
        self.id = playlist.id.rawValue
        self.name = playlist.name
        self.description = playlist.standardDescription
        self.curatorName = playlist.curatorName
    }
}
