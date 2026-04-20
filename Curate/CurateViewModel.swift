//
//  CurateViewModel.swift
//  Curate
//
//  Created by Kevin Chou on 11/21/25.
//

import Foundation
import MusicKit
import Combine
import SwiftUI
import MediaPlayer

@MainActor
@Observable
class CurateViewModel {
    // MARK: - Published State
    var songQuery: String = "" {
        didSet {
            searchAsYouType(query: songQuery)
        }
    }
    var searchResults: [Song] = []
    var artistSearchResults: [Artist] = []
    var selectedSong: Song?
    var selectedArtist: Artist?
    var isSearching: Bool = false
    var curateBy: CurateCategory = .song {
        didSet {
            // Clear search when switching modes
            if oldValue != curateBy {
                songQuery = ""
                searchResults = []
                artistSearchResults = []
            }
        }
    }

    // MARK: - Station State
    var isStationActive: Bool = false
    var currentTrack: Track?
    var currentAppleMusicSong: Song?
    var previousAppleMusicSong: Song?
    var nextAppleMusicSong: Song?
    var isLoadingNextTrack: Bool = false

    // Feedback counts
    var likeCount: Int = 0
    var dislikeCount: Int = 0
    var skipCount: Int = 0

    // Debug
    var candidatePoolSize: Int = 0

    // MARK: - Private State
    private var station: Station?
    private var seedTrack: Track?
    private var allTracks: [Track] = []
    private var candidatePool: [Track] = []
    private var playbackObserverTask: Task<Void, Never>?

    /// History of played songs (for going back)
    private var playedSongsHistory: [(track: Track, song: Song)] = []

    // MARK: - Dependencies
    private let searchService = SearchService()
    private let trackRepository: TrackRepositoryProtocol
    
    // MARK: - Types
    enum CurateCategory: String, CaseIterable {
        case song = "Song"
        case artist = "Artist"
        case aiSearch = "AI Search"
        case genre = "Genre"
        case decade = "Decade"
        case activity = "Activity"
        case mood = "Mood"
    }

    // MARK: - Initialization
    init(trackRepository: TrackRepositoryProtocol? = nil) {
        self.trackRepository = trackRepository ?? SupabaseTrackRepository()
    }

    // MARK: - Public Methods

    func clearSearch() {
        songQuery = ""
        selectedSong = nil
        selectedArtist = nil
        searchResults = []
        artistSearchResults = []
    }
    
    func selectSong(_ song: Song) {
        songQuery = "\(song.title) - \(song.artistName)"
        selectedSong = song
        selectedArtist = nil
        searchResults = []
        artistSearchResults = []
    }
    
    func selectArtist(_ artist: Artist) {
        songQuery = artist.name
        selectedArtist = artist
        selectedSong = nil
        searchResults = []
        artistSearchResults = []
    }
    
    func selectFirstResult() {
        if curateBy == .song {
            if let firstSong = searchResults.first {
                selectSong(firstSong)
            }
        } else if curateBy == .artist {
            if let firstArtist = artistSearchResults.first {
                selectArtist(firstArtist)
            }
        }
    }
    
    func playSong(_ song: Song) {
        Task {
            await startStation(with: song)
        }
    }

