//
//  MusicProviderProtocol.swift
//  Curate
//
//  Protocol for music provider abstraction.
//  Enables swapping between Apple Music, Spotify, etc.
//

import Foundation

// MARK: - Music Provider Protocol

/// Protocol for music streaming providers (Apple Music, Spotify, etc.)
protocol MusicProviderProtocol {
    /// The type of provider
    var providerType: MusicProviderType { get }

    /// Check if the provider is authorized
    var isAuthorized: Bool { get async }

    /// Request authorization from the user
    func requestAuthorization() async throws

    /// Resolve artist names to provider-specific artist objects
    /// - Parameter names: Array of artist names to resolve
    /// - Returns: Array of resolved artists (may be fewer than input if some not found)
    func resolveArtists(_ names: [String]) async throws -> [ResolvedArtist]

    /// Fetch top tracks for an artist
    /// - Parameters:
    ///   - artist: The resolved artist
    ///   - limit: Maximum number of tracks to fetch
    /// - Returns: Array of tracks
    func fetchTopTracks(for artist: ResolvedArtist, limit: Int) async throws -> [ProviderTrack]

    /// Fetch tracks by their provider-specific IDs
    /// - Parameter ids: Array of track IDs
    /// - Returns: Array of tracks
    func fetchTracks(byIds ids: [String]) async throws -> [ProviderTrack]

    /// Add tracks to the playback queue
    /// - Parameter tracks: Tracks to queue
    func queueTracks(_ tracks: [ProviderTrack]) async throws

    /// Start playing tracks immediately
    /// - Parameter tracks: Tracks to play
    func play(tracks: [ProviderTrack]) async throws

    /// Get currently playing track info
    var currentTrack: ProviderTrack? { get async }

    /// Skip to next track
    func skipToNext() async throws

    /// Skip to previous track
    func skipToPrevious() async throws

    /// Pause playback
    func pause() async throws

    /// Resume playback
    func resume() async throws
}

// MARK: - Default Implementations

extension MusicProviderProtocol {
    /// Convenience method to resolve a single artist
    func resolveArtist(_ name: String) async throws -> ResolvedArtist? {
        let results = try await resolveArtists([name])
        return results.first
    }

    /// Fetch top tracks for multiple artists with batching
    /// - Parameters:
    ///   - artists: Array of resolved artists
    ///   - tracksPerArtist: Maximum tracks per artist
    ///   - delayMs: Delay between batches to avoid rate limiting
    /// - Returns: Dictionary mapping artist ID to their tracks
    func fetchTopTracks(
        for artists: [ResolvedArtist],
        tracksPerArtist: Int = 10,
        delayMs: UInt64 = 100
    ) async throws -> [String: [ProviderTrack]] {
        var results: [String: [ProviderTrack]] = [:]

        for (index, artist) in artists.enumerated() {
            // Add delay between requests to avoid rate limiting
            if index > 0 {
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }

            do {
                let tracks = try await fetchTopTracks(for: artist, limit: tracksPerArtist)
                results[artist.id] = tracks
            } catch MusicProviderError.noTracksAvailable {
                // Skip artists with no tracks
                results[artist.id] = []
            }
        }

        return results
    }
}

// MARK: - Artist Seed Generator Protocol

/// Protocol for generating artist seeds from LLM
protocol ArtistSeedGeneratorProtocol {
    /// Generate artist seeds for a station configuration
    /// - Parameters:
    ///   - config: The station configuration
    ///   - tasteSummary: Summary of user's taste preferences
    ///   - avoidArtists: Artists to avoid suggesting
    ///   - count: Number of seeds to generate
    ///   - temperature: Exploration temperature (0=conservative, 1=adventurous)
    ///   - preferredGenres: Genres to boost
    ///   - nonPreferredGenres: Genres to deprioritize
    /// - Returns: Array of artist seeds
    func generateSeeds(
        for config: LLMStationConfig,
        tasteSummary: String,
        avoidArtists: [String],
        count: Int,
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) async throws -> [ArtistSeed]
}

// MARK: - Track Filter Protocol

/// Protocol for filtering tracks based on various criteria
protocol TrackFilterProtocol {
    /// Filter tracks based on context
    /// - Parameters:
    ///   - tracks: All available tracks
    ///   - context: Filtering context (recently played, artist scores, etc.)
    ///   - targetCount: Desired number of tracks after filtering
    /// - Returns: Filtered and scored tracks
    func filter(
        tracks: [ProviderTrack],
        context: TrackFilterContext,
        targetCount: Int
    ) -> [ProviderTrack]
}

// MARK: - Track Filter Context

/// Context for track filtering decisions
struct TrackFilterContext {
    /// ISRCs of recently played tracks
    let recentlyPlayedISRCs: Set<String>

    /// Track IDs of recently played tracks (fallback if no ISRC)
    let recentlyPlayedIds: Set<String>

