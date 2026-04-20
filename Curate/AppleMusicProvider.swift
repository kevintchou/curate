//
//  AppleMusicProvider.swift
//  Curate
//
//  MusicKit implementation of MusicProviderProtocol.
//  Handles artist resolution, track fetching, and playback.
//

import Foundation
import MusicKit
import MediaPlayer

// MARK: - Apple Music Provider

final class AppleMusicProvider: MusicProviderProtocol, PlaylistDiscoveryProtocol {
    let providerType: MusicProviderType = .appleMusic

    private let player = SystemMusicPlayer.shared

    // MARK: - Authorization

    var isAuthorized: Bool {
        get async {
            let status = MusicAuthorization.currentStatus
            return status == .authorized
        }
    }

    func requestAuthorization() async throws {
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            throw MusicProviderError.notAuthorized
        }
    }

    // MARK: - Artist Resolution

    func resolveArtists(_ names: [String]) async throws -> [ResolvedArtist] {
        var results: [ResolvedArtist] = []

        for (index, name) in names.enumerated() {
            // Add delay between requests to avoid rate limiting
            if index > 0 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            do {
                if let artist = try await resolveArtist(name) {
                    results.append(artist)
                }
            } catch {
                // Log but continue with other artists
                print("⚠️ Failed to resolve artist '\(name)': \(error.localizedDescription)")
            }
        }

        return results
    }

    private func resolveArtist(_ name: String) async throws -> ResolvedArtist? {
        var request = MusicCatalogSearchRequest(term: name, types: [Artist.self])
        request.limit = 5

        let response = try await request.response()

        guard let artist = response.artists.first else {
            return nil
        }

        // Calculate match confidence based on name similarity
        let confidence = calculateNameSimilarity(searchName: name, foundName: artist.name)

        return ResolvedArtist(
            id: artist.id.rawValue,
            name: artist.name,
            providerType: .appleMusic,
            matchConfidence: confidence,
            genres: artist.genreNames?.isEmpty == false ? artist.genreNames : nil,
            imageURL: artist.artwork?.url(width: 300, height: 300)
        )
    }

    // MARK: - Track Fetching

    func fetchTopTracks(for artist: ResolvedArtist, limit: Int) async throws -> [ProviderTrack] {
        guard artist.providerType == .appleMusic else {
            throw MusicProviderError.invalidData("Artist is not from Apple Music")
        }

        guard let artistId = MusicItemID(artist.id) else {
            throw MusicProviderError.invalidData("Invalid artist ID")
        }

        var artistRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: artistId)
        artistRequest.properties = [.topSongs]

        let response = try await artistRequest.response()

        guard let fullArtist = response.items.first,
              let topSongs = fullArtist.topSongs else {
            throw MusicProviderError.noTracksAvailable(artist.name)
        }

        let tracks = Array(topSongs.prefix(limit)).map { song in
            songToProviderTrack(song, artistId: artist.id)
        }

        if tracks.isEmpty {
            throw MusicProviderError.noTracksAvailable(artist.name)
        }

        return tracks
    }

    func fetchTracks(byIds ids: [String]) async throws -> [ProviderTrack] {
        var tracks: [ProviderTrack] = []

        // Batch fetch to avoid too many individual requests
        let batchSize = 25
        let batches = stride(from: 0, to: ids.count, by: batchSize).map {
            Array(ids[$0..<min($0 + batchSize, ids.count)])
        }

        for (index, batch) in batches.enumerated() {
            if index > 0 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms between batches
            }

            let batchTracks = try await fetchTrackBatch(ids: batch)
            tracks.append(contentsOf: batchTracks)
        }

        return tracks
    }

    private func fetchTrackBatch(ids: [String]) async throws -> [ProviderTrack] {
        var tracks: [ProviderTrack] = []

        for id in ids {
            guard let musicId = MusicItemID(id) else { continue }

            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicId)
                let response = try await request.response()

                if let song = response.items.first {
                    tracks.append(songToProviderTrack(song, artistId: nil))
                }
            } catch {
                // Log but continue with other tracks
                print("⚠️ Failed to fetch track \(id): \(error.localizedDescription)")
            }
        }

        return tracks
    }

    // MARK: - Playback

    func queueTracks(_ tracks: [ProviderTrack]) async throws {
        let songs = try await fetchSongsForTracks(tracks)
        player.queue = .init(for: songs)
    }

    func play(tracks: [ProviderTrack]) async throws {
        let songs = try await fetchSongsForTracks(tracks)
        player.queue = .init(for: songs)
        try await player.play()
    }

    var currentTrack: ProviderTrack? {
        get async {
            guard let entry = player.queue.currentEntry,
                  case .song(let song) = entry.item else {
                return nil
            }
            return songToProviderTrack(song, artistId: nil)
        }
    }

    func skipToNext() async throws {
        try await player.skipToNextEntry()
    }

    func skipToPrevious() async throws {
        try await player.skipToPreviousEntry()
    }

    func pause() async throws {
        player.pause()
    }

    func resume() async throws {
        try await player.play()
    }

    // MARK: - Helpers

    private func fetchSongsForTracks(_ tracks: [ProviderTrack]) async throws -> [Song] {
        var songs: [Song] = []

        for track in tracks {
            guard let musicId = MusicItemID(track.id) else { continue }

            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicId)
            let response = try await request.response()

            if let song = response.items.first {
                songs.append(song)
            }
        }

        return songs
    }

    private func songToProviderTrack(_ song: Song, artistId: String?) -> ProviderTrack {
        ProviderTrack(
            id: song.id.rawValue,
            isrc: song.isrc,
            title: song.title,
            artistName: song.artistName,
            artistId: artistId ?? song.artistName,  // Use artist name as fallback ID
            albumName: song.albumTitle,
            durationMs: song.duration.map { Int($0 * 1000) },
            releaseDate: song.releaseDate?.ISO8601Format(),
            providerType: .appleMusic,
            artworkURL: song.artwork?.url(width: 300, height: 300),
            isExplicit: song.contentRating == .explicit
        )
    }

    /// Calculate similarity between two artist names (case-insensitive)
    private func calculateNameSimilarity(searchName: String, foundName: String) -> Float {
        let search = searchName.lowercased().trimmingCharacters(in: .whitespaces)
        let found = foundName.lowercased().trimmingCharacters(in: .whitespaces)

        if search == found {
            return 1.0
        }

        // Check if one contains the other
        if found.contains(search) || search.contains(found) {
            return 0.9
        }

        // Simple character overlap ratio
        let searchSet = Set(search)
        let foundSet = Set(found)
        let intersection = searchSet.intersection(foundSet)
        let union = searchSet.union(foundSet)

        return Float(intersection.count) / Float(union.count)
    }
}