    /// Start a recommendation station with the selected seed song
    func startStation(with seedSong: Song) async {
        // Stop any existing station
        stopStation()

        isLoadingNextTrack = true
        print("🎵 Starting station...")

        do {
            // Load all tracks from repository
            allTracks = try await trackRepository.getAllTracks()
            print("📚 Loaded \(allTracks.count) tracks from repository")

            // Try to find the seed track in our database
            if let isrc = seedSong.isrc {
                seedTrack = try await trackRepository.getTrack(byISRC: isrc)
            }

            // If seed not in database, find a similar track to use as proxy
            if seedTrack == nil {
                print("⚠️ Seed track not in database, using similar track features")
                if let similarTrack = findSimilarTrack(for: seedSong) {
                    seedTrack = similarTrack
                    print("✅ Using '\(similarTrack.title)' features as proxy")
                } else {
                    seedTrack = allTracks.first
                    print("⚠️ Using first track as fallback proxy")
                }
            } else {
                print("✅ Found seed track in database")
            }

            // Get temperature from user defaults (or use default)
            let temperature = Float(UserDefaults.standard.object(forKey: "stationTemperature") as? Double ?? 0.5)

            // Create the station
            station = Station(
                name: "\(seedSong.title) Radio",
                stationType: .songSeed,
                seedTrackISRC: seedSong.isrc,
                seedTrackTitle: seedSong.title,
                seedTrackArtist: seedSong.artistName,
                temperature: temperature
            )

            // Build initial candidate pool
            rebuildCandidatePool()

            // Play the seed song first
            isStationActive = true
            currentAppleMusicSong = seedSong
            currentTrack = seedTrack  // Set the seed track as current
            print("▶️ Playing seed: \(seedSong.title)")

            // Start playback
            await playAppleMusicSong(seedSong)

            // Start observing playback for autoplay
            startPlaybackObserver()

            // Configure remote commands AFTER playback starts
            // This ensures our handlers override SystemMusicPlayer's defaults
            configureRemoteCommands()

            isLoadingNextTrack = false

            // Preload first recommended track
            print("⏩ Preloading first recommended track...")
            await preloadNextTrack()

        } catch {
            print("❌ Error starting station: \(error.localizedDescription)")
            isLoadingNextTrack = false
        }
    }
    