    /// Artist scores from feedback
    let artistScores: [String: ArtistScore]

    /// Maximum tracks from any single artist
    let maxTracksPerArtist: Int

    /// Days to consider for recency
    let recencyWindowDays: Int

    /// Current station ID (to check station-specific history)
    let stationId: UUID?

    init(
        recentlyPlayedISRCs: Set<String> = [],
        recentlyPlayedIds: Set<String> = [],
        artistScores: [String: ArtistScore] = [:],
        maxTracksPerArtist: Int = 2,
        recencyWindowDays: Int = 45,
        stationId: UUID? = nil
    ) {
        self.recentlyPlayedISRCs = recentlyPlayedISRCs
        self.recentlyPlayedIds = recentlyPlayedIds
        self.artistScores = artistScores
        self.maxTracksPerArtist = maxTracksPerArtist
        self.recencyWindowDays = recencyWindowDays
        self.stationId = stationId
    }
}

// MARK: - Artist Seed Service Protocol

/// User preferences for recommendation tuning
struct UserPreferences {
    let temperature: Double           // 0=conservative, 1=adventurous
    let preferredGenres: [String]     // Genres to boost
    let nonPreferredGenres: [String]  // Genres to deprioritize

    static let `default` = UserPreferences(
        temperature: 0.5,
        preferredGenres: [],
        nonPreferredGenres: []
    )

    /// All available genres for preference selection
    static let availableGenres = [
        "Rock", "Pop", "Hip-Hop", "Electronic", "Jazz",
        "Classical", "Country", "R&B", "Metal", "Folk",
        "Blues", "Reggae", "Latin", "Indie", "Alternative"
    ]

    /// Load preferences from UserDefaults/AppStorage
    static func loadFromStorage() -> UserPreferences {
        let defaults = UserDefaults.standard

        // Load temperature
        let temperature = defaults.double(forKey: "stationTemperature")
        let finalTemperature = temperature == 0 ? 0.5 : temperature // Default if not set

        // Load selected genres
        var preferredGenres: [String] = []
        if let data = defaults.data(forKey: "selectedGenres"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            preferredGenres = decoded
        }

        // Non-preferred = all available genres minus preferred (only if some are selected)
        let nonPreferredGenres: [String]
        if preferredGenres.isEmpty {
            nonPreferredGenres = []
        } else {
            nonPreferredGenres = availableGenres.filter { !preferredGenres.contains($0) }
        }

        return UserPreferences(
            temperature: finalTemperature,
            preferredGenres: preferredGenres,
            nonPreferredGenres: nonPreferredGenres
        )
    }
}

/// Protocol for the main orchestration service
protocol ArtistSeedServiceProtocol {
    /// Get recommended tracks for a station
    /// - Parameters:
    ///   - config: Station configuration
    ///   - userId: Current user's ID
    ///   - count: Number of tracks to return
    ///   - preferences: User preferences for temperature and genres
    /// - Returns: Array of recommended tracks
    func getRecommendedTracks(
        config: LLMStationConfig,
        userId: UUID,
        count: Int,
        preferences: UserPreferences
    ) async throws -> [ProviderTrack]

    /// Record feedback for a track
    /// - Parameter feedback: The feedback record
    func recordFeedback(_ feedback: TrackFeedbackRecord) async throws

    /// Invalidate caches for a user (e.g., after preference change)
    /// - Parameter userId: User ID
    func invalidateCaches(for userId: UUID) async throws
}

// MARK: - Feedback Repository Protocol

/// Protocol for feedback storage operations
protocol FeedbackRepositoryProtocol {
    /// Record a feedback event
    func recordFeedback(_ feedback: TrackFeedbackRecord) async throws

    /// Get all feedback for a user
    func getFeedback(userId: UUID) async throws -> [TrackFeedbackRecord]

    /// Get aggregated artist scores with decay
    func getArtistScores(userId: UUID) async throws -> [ArtistScore]

    /// Get ISRCs of recently played tracks
    func getRecentlyPlayedISRCs(userId: UUID, days: Int) async throws -> [String]

    /// Get track IDs of recently played tracks
    func getRecentlyPlayedTrackIds(userId: UUID, days: Int) async throws -> [String]
}

// MARK: - Artist Cache Repository Protocol

/// Protocol for global artist cache operations
protocol ArtistCacheRepositoryProtocol {
    /// Get cached artist data
    func getCachedArtist(canonicalId: String) async throws -> CachedArtist?

    /// Get multiple cached artists
    func getCachedArtists(canonicalIds: [String]) async throws -> [CachedArtist]

    /// Cache artist data with top tracks
    func cacheArtist(_ artist: ResolvedArtist, topTrackIds: [String]) async throws

    /// Clean up expired cache entries
    func cleanupExpired() async throws
}

// MARK: - Seed Cache Repository Protocol