// MARK: - MusicItemID Extension

extension MusicItemID {
    init?(_ string: String) {
        self.init(rawValue: string)
    }
}

// MARK: - Song Search by ISRC

extension AppleMusicProvider {
    /// Search for a song by ISRC
    func searchByISRC(_ isrc: String) async throws -> ProviderTrack? {
        var request = MusicCatalogSearchRequest(term: isrc, types: [Song.self])
        request.limit = 5

        let response = try await request.response()

        // Find the song with matching ISRC
        for song in response.songs {
            if song.isrc == isrc {
                return songToProviderTrack(song, artistId: nil)
            }
        }

        return nil
    }

    /// Batch search for songs by ISRCs
    func searchByISRCs(_ isrcs: [String]) async throws -> [String: ProviderTrack] {
        var results: [String: ProviderTrack] = [:]

        for (index, isrc) in isrcs.enumerated() {
            if index > 0 && index % 10 == 0 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms every 10 requests
            }

            if let track = try await searchByISRC(isrc) {
                results[isrc] = track
            }
        }

        return results
    }
}

// MARK: - PlaylistDiscoveryProtocol Implementation

extension AppleMusicProvider {

    /// Search for playlists by term
    func searchPlaylists(term: String, limit: Int) async throws -> [ProviderPlaylist] {
        var request = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
        request.limit = limit

        let response = try await request.response()

        return response.playlists.map { playlist in
            ProviderPlaylist(
                id: playlist.id.rawValue,
                name: playlist.name,
                description: playlist.standardDescription,
                trackCount: playlist.tracks?.count ?? 0,
                curatorName: playlist.curatorName,
                isEditorial: playlist.curatorName?.lowercased().contains("apple") ?? false,
                artworkURL: playlist.artwork?.url(width: 300, height: 300)
            )
        }
    }

    /// Get tracks from a playlist
    func getPlaylistTracks(playlistId: String, limit: Int) async throws -> [ProviderTrack] {
        guard let musicId = MusicItemID(playlistId) else {
            throw MusicProviderError.invalidData("Invalid playlist ID")
        }

        var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: musicId)
        request.properties = [.tracks]

        let response = try await request.response()

        guard let playlist = response.items.first,
              let tracks = playlist.tracks else {
            return []
        }

        return Array(tracks.prefix(limit)).compactMap { item -> ProviderTrack? in
            // Playlist tracks can be Songs or MusicVideos
            if let song = item as? Song {
                return songToProviderTrack(song, artistId: nil)
            }
            return nil
        }
    }

    /// Search for tracks in the catalog
    func searchTracks(term: String, genres: [String]?, limit: Int) async throws -> [ProviderTrack] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = limit

        let response = try await request.response()
        var tracks = response.songs.map { songToProviderTrack($0, artistId: nil) }

        // Filter by genre if specified
        if let genres = genres, !genres.isEmpty {
            let lowercasedGenres = Set(genres.map { $0.lowercased() })
            tracks = tracks.filter { track in
                // We don't have genre info in ProviderTrack, so we rely on the search term
                // including genre context. This is a best-effort filter.
                true
            }
        }

        return tracks
    }

    /// Get related artists for an artist
    func getRelatedArtists(artistId: String, limit: Int) async throws -> [ResolvedArtist] {
        guard let musicId = MusicItemID(artistId) else {
            throw MusicProviderError.invalidData("Invalid artist ID")
        }

        // Apple Music doesn't have a direct "related artists" endpoint
        // We can use the artist's similar artists or just return an empty array
        // For now, we'll fetch the artist and use genre-based discovery

        var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: musicId)
        request.properties = [.similarArtists]

        let response = try await request.response()

        guard let artist = response.items.first,
              let similarArtists = artist.similarArtists else {
            return []
        }

        return Array(similarArtists.prefix(limit)).map { similar in
            ResolvedArtist(
                id: similar.id.rawValue,
                name: similar.name,
                providerType: .appleMusic,
                matchConfidence: 0.8,  // Similar artists have good confidence
                genres: similar.genreNames?.isEmpty == false ? similar.genreNames : nil,
                imageURL: similar.artwork?.url(width: 300, height: 300)
            )
        }
    }
}