    func playArtist(_ artist: Artist) {
        Task {
            do {
                print("✅ Playing artist: \(artist.name)")
                print("🎵 Artist ID: \(artist.id)")
                
                // Request authorization
                let status = await MusicAuthorization.request()
                guard status == .authorized else {
                    print("❌ Apple Music access not authorized")
                    return
                }
                
                // Fetch top songs for the artist and play them
                var artistRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: artist.id)
                artistRequest.properties = [.topSongs]
                
                let artistResponse = try await artistRequest.response()
                
                if let fullArtist = artistResponse.items.first,
                   let topSongs = fullArtist.topSongs {
                    let player = SystemMusicPlayer.shared
                    player.queue = .init(for: Array(topSongs))
                    try await player.play()

                    print("▶️ Now playing top songs from: \(artist.name)")
                } else {
                    print("❌ No songs found for artist: \(artist.name)")
                }
                
            } catch {
                print("❌ Error playing artist: \(error.localizedDescription)")
            }
        }
    }
    
    /// Stop the station
    func stopStation() {
        guard isStationActive else { return }

        isStationActive = false
        station = nil
        currentTrack = nil
        currentAppleMusicSong = nil
        previousAppleMusicSong = nil
        nextAppleMusicSong = nil
        candidatePool = []
        candidatePoolSize = 0
        playedSongsHistory = []

        // Reset feedback counts
        likeCount = 0
        dislikeCount = 0
        skipCount = 0

        // Cancel playback observer
        playbackObserverTask?.cancel()
        playbackObserverTask = nil

        // Clear remote command handlers
        RemoteCommandManager.shared.clearHandlers()

        // Stop playback
        SystemMusicPlayer.shared.stop()

        print("⏹ Station stopped")
    }

    // MARK: - Remote Command Center

    private func configureRemoteCommands() {
        RemoteCommandManager.shared.updateHandlers(
            onNext: { [weak self] in
                print("🎛️ CurateStation: Remote next track command received")
                await self?.playNext()
            },
            onPrevious: { [weak self] in
                print("🎛️ CurateStation: Remote previous track command received")
                await self?.playPrevious()
            },
            onLike: { [weak self] in
                print("🎛️ CurateStation: Remote like command received")
                self?.like()
            },
            onDislike: { [weak self] in
                print("🎛️ CurateStation: Remote dislike command received")
                self?.dislike()
            }
        )
        print("🎛️ Remote commands configured for Curate station")
    }

    /// Play the previous song (if available in history)
    func playPrevious() async {
        guard isStationActive else {
            print("⚠️ Station not active")
            return
        }

        // Need at least one song in history to go back
        guard !playedSongsHistory.isEmpty else {
            print("⏮️ No previous song available")
            return
        }

        // Pop the last played song from history
        let previous = playedSongsHistory.removeLast()

        print("⏮️ Going back to: \(previous.track.title)")

        // Store current as next (for previousAppleMusicSong tracking)
        if let current = currentTrack, let currentSong = currentAppleMusicSong {
            // Re-add current to candidate pool so it can be played again
            if !candidatePool.contains(where: { $0.isrc == current.isrc }) {
                candidatePool.append(current)
                candidatePoolSize = candidatePool.count
            }
        }

        // Update previous song display (what was before the song we're going back to)
        previousAppleMusicSong = playedSongsHistory.last?.song

        // Update current
        currentTrack = previous.track
        currentAppleMusicSong = previous.song

        // Play it
        await playAppleMusicSong(previous.song)
    }

    /// Play the next recommended track
    func playNext() async {
        guard isStationActive, let station = station else {
            print("⚠️ Station not active")
            return
        }

        isLoadingNextTrack = true
        print("🔍 Finding next track...")

        // Save current song to history before switching (if we have one)
        if let current = currentTrack, let currentSong = currentAppleMusicSong {
            playedSongsHistory.append((track: current, song: currentSong))
            // Keep history limited to prevent memory issues
            if playedSongsHistory.count > 50 {
                playedSongsHistory.removeFirst()
            }
            print("📀 Added to history: \(current.title)")
        }

        // Update previous song display
        previousAppleMusicSong = currentAppleMusicSong

        // Get genre preferences if any
        let selectedGenres = getSelectedGenres()

        // Select next track using simple similarity-based selection
        guard let nextTrack = selectNextTrack(
            from: candidatePool,
            seedFeatures: seedTrack?.featureVector(),
            preferredGenres: selectedGenres
        ) else {
            print("❌ No more tracks in pool - candidate pool exhausted")
            isLoadingNextTrack = false
            return
        }

        print("🎵 Selected: \(nextTrack.title) by \(nextTrack.artistName)")

        // Update current track
        currentTrack = nextTrack

        // Mark as recently played
        station.addToRecentlyPlayed(nextTrack.isrc)

        // Remove from candidate pool
        candidatePool.removeAll { $0.isrc == nextTrack.isrc }
        candidatePoolSize = candidatePool.count

        // Find in Apple Music for playback
        if let appleSong = await findAppleMusicSong(for: nextTrack) {
            currentAppleMusicSong = appleSong
            print("▶️ Now playing: \(nextTrack.title)")
            await playAppleMusicSong(appleSong)
        } else {
            print("⚠️ \(nextTrack.title) - Not available in Apple Music")
            // Try next track
            await playNext()
            return
        }

        // Rebuild pool if running low
        if candidatePool.count < 20 {
            print("🔄 Pool running low, rebuilding...")
            rebuildCandidatePool()
        }

        isLoadingNextTrack = false
    }

    // MARK: - Feedback Methods

    func like() {
        recordFeedback(.like)
        likeCount += 1
        print("👍 Liked: \(currentTrack?.title ?? "Unknown")")
    }

    func dislike() {
        recordFeedback(.dislike)
        dislikeCount += 1
        print("👎 Disliked: \(currentTrack?.title ?? "Unknown")")

        // Auto-skip on dislike
        Task {
            await playNext()
        }
    }

    func skip() {
        recordFeedback(.skip)
        skipCount += 1
        print("⏭ Skipped: \(currentTrack?.title ?? "Unknown")")

        Task {
            await playNext()
        }
    }

    // MARK: - Private Methods

    private func recordFeedback(_ type: FeedbackType) {
        guard let track = currentTrack else { return }

        // Record feedback in user overlay for future recommendations
        switch type {
        case .like:
            // Boost similar tracks in future selections
            print("🔧 Recorded like for \(track.title)")
        case .dislike:
            // Deprioritize similar tracks
            print("🔧 Recorded dislike for \(track.title)")
        case .skip:
            // Mild negative signal
            print("🔧 Recorded skip for \(track.title)")
        case .listenThrough:
            // Positive signal
            print("🔧 Recorded listen-through for \(track.title)")
        }
    }

    private func rebuildCandidatePool() {
        guard let seedTrack = seedTrack, let station = station else { return }

        let excludeISRCs = Set(station.recentlyPlayed)
        let seedFeatures = seedTrack.featureVector()
        let temperature = station.temperature

        // Calculate similarity ranges based on temperature
        // Higher temperature = wider range (more exploration)
        let bpmTolerance: Float = 0.15 + (temperature * 0.25)  // 15-40% tolerance
        let energyTolerance: Float = 0.2 + (temperature * 0.3)  // 20-50% tolerance

        let filtered = allTracks.filter { track in
            // Exclude recently played
            guard !excludeISRCs.contains(track.isrc) else { return false }

            // Must have audio features
            guard track.hasAudioFeatures else { return false }

            // Exclude the seed track itself
            guard track.isrc != seedTrack.isrc else { return false }

            let features = track.featureVector()

            // BPM filter
            if abs(features.bpm - seedFeatures.bpm) > bpmTolerance {
                return false
            }

            // Energy filter (looser)
            if abs(features.energy - seedFeatures.energy) > energyTolerance {
                return false
            }

            return true
        }

        // Sort by similarity to seed
        let sorted = filtered.sorted { track1, track2 in
            let sim1 = track1.featureVector().similarity(to: seedFeatures)
            let sim2 = track2.featureVector().similarity(to: seedFeatures)
            return sim1 > sim2
        }

        candidatePool = Array(sorted.prefix(200))
        candidatePoolSize = candidatePool.count
        print("🏗 Built candidate pool: \(candidatePoolSize) tracks")
    }

    private func findSimilarTrack(for song: Song) -> Track? {
        let _ = song.title.lowercased()  // Reserved for future title matching
        let artistLower = song.artistName.lowercased()

        // First try exact artist match
        if let match = allTracks.first(where: { $0.artistName.lowercased() == artistLower }) {
            return match
        }

        // Then try partial artist match
        if let match = allTracks.first(where: { $0.artistName.lowercased().contains(artistLower) || artistLower.contains($0.artistName.lowercased()) }) {
            return match
        }

        // Return a random track as fallback
        return allTracks.randomElement()
    }

    private func findAppleMusicSong(for track: Track) async -> Song? {
        do {
            var searchRequest = MusicCatalogSearchRequest(
                term: "\(track.title) \(track.artistName)",
                types: [Song.self]
            )
            searchRequest.limit = 5

            let response = try await searchRequest.response()

            // Try exact ISRC match first
            if let match = response.songs.first(where: { $0.isrc == track.isrc }) {
                return match
            }

            // Fallback to first result
            return response.songs.first

        } catch {
            print("❌ Error finding Apple Music song: \(error)")
            return nil
        }
    }

    private func playAppleMusicSong(_ song: Song) async {
        do {
            let player = SystemMusicPlayer.shared
            player.queue = [song]
            try await player.play()
            // Small delay to let SystemMusicPlayer finish its setup
            try? await Task.sleep(for: .milliseconds(100))
            // Reconfigure remote commands after playback starts
            // SystemMusicPlayer may override handlers when queue changes
            configureRemoteCommands()
        } catch {
            print("❌ Playback error: \(error)")
        }
    }

    private func startPlaybackObserver() {
        playbackObserverTask?.cancel()

        print("👀 Starting playback observer...")

        playbackObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let player = SystemMusicPlayer.shared
            var lastItemId: String?

            while !Task.isCancelled && self.isStationActive {
                let currentEntry = player.queue.currentEntry
                let currentSong = currentEntry?.item as? Song
                let currentId = currentSong?.id.rawValue

                // If song changed, update current track and preload next
                if let currentId = currentId, currentId != lastItemId {
                    if lastItemId != nil {
                        print("🎵 Song changed to: \(currentSong?.title ?? "Unknown")")

                        // Update currentTrack to match what's actually playing
                        if let song = currentSong {
                            await self.updateCurrentTrackFromAppleSong(song)
                        }

                        if !self.isLoadingNextTrack {
                            await self.preloadNextTrack()
                        }
                    } else {
                        print("👀 Observer started, tracking: \(currentSong?.title ?? "Unknown")")
                    }
                    lastItemId = currentId
                }

                try? await Task.sleep(for: .milliseconds(500))
            }

            print("👀 Playback observer stopped")
        }
    }

    /// Update currentTrack by finding it in our database via ISRC
    private func updateCurrentTrackFromAppleSong(_ song: Song) async {
        // Store previous song before switching
        previousAppleMusicSong = currentAppleMusicSong

        // Try to find this track in our database
        if let isrc = song.isrc {
            if let dbTrack = allTracks.first(where: { $0.isrc == isrc }) {
                currentTrack = dbTrack
                currentAppleMusicSong = song
                print("✅ Updated currentTrack: \(dbTrack.title)")
                return
            }
        }

        // If not found by ISRC, try by title/artist match
        let titleLower = song.title.lowercased()
        let artistLower = song.artistName.lowercased()
        if let dbTrack = allTracks.first(where: {
            $0.title.lowercased() == titleLower && $0.artistName.lowercased() == artistLower
        }) {
            currentTrack = dbTrack
            currentAppleMusicSong = song
            print("✅ Updated currentTrack (by title/artist): \(dbTrack.title)")
        }
    }

    private func preloadNextTrack() async {
        guard isStationActive, let station = station else { return }
        guard !isLoadingNextTrack else { return }

        isLoadingNextTrack = true

        // Get genre preferences if any
        let selectedGenres = getSelectedGenres()

        guard let nextTrack = selectNextTrack(
            from: candidatePool,
            seedFeatures: seedTrack?.featureVector(),
            preferredGenres: selectedGenres
        ) else {
            print("⚠️ No tracks to preload")
            isLoadingNextTrack = false
            return
        }

        print("⏩ Preloading: \(nextTrack.title) by \(nextTrack.artistName)")

        // Mark as recently played and remove from pool
        station.addToRecentlyPlayed(nextTrack.isrc)
        candidatePool.removeAll { $0.isrc == nextTrack.isrc }
        candidatePoolSize = candidatePool.count

        if let appleSong = await findAppleMusicSong(for: nextTrack) {
            let player = SystemMusicPlayer.shared
            do {
                try await player.queue.insert(appleSong, position: .tail)
                print("✅ Queued next: \(nextTrack.title)")
            } catch {
                print("❌ Error queuing track: \(error)")
            }
        }

        if candidatePool.count < 20 {
            rebuildCandidatePool()
        }

        // Look ahead to find the NEXT track for UI display (2 tracks ahead)
        await updateNextSongPreview()

        isLoadingNextTrack = false
    }

    /// Updates nextAppleMusicSong by looking ahead in the candidate pool
    /// This shows what will play AFTER the currently queued track
    private func updateNextSongPreview() async {
        guard station != nil else {
            nextAppleMusicSong = nil
            return
        }

        // Get genre preferences if any
        let selectedGenres = getSelectedGenres()

        // Peek at what would be selected next (without committing)
        guard let previewTrack = selectNextTrack(
            from: candidatePool,
            seedFeatures: seedTrack?.featureVector(),
            preferredGenres: selectedGenres
        ) else {
            nextAppleMusicSong = nil
            return
        }

        // Find Apple Music song for preview display only
        if let previewSong = await findAppleMusicSong(for: previewTrack) {
            nextAppleMusicSong = previewSong
            print("📀 Next up preview: \(previewTrack.title)")
        } else {
            nextAppleMusicSong = nil
        }
    }

    private func getSelectedGenres() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "selectedGenres"),
              let genres = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(genres)
    }

    /// Simple track selection based on similarity and genre preferences
    /// Replaces the legacy Thompson Sampling RecommendationEngine
    private func selectNextTrack(
        from candidates: [Track],
        seedFeatures: TrackFeatures?,
        preferredGenres: Set<String>
    ) -> Track? {
        guard !candidates.isEmpty else { return nil }

        // Score each candidate
        let scored = candidates.map { track -> (Track, Float) in
            var score: Float = 0.5  // Base score

            // Similarity bonus if we have seed features
            if let seedFeatures = seedFeatures {
                let similarity = track.featureVector().similarity(to: seedFeatures)
                score = score * 0.6 + similarity * 0.4
            }

            // Genre preference bonus
            if !preferredGenres.isEmpty, let trackGenre = track.genre {
                let trackGenreLower = trackGenre.lowercased()
                let isPreferred = preferredGenres.contains { $0.lowercased() == trackGenreLower }
                if isPreferred {
                    score *= 2.0  // Boost preferred genres
                } else {
                    score *= 0.5  // Reduce non-preferred
                }
            }

            // Add small random noise for variety
            score += Float.random(in: 0...0.1)

            return (track, score)
        }

        // Sort by score and pick from top candidates with some randomness
        let sorted = scored.sorted { $0.1 > $1.1 }

        // Pick randomly from top 10% for variety
        let topCount = max(1, Int(Float(sorted.count) * 0.1))
        let topCandidates = Array(sorted.prefix(topCount))

        return topCandidates.randomElement()?.0
    }

    private func searchAsYouType(query: String) {
        // Return early for AI Search - no actual search needed
        if curateBy == .aiSearch {
            return
        }

        isSearching = !query.isEmpty

        if curateBy == .song {
            searchService.searchAsYouType(query: query) { [weak self] results, isSearching in
                guard let self else { return }
                self.searchResults = results
                self.artistSearchResults = []
                self.isSearching = isSearching
            }
        } else if curateBy == .artist {
            searchService.searchArtistsAsYouType(query: query) { [weak self] results, isSearching in
                guard let self else { return }
                self.artistSearchResults = results
                self.searchResults = []
                self.isSearching = isSearching
            }
        }
    }

    // MARK: - Unified Player Data

    /// Creates StationPlaybackData for unified player views
    func createPlaybackData() -> StationPlaybackData {
        // Fixed gradient colors for custom pill stations
        let gradientColors = [Color.blue.opacity(0.7), Color.purple.opacity(0.8)]

        // Station name based on selected song or artist
        let stationName: String
        if let song = selectedSong {
            stationName = "\(song.title) Radio"
        } else if let artist = selectedArtist {
            stationName = "\(artist.name) Radio"
        } else {
            stationName = "Station Radio"
        }

        return StationPlaybackData(
            currentTrack: currentTrack,
            currentSong: currentAppleMusicSong,
            stationName: stationName,
            stationIcon: "music.note",
            gradientColors: gradientColors,
            likeCount: likeCount,
            skipCount: skipCount,
            dislikeCount: dislikeCount,
            candidatePoolSize: candidatePoolSize,
            isStationActive: isStationActive,
            isLoadingNextTrack: isLoadingNextTrack,
            onPlayNext: { [weak self] in
                await self?.playNext()
            },
            onLike: { [weak self] in
                self?.like()
            },
            onDislike: { [weak self] in
                self?.dislike()
            },
            onSkip: { [weak self] in
                self?.skip()
            }
        )
    }
}