/// Protocol for per-user seed cache operations
protocol SeedCacheRepositoryProtocol {
    /// Get cached seeds if available and not expired
    func getCachedSeeds(
        userId: UUID,
        configHash: String,
        tasteHash: String
    ) async throws -> [ArtistSeed]?

    /// Cache seeds for a user/config/taste combination
    func cacheSeeds(
        userId: UUID,
        configHash: String,
        tasteHash: String,
        seeds: [ArtistSeed]
    ) async throws

    /// Invalidate all cached seeds for a user
    func invalidateUserCache(userId: UUID) async throws

    /// Clean up expired cache entries
    func cleanupExpired() async throws
}

// MARK: - Playlist Discovery Protocol Extension

/// Extended protocol for playlist discovery (used by hybrid candidate pool)
protocol PlaylistDiscoveryProtocol: MusicProviderProtocol {
    /// Search for playlists by term
    /// - Parameters:
    ///   - term: Search term (e.g., "sunset vibes", "chill")
    ///   - limit: Maximum number of playlists to return
    /// - Returns: Array of discovered playlists
    func searchPlaylists(term: String, limit: Int) async throws -> [ProviderPlaylist]

    /// Get tracks from a playlist
    /// - Parameters:
    ///   - playlistId: The playlist's provider-specific ID
    ///   - limit: Maximum number of tracks to return
    /// - Returns: Array of tracks from the playlist
    func getPlaylistTracks(playlistId: String, limit: Int) async throws -> [ProviderTrack]

    /// Search for tracks in the catalog
    /// - Parameters:
    ///   - term: Search term
    ///   - genres: Optional genre filter
    ///   - limit: Maximum number of tracks to return
    /// - Returns: Array of tracks
    func searchTracks(term: String, genres: [String]?, limit: Int) async throws -> [ProviderTrack]

    /// Get related artists for an artist
    /// - Parameters:
    ///   - artistId: The artist's provider-specific ID
    ///   - limit: Maximum number of related artists
    /// - Returns: Array of related artists
    func getRelatedArtists(artistId: String, limit: Int) async throws -> [ResolvedArtist]
}

// MARK: - Provider Playlist

/// A playlist from a music provider
struct ProviderPlaylist: Identifiable {
    let id: String                    // Provider-specific playlist ID
    let name: String
    let description: String?
    let trackCount: Int
    let curatorName: String?
    let isEditorial: Bool             // True if curated by the platform
    let artworkURL: URL?

    init(
        id: String,
        name: String,
        description: String? = nil,
        trackCount: Int = 0,
        curatorName: String? = nil,
        isEditorial: Bool = false,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.trackCount = trackCount
        self.curatorName = curatorName
        self.isEditorial = isEditorial
        self.artworkURL = artworkURL
    }
}

// MARK: - Default Implementations for Playlist Discovery

extension PlaylistDiscoveryProtocol {
    /// Search for playlists and extract tracks
    /// - Parameters:
    ///   - term: Search term
    ///   - maxPlaylists: Maximum playlists to search
    ///   - tracksPerPlaylist: Maximum tracks per playlist
    /// - Returns: Array of tracks with source information
    func searchPlaylistTracks(
        term: String,
        maxPlaylists: Int = 5,
        tracksPerPlaylist: Int = 20
    ) async throws -> [(track: ProviderTrack, playlistId: String)] {
        let playlists = try await searchPlaylists(term: term, limit: maxPlaylists)

        var results: [(ProviderTrack, String)] = []

        for playlist in playlists {
            do {
                let tracks = try await getPlaylistTracks(
                    playlistId: playlist.id,
                    limit: tracksPerPlaylist
                )
                results.append(contentsOf: tracks.map { ($0, playlist.id) })
            } catch {
                // Skip playlists that fail to load
                continue
            }
        }

        return results
    }

    /// Build a list of PoolTracks from playlist search results
    func buildPoolTracksFromPlaylists(
        searchTerm: String,
        maxPlaylists: Int = 5,
        tracksPerPlaylist: Int = 20
    ) async throws -> [PoolTrack] {
        let results = try await searchPlaylistTracks(
            term: searchTerm,
            maxPlaylists: maxPlaylists,
            tracksPerPlaylist: tracksPerPlaylist
        )

        return results.map { track, playlistId in
            PoolTrack(
                trackId: track.id,
                artistId: track.artistId ?? "",
                isrc: track.isrc,
                source: .playlist,
                sourceDetail: "playlist:\(playlistId)"
            )
        }
    }

    /// Build a list of PoolTracks from catalog search
    func buildPoolTracksFromSearch(
        term: String,
        genres: [String]? = nil,
        limit: Int = 50
    ) async throws -> [PoolTrack] {
        let tracks = try await searchTracks(term: term, genres: genres, limit: limit)

        return tracks.map { track in
            PoolTrack(
                trackId: track.id,
                artistId: track.artistId ?? "",
                isrc: track.isrc,
                source: .search,
                sourceDetail: "search:\(term)"
            )
        }
    }
}
