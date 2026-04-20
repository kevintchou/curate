//
//  StationTestViewModelOldTS.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//
//  LEGACY CODE - DISABLED
//  ======================
//  This ViewModel used the Thompson Sampling RecommendationEngine which has been
//  replaced by the HybridRecommender in the CandidatePool/ folder.
//
//  The hybrid candidate pool architecture provides better recommendations with:
//  - Global pools shared across users (reduces API calls ~90%)
//  - Per-user overlays for personalization
//  - LLM-only for intent parsing, not per-track decisions
//
//  See HYBRID_CANDIDATE_POOL_PLAN.md for architecture details.
//
//  To re-enable: Uncomment the code below and uncomment RecommendationEngine
//  in RecommendationEngine.swift.
//

import Foundation

/*
// LEGACY: Thompson Sampling Test ViewModel
// ========================================
// Commented out in favor of HybridRecommender.
// Preserved for reference and potential A/B testing.

import MusicKit
import SwiftData
import Combine

/// ViewModel for testing the Thompson Sampling recommendation engine
@MainActor
@Observable
final class StationTestViewModelOld {

    // MARK: - Published State

    // Search state
    var searchQuery: String = "" {
        didSet {
            if oldValue != searchQuery {
                searchAsYouType(query: searchQuery)
            }
        }
    }
    var searchResults: [Song] = []
    var isSearching: Bool = false
    var selectedSeedSong: Song?

    // Station state
    var isStationActive: Bool = false
    var currentTrack: Track?
    var currentAppleMusicSong: Song?  // For playback
    var stationStatus: String = ""
    var isLoadingNextTrack: Bool = false

    // Temperature control - read from AppStorage
    var temperature: Float {
        get { Float(UserDefaults.standard.double(forKey: "stationTemperature")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "stationTemperature") }
    }

    // Genre preferences - read from AppStorage (managed in PreferencesView)
    var selectedGenres: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: "selectedGenres"),
                  let genres = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(genres)
        }
    }

    // Feedback counts (for display)
    var likeCount: Int = 0
    var dislikeCount: Int = 0
    var skipCount: Int = 0

    // Debug info
    var candidatePoolSize: Int = 0
    var debugLog: [String] = []

    // MARK: - Private State

    private var station: Station?
    private var seedTrack: Track?
    private var allTracks: [Track] = []
    private var candidatePool: [Track] = []
    private var playbackObserverTask: Task<Void, Never>?
    private var playbackStateObserver: AnyCancellable?

    // MARK: - Dependencies

    private let searchService = SearchService()
    private let trackRepository: TrackRepositoryProtocol
    private let recommendationEngine: RecommendationEngine
    private var modelContext: ModelContext?

    // MARK: - Initialization

    init(
        trackRepository: TrackRepositoryProtocol? = nil,
        modelContext: ModelContext? = nil
    ) {
        // Use provided repository or create default Supabase repository
        self.trackRepository = trackRepository ?? SupabaseTrackRepository()
        self.recommendationEngine = RecommendationEngine(config: .songSeed)
        self.modelContext = modelContext

        // Initialize temperature default if not set
        if UserDefaults.standard.object(forKey: "stationTemperature") == nil {
            UserDefaults.standard.set(0.5, forKey: "stationTemperature")
        }

        log("Initialized with Supabase track repository")
    }

    /// Switch to mock repository (for testing without network)
    func useMockRepository() {
        // This would reinitialize with MockTrackRepository
        log("Note: To use mock data, initialize with MockTrackRepository()")
    }

    // MARK: - Search Methods

    private func searchAsYouType(query: String) {
        isSearching = !query.isEmpty

        searchService.searchAsYouType(query: query) { [weak self] results, searching in
            self?.searchResults = results
            self?.isSearching = searching
        }
    }

    func selectSeedSong(_ song: Song) {
        selectedSeedSong = song
        searchQuery = "\(song.title) - \(song.artistName)"
        searchResults = []
        stationStatus = "Ready to start station"
        log("Selected seed: \(song.title) by \(song.artistName)")

        if let isrc = song.isrc {
            log("ISRC: \(isrc)")
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        selectedSeedSong = nil
        stationStatus = ""
    }

    // MARK: - Station Control

    /// Start a new station with the selected seed song
    func startStation() async {
        guard let seedSong = selectedSeedSong else {
            stationStatus = "Please select a seed song first"
            return
        }

        isLoadingNextTrack = true
        stationStatus = "Starting station..."
        log("Starting station with seed: \(seedSong.title)")

        do {
            // Load all tracks from repository
            allTracks = try await trackRepository.getAllTracks()
            log("Loaded \(allTracks.count) tracks from repository")

            // Try to find the seed track in our database
            if let isrc = seedSong.isrc {
                seedTrack = try await trackRepository.getTrack(byISRC: isrc)
            }

            // If seed not in database, create a placeholder with estimated features
            if seedTrack == nil {
                log("Seed track not in database, using similar track features")
                // Find a similar track to use as proxy features
                if let similarTrack = findSimilarTrack(for: seedSong) {
                    seedTrack = similarTrack
                    log("Using '\(similarTrack.title)' features as proxy")
                } else {
                    // Use average features as fallback
                    seedTrack = allTracks.first
                    log("Using first track as fallback proxy")
                }
            } else {
                log("Found seed track in database")
            }

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
            stationStatus = "▶️ Playing seed: \(seedSong.title)"

            // Start playback
            await playSong(seedSong)

            // Start observing playback state for autoplay
            startPlaybackObserver()

            isLoadingNextTrack = false

            // Immediately preload the first track after seed
            log("Preloading first recommended track...")
            await preloadNextTrack()

        } catch {
            stationStatus = "❌ Error: \(error.localizedDescription)"
            log("Error starting station: \(error)")
            isLoadingNextTrack = false
        }
    }

    /// Get and play the next recommended track
    func playNext() async {
        guard isStationActive, let station = station else {
            stationStatus = "Station not active"
            return
        }

        isLoadingNextTrack = true
        stationStatus = "Finding next track..."

        // Select next track using Thompson Sampling
        let genreWeights: [String: Float]? = selectedGenres.isEmpty ? nil : Dictionary(uniqueKeysWithValues: selectedGenres.map { ($0, Float(1.5)) })

        guard let nextTrack = recommendationEngine.selectNext(
            from: candidatePool,
            parameters: station.thompsonParameters,
            seedFeatures: seedTrack?.featureVector(),
            temperature: temperature,
            genreWeights: genreWeights
        ) else {
            stationStatus = "No more tracks in pool"
            log("Candidate pool exhausted")
            isLoadingNextTrack = false
            return
        }

        log("Selected: \(nextTrack.title) by \(nextTrack.artistName)")
        log("  BPM: \(nextTrack.bpm ?? 0), Energy: \(nextTrack.energy ?? 0)")

        // Update current track
        currentTrack = nextTrack

        // Mark as recently played
        station.addToRecentlyPlayed(nextTrack.isrc)

        // Remove from candidate pool
        candidatePool.removeAll { $0.isrc == nextTrack.isrc }
        candidatePoolSize = candidatePool.count

        // Try to find this track in Apple Music for playback
        if let appleSong = await findAppleMusicSong(for: nextTrack) {
            currentAppleMusicSong = appleSong
            stationStatus = "▶️ Now playing: \(nextTrack.title)"
            await playSong(appleSong)
        } else {
            stationStatus = "⚠️ \(nextTrack.title) - Not available for playback"
            log("Could not find Apple Music match for playback")
        }

        // Rebuild pool if running low
        if candidatePool.count < 20 {
            log("Pool running low, rebuilding...")
            rebuildCandidatePool()
        }

        isLoadingNextTrack = false
    }

    /// Stop the station
    func stopStation() {
        isStationActive = false
        station = nil
        currentTrack = nil
        currentAppleMusicSong = nil
        candidatePool = []
        candidatePoolSize = 0
        stationStatus = "Station stopped"
        log("Station stopped")

        // Cancel playback observers
        playbackObserverTask?.cancel()
        playbackObserverTask = nil
        playbackStateObserver?.cancel()
        playbackStateObserver = nil

        // Stop playback
        SystemMusicPlayer.shared.stop()
    }

    // MARK: - Feedback

    func like() {
        recordFeedback(.like)
        likeCount += 1
        log("👍 Liked")
    }

    func dislike() {
        recordFeedback(.dislike)
        dislikeCount += 1
        log("👎 Disliked")

        // Auto-skip to next on dislike
        Task {
            await playNext()
        }
    }

    func skip() {
        recordFeedback(.skip)
        skipCount += 1
        log("⏭ Skipped")

        Task {
            await playNext()
        }
    }

    private func recordFeedback(_ type: FeedbackType) {
        guard let station = station, let track = currentTrack else { return }

        // Update Thompson Sampling parameters
        let updatedParams = recommendationEngine.updateParameters(
            station.thompsonParameters,
            for: track,
            feedback: type
        )
        station.thompsonParameters = updatedParams

        log("Updated parameters after \(type.rawValue)")
    }

    // MARK: - Temperature Control

    func updateTemperature(_ newValue: Float) {
        temperature = newValue
        station?.temperature = newValue
        log("Temperature set to \(String(format: "%.2f", newValue))")

        // Rebuild candidate pool with new temperature
        if isStationActive {
            rebuildCandidatePool()
        }
    }

    // MARK: - Private Helpers

    private func rebuildCandidatePool() {
        guard let seedTrack = seedTrack else { return }

        let excludeISRCs = station?.recentlyPlayed ?? []

        candidatePool = CandidatePoolBuilder.forSongSeed(
            seedTrack: seedTrack,
            allTracks: allTracks,
            excludeISRCs: excludeISRCs,
            temperature: temperature,
            limit: 200
        )

        candidatePoolSize = candidatePool.count
        log("Built candidate pool: \(candidatePoolSize) tracks")
    }

    private func findSimilarTrack(for song: Song) -> Track? {
        // Try to find a track with similar title/artist
        let titleLower = song.title.lowercased()
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
        // Search Apple Music by title and artist
        do {
            var searchRequest = MusicCatalogSearchRequest(
                term: "\(track.title) \(track.artistName)",
                types: [Song.self]
            )
            searchRequest.limit = 5

            let response = try await searchRequest.response()

            // Try to find exact match by ISRC
            if let match = response.songs.first(where: { $0.isrc == track.isrc }) {
                return match
            }

            // Otherwise return first result
            return response.songs.first

        } catch {
            log("Error finding Apple Music song: \(error)")
            return nil
        }
    }

    private func playSong(_ song: Song) async {
        do {
            let player = SystemMusicPlayer.shared
            player.queue = [song]
            try await player.play()
        } catch {
            log("Playback error: \(error)")
        }
    }

    /// Start observing playback state to autoplay the next track when current one finishes
    private func startPlaybackObserver() {
        // Cancel any existing observer
        playbackObserverTask?.cancel()
        playbackStateObserver?.cancel()

        log("Starting playback observer...")

        let player = SystemMusicPlayer.shared

        // Observe the current entry to know when to queue more songs
        playbackObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var lastItemTitle: String?
            var iterationCount = 0

            // Continuously monitor playback state
            while !Task.isCancelled && self.isStationActive {
                do {
                    iterationCount += 1
                    let state = player.state
                    let currentEntry = player.queue.currentEntry

                    // Get the current playing song title for comparison
                    let currentTitle = (currentEntry?.item as? Song)?.title

                    // Log every 5 iterations for debugging
                    if iterationCount % 5 == 0 {
                        log("Observer check #\(iterationCount): currentTitle=\(currentTitle ?? "nil"), lastTitle=\(lastItemTitle ?? "nil")")
                        log("  Playback status: \(state.playbackStatus)")
                        log("  Has current entry: \(currentEntry != nil)")
                    }

                    // If the song changed, check if we need to queue more
                    if currentTitle != lastItemTitle {
                        if let title = currentTitle {
                            log("🎵 Now playing: \(title)")
                        } else {
                            log("⚠️ Current title is nil")
                        }

                        // When a song starts playing, preload the next one
                        if currentTitle != nil && !self.isLoadingNextTrack {
                            log("▶️ Preloading next track...")
                            await self.preloadNextTrack()
                        }

                        lastItemTitle = currentTitle
                    }

                    // Check every 1 second
                    try? await Task.sleep(for: .seconds(1))

                } catch {
                    log("❌ Playback observer error: \(error)")
                    break
                }
            }

            log("Playback observer stopped")
        }
    }

    /// Preload the next track by adding it to the queue
    private func preloadNextTrack() async {
        guard isStationActive, let station = station else { return }
        guard !isLoadingNextTrack else { return }

        isLoadingNextTrack = true

        // Select next track using Thompson Sampling
        let genreWeights: [String: Float]? = selectedGenres.isEmpty ? nil : Dictionary(uniqueKeysWithValues: selectedGenres.map { ($0, Float(1.5)) })

        guard let nextTrack = recommendationEngine.selectNext(
            from: candidatePool,
            parameters: station.thompsonParameters,
            seedFeatures: seedTrack?.featureVector(),
            temperature: temperature,
            genreWeights: genreWeights
        ) else {
            log("No more tracks in candidate pool")
            isLoadingNextTrack = false
            return
        }

        log("Preloading: \(nextTrack.title) by \(nextTrack.artistName)")

        // Update current track
        currentTrack = nextTrack

        // Mark as recently played
        station.addToRecentlyPlayed(nextTrack.isrc)

        // Remove from candidate pool
        candidatePool.removeAll { $0.isrc == nextTrack.isrc }
        candidatePoolSize = candidatePool.count

        // Try to find this track in Apple Music
        if let appleSong = await findAppleMusicSong(for: nextTrack) {
            currentAppleMusicSong = appleSong

            // Add to the queue instead of replacing it
            let player = SystemMusicPlayer.shared
            do {
                try await player.queue.insert(appleSong, position: .tail)
                log("✅ Queued: \(nextTrack.title)")
                stationStatus = "▶️ Queued: \(nextTrack.title)"
            } catch {
                log("❌ Error queuing track: \(error)")
            }
        } else {
            log("Could not find Apple Music match for: \(nextTrack.title)")
        }

        // Rebuild pool if running low
        if candidatePool.count < 20 {
            log("Pool running low, rebuilding...")
            rebuildCandidatePool()
        }

        isLoadingNextTrack = false
    }

    /// Check if a song ended and trigger autoplay (fallback, shouldn't be needed with queue approach)
    private func checkIfSongEnded() async {
        let player = SystemMusicPlayer.shared
        let currentEntry = player.queue.currentEntry
        let state = player.state

        log("Checking if song ended...")
        log("  Current entry: \(currentEntry != nil ? "Present" : "Nil")")
        log("  Playback status: \(state.playbackStatus)")
        log("  Station active: \(isStationActive)")
        log("  Already loading: \(isLoadingNextTrack)")

        // If current entry is nil and station is active, play next
        if currentEntry == nil && isStationActive && !isLoadingNextTrack {
            log("✅ Song ended, manually playing next track...")
            await self.playNext()
        }
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        debugLog.insert(logEntry, at: 0)

        // Keep only last 50 entries
        if debugLog.count > 50 {
            debugLog = Array(debugLog.prefix(50))
        }

        print("🎵 \(message)")
    }
}
*/
