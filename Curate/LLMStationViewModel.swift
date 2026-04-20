//
//  LLMStationViewModel.swift
//  Curate
//
//  Unified ViewModel for all LLM-powered stations.
//  Handles predefined stations (Mood, Activity, Genre, Decade) and free-text AI search.
//

import Foundation
import MusicKit
import SwiftData
import Combine
import MediaPlayer

// MARK: - LLM Station ViewModel
@MainActor
@Observable
final class LLMStationViewModel {

    // MARK: - Published State

    /// Current station configuration (any category)
    var stationConfig: LLMStationConfig?

    /// Original unified config that created this station
    var originalConfig: (any UnifiedStationConfigProtocol)?

    /// The persisted station model
    var station: Station?

    /// Whether the station is active
    var isStationActive: Bool = false

    /// Current song being played
    var currentSong: Song?

    /// Previous Apple Music song (for UI display)
    var previousAppleMusicSong: Song?

    /// Next Apple Music song that's queued (for UI display)
    var nextAppleMusicSong: Song?

    /// Current queue item
    var currentQueueItem: LLMQueueItem?

    /// Song queue
    var queue: [LLMQueueItem] = []

    /// Station status message
    var statusMessage: String = ""

    /// Loading states
    var isCreatingStation: Bool = false
    var isLoadingSongs: Bool = false
    var isVerifyingSong: Bool = false

    /// Error message
    var errorMessage: String?

    /// Feedback counts
    var likeCount: Int = 0
    var dislikeCount: Int = 0
    var skipCount: Int = 0

    /// Debug log
    var debugLog: [String] = []

    /// Current track (computed from currentQueueItem for unified player compatibility)
    var currentTrack: Track? {
        guard let item = currentQueueItem else { return nil }
        let suggestion = item.suggestion

        return Track(
            id: UUID(),
            isrc: item.isrc ?? "",
            spotifyId: nil,
            appleMusicId: item.appleMusicId,
            reccobeatsId: nil,
            title: suggestion.title,
            artistName: suggestion.artist,
            albumName: suggestion.album,
            durationMs: nil,
            releaseDate: suggestion.year != nil ? "\(suggestion.year!)" : nil,
            genre: nil,
            hasLyrics: nil,
            bpm: suggestion.estimatedBpm,
            energy: suggestion.estimatedEnergy,
            danceability: suggestion.estimatedDanceability,
            valence: suggestion.estimatedValence,
            acousticness: suggestion.estimatedAcousticness,
            instrumentalness: suggestion.estimatedInstrumentalness,
            liveness: nil,
            speechiness: nil,
            loudness: nil,
            key: nil,
            mode: nil,
            attributesFetchedAt: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    // MARK: - Private State

    private var llmServiceProvider_: LLMServiceProvider?
    private var llmServiceDirect: LLMStationServiceProtocol?

    /// Always returns the current active service (supports runtime switching)
    private var llmService: LLMStationServiceProtocol {
        llmServiceProvider_?.llmService ?? llmServiceDirect!
    }
    private var artistSeedService: ArtistSeedServiceProtocol?
    private var hybridPoolService: HybridPoolIntegrationService?
    private var heuristicPoolService: HeuristicPoolIntegrationService?
    private var toolCallingService: ToolCallingStationService?
    private var authManager: AuthManager?
    private var modelContext: ModelContext?
    private var playbackObserverTask: Task<Void, Never>?
    private var tasteProfile: LLMTasteProfile = .empty
    private var feedbackHistory: [FeedbackRecord] = []

    /// Whether to use artist-seeded recommendations (new approach)
    private var useArtistSeededRecommendations: Bool = true

    /// Get current recommendation engine from feature flag
    private var currentEngine: RecommendationEngine {
        RecommendationEngineFlag.current
    }

    /// Check if hybrid pool is enabled via feature flag (legacy compatibility)
    private var isHybridPoolEnabled: Bool {
        currentEngine == .hybridPool
    }

    /// Check if heuristic pool is enabled via feature flag
    private var isHeuristicPoolEnabled: Bool {
        currentEngine == .heuristicPool
    }

    /// Check if tool-calling engine is enabled via feature flag
    private var isToolCallingEnabled: Bool {
        currentEngine == .toolCalling
    }

    /// Threshold for refreshing suggestions
    private let queueLowThreshold = 5
    private let suggestionBatchSize = 15

    /// Number of songs to keep in SystemMusicPlayer's queue (current + upcoming)
    private let playerQueueSize = 3

    /// Track which songs have been added to SystemMusicPlayer's queue (by Apple Music ID)
    private var songsAddedToPlayerQueue: Set<String> = []

    // MARK: - Initialization

    /// Initialize with an LLM service (required) and optional model context.
    /// Use `LLMServiceProvider.shared.llmService` for production or inject a mock for testing.
    init(
        llmService: LLMStationServiceProtocol,
        artistSeedService: ArtistSeedServiceProtocol? = ArtistSeedService(),
        hybridPoolService: HybridPoolIntegrationService? = nil,
        heuristicPoolService: HeuristicPoolIntegrationService? = nil,
        toolCallingService: ToolCallingStationService? = nil,
        authManager: AuthManager? = nil,
        modelContext: ModelContext? = nil
    ) {
        self.llmServiceDirect = llmService
        self.llmServiceProvider_ = nil
        self.artistSeedService = artistSeedService
        self.hybridPoolService = hybridPoolService
        self.heuristicPoolService = heuristicPoolService
        self.toolCallingService = toolCallingService
        self.authManager = authManager
        self.modelContext = modelContext
        log("LLMStationViewModel initialized")
    }

    /// Initialize with a provider reference (supports runtime service switching).
    /// This is the preferred initializer for production use.
    init(
        provider: LLMServiceProvider,
        artistSeedService: ArtistSeedServiceProtocol? = ArtistSeedService(),
        authManager: AuthManager? = nil,
        modelContext: ModelContext? = nil
    ) {
        self.llmServiceProvider_ = provider
        self.llmServiceDirect = nil
        self.artistSeedService = artistSeedService
        self.hybridPoolService = nil
        self.heuristicPoolService = nil
        self.toolCallingService = nil
        self.authManager = authManager
        self.modelContext = modelContext
        log("LLMStationViewModel initialized with provider")
    }

    /// Convenience initializer that uses the shared LLMServiceProvider.
    convenience init(modelContext: ModelContext? = nil) {
        self.init(
            provider: LLMServiceProvider.shared,
            artistSeedService: ArtistSeedService(),
            authManager: nil,
            modelContext: modelContext
        )
    }

    /// Set the auth manager (called from view when environment is available)
    func setAuthManager(_ authManager: AuthManager) {
        self.authManager = authManager
    }

    // MARK: - Station Creation (from UnifiedStationConfig)

    /// Start a station from any UnifiedStationConfigProtocol (Mood, Activity, Genre, Decade)
    func startStation<T: UnifiedStationConfigProtocol>(with config: T) async {
        isCreatingStation = true
        errorMessage = nil
        statusMessage = "Creating \(config.name) station..."
        log("Starting station from config: \(config.name) (\(config.category))")

        // Reset playback state for fresh start
        currentSong = nil
        previousAppleMusicSong = nil
        nextAppleMusicSong = nil
        currentQueueItem = nil
        queue.removeAll()

        // Store original config
        originalConfig = config

        // Convert to LLMStationConfig
        let llmConfig = config.toLLMStationConfig()
        stationConfig = llmConfig

        do {
            // Create and persist Station model
            let newStation = Station(
                name: llmConfig.name,
                stationType: stationTypeFromCategory(config.category),
                temperature: config.defaultTemperature
            )
            newStation.originalPrompt = llmConfig.originalPrompt
            newStation.llmStationConfig = llmConfig

            if let context = modelContext {
                context.insert(newStation)
                try context.save()
                log("Station saved to SwiftData")
            }

            station = newStation

            // Get initial song suggestions
            statusMessage = "Finding songs..."
            try await fetchSongSuggestions()

            // Start playback
            if !queue.isEmpty {
                isStationActive = true
                startPlaybackObserver()
                configureRemoteCommands()
                await playNext()
            } else {
                errorMessage = "Couldn't find matching songs. Try a different station."
            }

        } catch {
            log("Error creating station: \(error)")
            errorMessage = "Failed to create station: \(error.localizedDescription)"
        }

        isCreatingStation = false
    }

    /// Create a station from a free-form natural language prompt (custom/AI search)
    func createStation(from prompt: String) async {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter a description for your station"
            return
        }

        isCreatingStation = true
        errorMessage = nil
        statusMessage = "Creating your station..."
        log("Creating station from prompt: \(prompt)")

        // Reset playback state for fresh start
        currentSong = nil
        previousAppleMusicSong = nil
        nextAppleMusicSong = nil
        currentQueueItem = nil
        queue.removeAll()

        do {
            // Generate config from LLM
            let config = try await llmService.generateConfig(from: prompt, tasteProfile: tasteProfile)
            stationConfig = config
            log("Generated config: \(config.name)")

            // Create and persist Station model
            let newStation = Station(
                name: config.name,
                stationType: .llmGenerated,
                temperature: 0.5
            )
            newStation.originalPrompt = prompt
            newStation.llmStationConfig = config

            if let context = modelContext {
                context.insert(newStation)
                try context.save()
                log("Station saved to SwiftData")
            }

            station = newStation

            // Get initial song suggestions
            statusMessage = "Finding songs..."
            try await fetchSongSuggestions()

            // Start playback
            if !queue.isEmpty {
                isStationActive = true
                startPlaybackObserver()
                configureRemoteCommands()
                await playNext()
            } else {
                errorMessage = "Couldn't find matching songs. Try a different description."
            }

        } catch {
            log("Error creating station: \(error)")
            errorMessage = "Failed to create station: \(error.localizedDescription)"
        }

        isCreatingStation = false
    }

    /// Resume a previously saved station
    func resumeStation(_ existingStation: Station) async {
        guard let config = existingStation.llmStationConfig else {
            errorMessage = "This station has no saved configuration"
            return
        }

        station = existingStation
        stationConfig = config
        tasteProfile = existingStation.llmTasteProfile ?? .empty

        // Reset playback state for fresh start
        currentSong = nil
        previousAppleMusicSong = nil
        nextAppleMusicSong = nil
        currentQueueItem = nil
        queue.removeAll()

        // Load feedback history
        loadFeedbackHistory()

        // Update counts from history
        likeCount = feedbackHistory.filter { $0.type == .like }.count
        dislikeCount = feedbackHistory.filter { $0.type == .dislike }.count
        skipCount = feedbackHistory.filter { $0.type == .skip }.count

        statusMessage = "Resuming \(config.name)..."
        log("Resuming station: \(config.name)")

        do {
            // Fetch fresh suggestions based on learned preferences
            try await fetchSongSuggestions()

            if !queue.isEmpty {
                isStationActive = true
                startPlaybackObserver()
                configureRemoteCommands()
                await playNext()
            }
        } catch {
            errorMessage = "Failed to resume station: \(error.localizedDescription)"
        }
    }

    // MARK: - Song Suggestions

    private func fetchSongSuggestions() async throws {
        guard let config = stationConfig else { return }

        isLoadingSongs = true
        log("Fetching song suggestions...")

        // When using local AI, always route through tool-calling (no backend dependency)
        let isLocalAI = llmServiceProvider_?.activeServiceType == .local
        if isLocalAI || isToolCallingEnabled {
            let userId = authManager?.currentUser?.id ?? UUID()
            log(isLocalAI
                ? "📱 Using local AI tool-calling for user: \(userId.uuidString)"
                : "🛠️ Using AI tool-calling recommendations for user: \(userId.uuidString)")
            try await fetchToolCallingSuggestions(config: config, userId: userId)
            isLoadingSongs = false
            log("Queue size: \(queue.count)")
            return
        }

        guard let userId = authManager?.currentUser?.id else {
            log("❌ User not authenticated - cannot fetch recommendations")
            isLoadingSongs = false
            throw LLMServiceError.apiError("User not authenticated")
        }

        log("🔧 Current recommendation engine: \(currentEngine.displayName)")

        // Check if heuristic pool is enabled (on-device parsing)
        if isHeuristicPoolEnabled {
            log("🧠 Using heuristic pool recommendations for user: \(userId.uuidString)")
            try await fetchHeuristicPoolSuggestions(config: config, userId: userId)
            isLoadingSongs = false
            log("Queue size: \(queue.count)")
            return
        }

        // Check if hybrid pool is enabled (LLM-based)
        if isHybridPoolEnabled {
            log("🏊 Using hybrid pool recommendations for user: \(userId.uuidString)")
            try await fetchHybridPoolSuggestions(config: config, userId: userId)
            isLoadingSongs = false
            log("Queue size: \(queue.count)")
            return
        }

        // Fall back to artist-seeded approach
        guard let artistService = artistSeedService else {
            log("❌ ArtistSeedService not available")
            isLoadingSongs = false
            throw LLMServiceError.notInitialized
        }

        log("🌱 Using artist-seeded recommendations for user: \(userId.uuidString)")

        try await fetchArtistSeededSuggestions(config: config, userId: userId, service: artistService)
        isLoadingSongs = false
        log("Queue size: \(queue.count)")

        // MARK: - Legacy fallback (commented out)
        /*
        // Debug: Log why we might fall back to legacy
        let userIdString = authManager?.currentUser.map { $0.id.uuidString } ?? "nil"
        log("🔍 Artist-seeded check: useArtistSeeded=\(useArtistSeededRecommendations), hasService=\(artistSeedService != nil), hasAuth=\(authManager != nil), userId=\(userIdString)")

        // Try artist-seeded approach first if available and user is authenticated
        if useArtistSeededRecommendations,
           let artistService = artistSeedService,
           let userId = authManager?.currentUser?.id {
            do {
                try await fetchArtistSeededSuggestions(config: config, userId: userId, service: artistService)
                isLoadingSongs = false
                log("Queue size: \(queue.count)")
                return
            } catch {
                log("⚠️ Artist-seeded fetch failed, falling back to legacy: \(error.localizedDescription)")
                // Fall through to legacy approach
            }
        }

        // Legacy approach: direct LLM song suggestions
        try await fetchLegacySuggestions(config: config)

        isLoadingSongs = false
        log("Queue size: \(queue.count)")
        */
    }

    /// Tool-calling recommendation approach (LLM autonomously calls MusicKit tools)
    private func fetchToolCallingSuggestions(
        config: LLMStationConfig,
        userId: UUID
    ) async throws {
        log("🛠️ Using AI tool-calling recommendations")

        // Lazy initialize or re-create if backend type changed
        let backend: ToolCallingLLMBackend = {
            if let provider = llmServiceProvider_, provider.activeServiceType == .local,
               let localProvider = provider.localProvider {
                return LocalToolCallingBackend(provider: localProvider)
            }
            return SupabaseToolCallingBackend()
        }()

        // Always re-create to pick up the current backend
        toolCallingService = ToolCallingStationService(
            feedbackRepository: nil,
            userId: userId,
            llmBackend: backend
        )

        guard let service = toolCallingService else {
            throw LLMServiceError.notInitialized
        }

        // Forward progress updates to the status message
        service.onProgress = { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
                self?.log(message)
            }
        }

        let preferences = UserPreferences.loadFromStorage()
        let prompt = config.originalPrompt ?? config.name

        let result = try await service.buildStation(
            prompt: prompt,
            preferences: preferences
        )

        log("Tool-calling completed: \(result.tracks.count) tracks, \(result.turnsUsed) turns, approach: \(result.approachUsed)")
        log("Reasoning: \(result.reasoning)")

        // Shuffle before adding so tracks from different artists are interleaved,
        // not played in consecutive artist blocks.
        for track in result.tracks.shuffled() {
            if queue.contains(where: { $0.appleMusicId == track.id }) {
                continue
            }

            let suggestion = LLMSongSuggestion(
                title: track.title,
                artist: track.artistName,
                album: track.albumName,
                year: track.releaseDate.flatMap { Int($0.prefix(4)) },
                reason: "AI tool-calling: \(result.approachUsed)",
                estimatedBpm: nil,
                estimatedEnergy: nil,
                estimatedValence: nil,
                estimatedDanceability: nil,
                estimatedAcousticness: nil,
                estimatedInstrumentalness: nil,
                verificationStatus: .verified,
                appleMusicId: track.id,
                isrc: track.isrc,
                artworkURL: track.artworkURL?.absoluteString
            )

            var queueItem = LLMQueueItem(suggestion: suggestion)
            queueItem.appleMusicId = track.id
            queueItem.isrc = track.isrc
            queueItem.artworkURL = track.artworkURL
            queueItem.status = .queued
            queue.append(queueItem)

            log("✅ Added: \(track.title) by \(track.artistName)")
        }
    }

    /// New artist-seeded recommendation approach
    private func fetchArtistSeededSuggestions(
        config: LLMStationConfig,
        userId: UUID,
        service: ArtistSeedServiceProtocol
    ) async throws {
        log("🌱 Using artist-seeded recommendations")

        // Load user preferences from AppStorage
        let preferences = UserPreferences.loadFromStorage()

        let tracks = try await service.getRecommendedTracks(
            config: config,
            userId: userId,
            count: suggestionBatchSize,
            preferences: preferences
        )

        log("Received \(tracks.count) tracks from artist seeds")

        // Convert ProviderTracks to queue items
        for track in tracks {
            // Skip if already in queue
            if queue.contains(where: { $0.appleMusicId == track.id }) {
                continue
            }

            // Create an LLMSongSuggestion from the provider track
            let suggestion = LLMSongSuggestion(
                title: track.title,
                artist: track.artistName,
                album: track.albumName,
                year: track.releaseDate.flatMap { Int($0.prefix(4)) },
                reason: "From artist-seeded recommendations",
                estimatedBpm: nil,
                estimatedEnergy: nil,
                estimatedValence: nil,
                estimatedDanceability: nil,
                estimatedAcousticness: nil,
                estimatedInstrumentalness: nil,
                verificationStatus: .verified,
                appleMusicId: track.id,
                isrc: track.isrc,
                artworkURL: track.artworkURL?.absoluteString
            )

            var queueItem = LLMQueueItem(suggestion: suggestion)
            queueItem.appleMusicId = track.id
            queueItem.isrc = track.isrc
            queueItem.artworkURL = track.artworkURL
            queueItem.status = .queued
            queue.append(queueItem)

            log("✅ Added: \(track.title) by \(track.artistName)")
        }
    }

    /// Hybrid pool recommendation approach (uses global cached pools)
    private func fetchHybridPoolSuggestions(
        config: LLMStationConfig,
        userId: UUID
    ) async throws {
        log("🏊 Using hybrid pool recommendations")

        // Lazy initialize hybrid pool service if needed
        if hybridPoolService == nil {
            // Create the service with dependencies
            let supabaseClient = SupabaseConfig.client
            let musicProvider = AppleMusicProvider()

            hybridPoolService = HybridPoolIntegrationService(
                supabaseClient: supabaseClient,
                musicProvider: musicProvider,
                artistSeedService: artistSeedService
            )
            log("🏊 Initialized HybridPoolIntegrationService")
        }

        guard let service = hybridPoolService else {
            log("❌ Failed to initialize HybridPoolIntegrationService")
            throw LLMServiceError.notInitialized
        }

        // Load user preferences from AppStorage
        let preferences = UserPreferences.loadFromStorage()

        let tracks = try await service.getRecommendedTracks(
            prompt: config.originalPrompt,
            config: config,
            userId: userId,
            stationId: station?.id ?? UUID(),
            count: suggestionBatchSize,
            preferences: preferences
        )

        log("🏊 Received \(tracks.count) tracks from hybrid pool")

        // Convert ProviderTracks to queue items
        for track in tracks {
            // Skip if already in queue
            if queue.contains(where: { $0.appleMusicId == track.id }) {
                continue
            }

            // Create an LLMSongSuggestion from the provider track
            let suggestion = LLMSongSuggestion(
                title: track.title,
                artist: track.artistName,
                album: track.albumName,
                year: track.releaseDate.flatMap { Int($0.prefix(4)) },
                reason: "From hybrid pool recommendations",
                estimatedBpm: nil,
                estimatedEnergy: nil,
                estimatedValence: nil,
                estimatedDanceability: nil,
                estimatedAcousticness: nil,
                estimatedInstrumentalness: nil,
                verificationStatus: .verified,
                appleMusicId: track.id,
                isrc: track.isrc,
                artworkURL: track.artworkURL?.absoluteString
            )

            var queueItem = LLMQueueItem(suggestion: suggestion)
            queueItem.appleMusicId = track.id
            queueItem.isrc = track.isrc
            queueItem.artworkURL = track.artworkURL
            queueItem.status = .queued
            queue.append(queueItem)

            log("🏊 Added: \(track.title) by \(track.artistName)")
        }
    }

    /// Heuristic pool recommendation approach (on-device parsing, genre-aware)
    private func fetchHeuristicPoolSuggestions(
        config: LLMStationConfig,
        userId: UUID
    ) async throws {
        log("🧠 Using heuristic pool recommendations")

        // Lazy initialize heuristic pool service if needed
        if heuristicPoolService == nil {
            let musicProvider = AppleMusicProvider()

            heuristicPoolService = HeuristicPoolIntegrationService(
                musicProvider: musicProvider,
                artistSeedService: artistSeedService
            )
            log("🧠 Initialized HeuristicPoolIntegrationService")
        }

        guard let service = heuristicPoolService else {
            log("❌ Failed to initialize HeuristicPoolIntegrationService")
            throw LLMServiceError.notInitialized
        }

        // For heuristic pool, use a cleaner prompt for predefined stations
        // Predefined stations have originalConfig set; custom/AI search does not
        let heuristicPrompt: String
        if originalConfig != nil {
            // Predefined station - use just the station name for cleaner parsing
            heuristicPrompt = config.name
            log("🧠 Using station name as prompt: \"\(heuristicPrompt)\"")
        } else {
            // Custom/free-text input - use the original prompt
            heuristicPrompt = config.originalPrompt
            log("🧠 Using original prompt: \"\(heuristicPrompt)\"")
        }

        let tracks = try await service.getRecommendedTracks(
            prompt: heuristicPrompt,
            config: config,
            userId: userId,
            stationId: station?.id ?? UUID(),
            count: suggestionBatchSize
        )

        log("🧠 Received \(tracks.count) tracks from heuristic pool")

        // Convert ProviderTracks to queue items
        for track in tracks {
            // Skip if already in queue
            if queue.contains(where: { $0.appleMusicId == track.id }) {
                continue
            }

            // Create an LLMSongSuggestion from the provider track
            let suggestion = LLMSongSuggestion(
                title: track.title,
                artist: track.artistName,
                album: track.albumName,
                year: track.releaseDate.flatMap { Int($0.prefix(4)) },
                reason: "From heuristic pool recommendations",
                estimatedBpm: nil,
                estimatedEnergy: nil,
                estimatedValence: nil,
                estimatedDanceability: nil,
                estimatedAcousticness: nil,
                estimatedInstrumentalness: nil,
                verificationStatus: .verified,
                appleMusicId: track.id,
                isrc: track.isrc,
                artworkURL: track.artworkURL?.absoluteString
            )

            var queueItem = LLMQueueItem(suggestion: suggestion)
            queueItem.appleMusicId = track.id
            queueItem.isrc = track.isrc
            queueItem.artworkURL = track.artworkURL
            queueItem.status = .queued
            queue.append(queueItem)

            log("🧠 Added: \(track.title) by \(track.artistName)")
        }
    }

    // MARK: - Direct LLM Song Suggestions (used by local AI and as legacy fallback)

    private func fetchLegacySuggestions(config: LLMStationConfig) async throws {
        log("📝 Using direct LLM song suggestions")

        let request = LLMSongRequest(
            config: config,
            likedSongs: feedbackHistory
                .filter { $0.type == .like }
                .map { LLMSongRequest.LikedSongInfo(title: $0.title, artist: $0.artist) },
            dislikedSongs: feedbackHistory
                .filter { $0.type == .dislike }
                .map { LLMSongRequest.DislikedSongInfo(title: $0.title, artist: $0.artist) },
            recentlyPlayed: queue.filter { $0.status == .played || $0.status == .playing }
                .map { $0.suggestion.title },
            count: suggestionBatchSize
        )

        let suggestions = try await llmService.suggestSongs(request: request)
        log("Received \(suggestions.count) suggestions")

        // Convert to queue items and verify in Apple Music
        for suggestion in suggestions {
            if queue.contains(where: { $0.suggestion.title == suggestion.title && $0.suggestion.artist == suggestion.artist }) {
                continue
            }

            var queueItem = LLMQueueItem(suggestion: suggestion)

            if let (appleMusicId, artworkURL, isrc) = await verifySongInAppleMusic(suggestion) {
                queueItem.appleMusicId = appleMusicId
                queueItem.artworkURL = artworkURL
                queueItem.isrc = isrc
                queueItem.status = .queued
                queue.append(queueItem)
                log("✅ Verified: \(suggestion.title) by \(suggestion.artist)")
            } else {
                log("❌ Not found: \(suggestion.title) by \(suggestion.artist)")
            }
        }
    }

    private func verifySongInAppleMusic(_ suggestion: LLMSongSuggestion) async -> (String, URL?, String?)? {
        do {
            let currentStatus = MusicAuthorization.currentStatus
            guard currentStatus == .authorized else {
                log("Apple Music not authorized (status: \(currentStatus)) - skipping search")
                return nil
            }

            var searchRequest = MusicCatalogSearchRequest(
                term: "\(suggestion.title) \(suggestion.artist)",
                types: [Song.self]
            )
            searchRequest.limit = 5

            let response = try await searchRequest.response()

            let matchingSong = response.songs.first { song in
                song.title.localizedCaseInsensitiveContains(suggestion.title) &&
                song.artistName.localizedCaseInsensitiveContains(suggestion.artist)
            } ?? response.songs.first

            guard let song = matchingSong else {
                return nil
            }

            let artworkURL = song.artwork?.url(width: 300, height: 300)
            return (song.id.rawValue, artworkURL, song.isrc)

        } catch {
            log("Apple Music search error: \(error)")
            return nil
        }
    }

    // MARK: - Playback Control

    /// Play the previous song in queue (if available)
    func playPrevious() async {
        // Find the currently playing item
        guard let currentIndex = queue.firstIndex(where: { $0.status == .playing }) else {
            log("⏮️ No current song playing, cannot go back")
            return
        }

        // Look for the most recent played item before current
        var previousIndex: Int? = nil
        for i in stride(from: currentIndex - 1, through: 0, by: -1) {
            if queue[i].status == .played || queue[i].status == .skipped {
                previousIndex = i
                break
            }
        }

        guard let prevIndex = previousIndex else {
            log("⏮️ No previous song available")
            return
        }

        log("⏮️ Going back to: \(queue[prevIndex].suggestion.title)")

        // Re-queue the previous song
        queue[prevIndex].status = .queued

        // Play it
        await playQueueItem(at: prevIndex)
    }

    /// Play the next song in queue
    func playNext() async {
        // Find next queued song
        guard let nextIndex = queue.firstIndex(where: { $0.status == .queued }) else {
            // Queue empty, try to fetch more
            if !isLoadingSongs {
                statusMessage = "Getting more songs..."
                do {
                    try await fetchSongSuggestions()
                    if let nextIndex = queue.firstIndex(where: { $0.status == .queued }) {
                        await playQueueItem(at: nextIndex)
                    } else {
                        statusMessage = "No more songs available"
                    }
                } catch {
                    errorMessage = "Couldn't get more songs"
                }
            }
            return
        }

        await playQueueItem(at: nextIndex)
    }

    private func playQueueItem(at index: Int) async {
        guard index < queue.count else { return }

        // Find the currently playing item to use as previous (before we change states)
        var previousItemIndex: Int? = queue.firstIndex(where: { $0.status == .playing })

        // If nothing is currently playing, look for the most recent played/skipped item before this index
        if previousItemIndex == nil && index > 0 {
            for i in stride(from: index - 1, through: 0, by: -1) {
                if queue[i].status == .played || queue[i].status == .skipped {
                    previousItemIndex = i
                    break
                }
            }
        }

        // Mark previous as played (if it was playing)
        if let currentIndex = queue.firstIndex(where: { $0.status == .playing }) {
            queue[currentIndex].status = .played
        }

        // Update previousAppleMusicSong from the previous queue item
        if index == 0 {
            // First song in queue - ensure no previous
            previousAppleMusicSong = nil
            log("📀 First song, clearing previous")
        } else if let prevIdx = previousItemIndex, let prevAppleMusicId = queue[prevIdx].appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(prevAppleMusicId))
                let response = try await songRequest.response()
                previousAppleMusicSong = response.items.first
                log("📀 Set previous song to: \(previousAppleMusicSong?.title ?? "nil") from queue[\(prevIdx)]")
            } catch {
                log("📀 Failed to fetch previous song: \(error)")
                previousAppleMusicSong = nil  // Clear on error to avoid stale data
            }
        } else {
            // No valid previous item - clear to avoid showing stale data
            previousAppleMusicSong = nil
            log("📀 No previous item found for index \(index), clearing previous")
        }

        // Update current
        queue[index].status = .playing
        currentQueueItem = queue[index]

        let suggestion = queue[index].suggestion
        statusMessage = "▶️ \(suggestion.title)"
        log("Playing: \(suggestion.title) by \(suggestion.artist)")

        // Build a multi-song queue for SystemMusicPlayer
        var songsForPlayer: [Song] = []

        // Get current song
        if let appleMusicId = queue[index].appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleMusicId))
                let response = try await songRequest.response()

                if let song = response.items.first {
                    currentSong = song
                    songsForPlayer.append(song)
                    station?.addToRecentlyPlayed(queue[index].isrc ?? suggestion.title)
                }
            } catch {
                log("Playback error: \(error)")
                queue[index].status = .failed(error.localizedDescription)
                await playNext()
                return
            }
        }

        // Get next songs to pre-queue
        let upcomingItems = queue.dropFirst(index + 1)
            .filter { $0.status == .queued }
            .prefix(playerQueueSize - 1)

        for item in upcomingItems {
            if let appleMusicId = item.appleMusicId {
                do {
                    let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleMusicId))
                    let response = try await songRequest.response()
                    if let song = response.items.first {
                        songsForPlayer.append(song)
                        log("📀 Pre-queued: \(song.title)")
                    }
                } catch {
                    log("Failed to fetch upcoming song: \(error)")
                }
            }
        }

        // Set up the player queue with multiple songs
        if !songsForPlayer.isEmpty {
            let player = SystemMusicPlayer.shared

            // Clear tracking of what's in player queue since we're resetting it
            songsAddedToPlayerQueue.removeAll()

            // Track all songs being added to player queue
            for song in songsForPlayer {
                songsAddedToPlayerQueue.insert(song.id.rawValue)
            }

            player.queue = SystemMusicPlayer.Queue(for: songsForPlayer)

            // Disable repeat mode so queue doesn't loop
            player.state.repeatMode = .none

            do {
                try await player.play()
                log("▶️ Started playback with \(songsForPlayer.count) songs in queue")

                // Reconfigure remote commands after playback starts
                // SystemMusicPlayer may override handlers when queue changes
                configureRemoteCommands()
            } catch {
                log("Playback error: \(error)")
            }
        }

        // Update nextAppleMusicSong for UI display - use queue as source of truth
        let nextQueuedItem = queue.dropFirst(index + 1).first(where: { $0.status == .queued })
        if let nextItem = nextQueuedItem, let nextAppleMusicId = nextItem.appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(nextAppleMusicId))
                let response = try await songRequest.response()
                nextAppleMusicSong = response.items.first
                log("📀 Set next song to: \(nextAppleMusicSong?.title ?? "nil")")
            } catch {
                nextAppleMusicSong = nil
                log("📀 Failed to fetch next song: \(error)")
            }
        } else {
            nextAppleMusicSong = nil
            log("📀 No next queued item available")
        }

        // Check if we need more songs in our internal queue
        let queuedCount = queue.filter { $0.status == .queued }.count
        if queuedCount < queueLowThreshold && !isLoadingSongs {
            Task {
                try? await fetchSongSuggestions()
            }
        }
    }

    /// Stop the station
    func stopStation() {
        guard isStationActive else { return }

        // Save state before stopping
        saveStationState()

        isStationActive = false
        currentSong = nil
        previousAppleMusicSong = nil
        nextAppleMusicSong = nil
        currentQueueItem = nil
        statusMessage = ""
        songsAddedToPlayerQueue.removeAll()

        playbackObserverTask?.cancel()
        playbackObserverTask = nil

        // Clear remote command handlers
        RemoteCommandManager.shared.clearHandlers()

        SystemMusicPlayer.shared.stop()
        log("Station stopped")
    }

    // MARK: - Remote Command Center

    private func configureRemoteCommands() {
        RemoteCommandManager.shared.updateHandlers(
            onNext: { [weak self] in
                print("🎛️ LLMStation: Remote next track command received")
                await self?.playNext()
            },
            onPrevious: { [weak self] in
                print("🎛️ LLMStation: Remote previous track command received")
                await self?.playPrevious()
            },
            onLike: { [weak self] in
                print("🎛️ LLMStation: Remote like command received")
                self?.like()
            },
            onDislike: { [weak self] in
                print("🎛️ LLMStation: Remote dislike command received")
                self?.dislike()
            }
        )
        log("Remote commands configured for LLM station")
    }

    // MARK: - Feedback

    func like() {
        guard let item = currentQueueItem else { return }

        recordFeedback(for: item, type: .like)
        likeCount += 1
        log("👍 Liked: \(item.suggestion.title)")
    }

    func dislike() {
        guard let item = currentQueueItem else { return }

        recordFeedback(for: item, type: .dislike)
        dislikeCount += 1
        log("👎 Disliked: \(item.suggestion.title)")

        // Auto-skip on dislike
        Task {
            await playNext()
        }
    }

    func skip() {
        guard let item = currentQueueItem else { return }

        // Mark as skipped
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            queue[index].status = .skipped
        }

        recordFeedback(for: item, type: .skip)
        skipCount += 1
        log("⏭️ Skipped: \(item.suggestion.title)")

        Task {
            await playNext()
        }
    }

    private func recordFeedback(for item: LLMQueueItem, type: FeedbackType) {
        let record = FeedbackRecord(
            title: item.suggestion.title,
            artist: item.suggestion.artist,
            type: type,
            estimatedFeatures: item.suggestion.toEstimatedFeatures()
        )
        feedbackHistory.append(record)

        // Persist to SwiftData (local)
        if let context = modelContext, let station = station {
            let feedback = Feedback(
                stationId: station.id,
                trackISRC: item.isrc ?? item.suggestion.title,
                feedbackType: type,
                trackTitle: item.suggestion.title,
                trackArtist: item.suggestion.artist,
                trackFeatures: item.suggestion.toEstimatedFeatures()
            )
            context.insert(feedback)
            try? context.save()
        }

        // Persist to Supabase (for artist-seeded recommendations)
        if let userId = authManager?.currentUser?.id,
           let artistService = artistSeedService {
            let providerFeedbackType: ProviderFeedbackType
            switch type {
            case .like:
                providerFeedbackType = .like
            case .dislike:
                providerFeedbackType = .dislike
            case .skip:
                providerFeedbackType = .skip
            case .listenThrough:
                providerFeedbackType = .listenThrough
            }

            let feedbackRecord = TrackFeedbackRecord(
                userId: userId,
                appleMusicId: item.appleMusicId,
                isrc: item.isrc,
                trackTitle: item.suggestion.title,
                artistName: item.suggestion.artist,
                albumName: item.suggestion.album,
                feedbackType: providerFeedbackType,
                stationId: station?.id,
                playedAt: Date(),
                feedbackAt: Date()
            )

            Task {
                do {
                    try await artistService.recordFeedback(feedbackRecord)
                    log("📤 Feedback synced to Supabase")
                } catch {
                    log("⚠️ Failed to sync feedback to Supabase: \(error.localizedDescription)")
                }
            }
        }

        // Maybe update taste profile
        maybeUpdateTasteProfile()
    }

    private func maybeUpdateTasteProfile() {
        // Update every 10 feedback items
        let totalFeedback = likeCount + dislikeCount
        guard totalFeedback > 0 && totalFeedback % 10 == 0 else { return }

        Task {
            await updateTasteProfile()
        }
    }

    private func updateTasteProfile() async {
        guard let config = stationConfig else { return }

        let summary = StationFeedbackSummary(
            totalLikes: likeCount,
            totalDislikes: dislikeCount,
            totalSkips: skipCount,
            likedSongs: feedbackHistory
                .filter { $0.type == .like }
                .map { StationFeedbackSummary.SongInfo(title: $0.title, artist: $0.artist, genre: nil) },
            dislikedSongs: feedbackHistory
                .filter { $0.type == .dislike }
                .map { StationFeedbackSummary.SongInfo(title: $0.title, artist: $0.artist, genre: nil) }
        )

        do {
            let newProfile = try await llmService.analyzeTaste(
                originalPrompt: config.originalPrompt,
                currentProfile: tasteProfile,
                feedbackSummary: summary
            )
            tasteProfile = newProfile
            station?.llmTasteProfile = newProfile
            log("Updated taste profile")
        } catch {
            log("Failed to update taste profile: \(error)")
        }
    }

    // MARK: - Playback Observer

    private func startPlaybackObserver() {
        playbackObserverTask?.cancel()

        playbackObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let player = SystemMusicPlayer.shared
            let mpPlayer = MPMusicPlayerController.systemMusicPlayer
            var lastItemId: String?
            var cycleCount = 0

            log("👀 Playback observer starting...")

            while !Task.isCancelled && self.isStationActive {
                cycleCount += 1

                // Try multiple methods to get the current playing song ID
                var currentId: String?
                var currentTitle: String?

                // Method 1: MPMusicPlayerController.nowPlayingItem (most reliable for external skips)
                if let nowPlaying = mpPlayer.nowPlayingItem,
                   let persistentID = nowPlaying.playbackStoreID as String? {
                    currentId = persistentID
                    currentTitle = nowPlaying.title
                }

                // Method 2: Fallback to SystemMusicPlayer.queue.currentEntry
                if currentId == nil {
                    let currentEntry = player.queue.currentEntry
                    if let song = currentEntry?.item as? Song {
                        currentId = song.id.rawValue
                        currentTitle = song.title
                    }
                }

                // Log every 20 cycles (10 seconds) to show observer is running
                if cycleCount % 20 == 0 {
                    log("👀 Observer alive - nowPlaying: \(currentTitle ?? "nil"), lastId: \(lastItemId ?? "nil")")
                }

                // Proactively refill player queue on every cycle to prevent looping
                await self.refillPlayerQueue()

                // Detect song change (user skipped or song ended)
                if let currentId = currentId, currentId != lastItemId {
                    if lastItemId != nil {
                        log("🔄 Song changed! From: \(lastItemId ?? "nil") To: \(currentId)")
                        log("🔄 New song title: \(currentTitle ?? "Unknown")")

                        // Sync our internal state with what's actually playing
                        await self.syncInternalStateWithPlayer(currentSongId: currentId)
                    } else {
                        log("👀 Observer started, tracking: \(currentTitle ?? "Unknown") (id: \(currentId))")
                    }
                    lastItemId = currentId
                }

                // Detect when playback stops (queue exhausted)
                if player.state.playbackStatus == .stopped && lastItemId != nil {
                    log("⏹ Playback stopped, refilling queue...")
                    await self.playNext()
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
            log("👀 Playback observer ended")
        }
    }

    /// Sync our internal queue state with what SystemMusicPlayer is actually playing
    private func syncInternalStateWithPlayer(currentSongId: String) async {
        log("🔄 syncInternalStateWithPlayer called with songId: \(currentSongId)")

        // Find the queue item matching the currently playing song
        guard let playingIndex = queue.firstIndex(where: { $0.appleMusicId == currentSongId }) else {
            log("⚠️ Playing song not found in queue (id: \(currentSongId))")
            return
        }

        log("🔄 Found song at queue index \(playingIndex)")

        // Find the actual previous song from queue (the one that was playing before)
        // Look for the most recent played/playing/skipped item before the new playing index
        var previousIndex: Int? = nil
        for i in stride(from: playingIndex - 1, through: 0, by: -1) {
            let status = queue[i].status
            if status == .playing || status == .played || status == .skipped {
                previousIndex = i
                break
            }
        }

        // If no played/skipped item found but there are items before us, use the immediately previous one
        if previousIndex == nil && playingIndex > 0 {
            previousIndex = playingIndex - 1
            log("🔄 No played item found, using index \(playingIndex - 1) as previous")
        }

        // Mark all items before the current as played
        for i in 0..<playingIndex {
            if queue[i].status == .playing || queue[i].status == .queued {
                queue[i].status = .played
            }
        }

        // Update previous song from the queue (not from currentSong state which may be stale/wrong)
        if playingIndex == 0 {
            // First song in queue - no previous
            previousAppleMusicSong = nil
            log("🔄 First song in queue, no previous")
        } else if let prevIdx = previousIndex, let prevAppleMusicId = queue[prevIdx].appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(prevAppleMusicId))
                let response = try await songRequest.response()
                previousAppleMusicSong = response.items.first
                log("🔄 Set previousAppleMusicSong to: \(previousAppleMusicSong?.title ?? "nil") from queue index \(prevIdx)")
            } catch {
                log("🔄 Failed to fetch previous song: \(error)")
                previousAppleMusicSong = nil  // Clear on error to avoid stale data
            }
        } else {
            // No valid previous - clear to avoid stale data
            previousAppleMusicSong = nil
            log("🔄 No previous song available for playingIndex \(playingIndex), clearing")
        }

        // Update current
        queue[playingIndex].status = .playing
        currentQueueItem = queue[playingIndex]
        log("🔄 Updated currentQueueItem to: \(queue[playingIndex].suggestion.title)")

        // Fetch the Song object for UI
        if let appleMusicId = queue[playingIndex].appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleMusicId))
                let response = try await songRequest.response()
                let newSong = response.items.first
                log("🔄 Fetched Song from Apple Music: \(newSong?.title ?? "nil")")
                currentSong = newSong
                log("🔄 currentSong updated to: \(currentSong?.title ?? "nil")")
            } catch {
                log("Failed to fetch current song: \(error)")
            }
        }

        let suggestion = queue[playingIndex].suggestion
        statusMessage = "▶️ \(suggestion.title)"
        log("Synced to: \(suggestion.title) by \(suggestion.artist)")

        // Update next song preview
        let nextQueuedItem = queue.dropFirst(playingIndex + 1).first(where: { $0.status == .queued })
        if let nextItem = nextQueuedItem, let nextAppleMusicId = nextItem.appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(nextAppleMusicId))
                let response = try await songRequest.response()
                nextAppleMusicSong = response.items.first
            } catch {
                nextAppleMusicSong = nil
            }
        } else {
            nextAppleMusicSong = nil
        }

        // Track as recently played
        station?.addToRecentlyPlayed(queue[playingIndex].isrc ?? suggestion.title)
    }

    /// Add more songs to SystemMusicPlayer's queue when it runs low
    private func refillPlayerQueue() async {
        let player = SystemMusicPlayer.shared

        // Ensure repeat mode stays off (check every time)
        if player.state.repeatMode != .none {
            player.state.repeatMode = .none
            log("🔄 Disabled repeat mode")
        }

        // Find current playing index
        guard let currentIndex = queue.firstIndex(where: { $0.status == .playing }) else { return }

        // Get upcoming items that haven't been added to player queue yet
        let upcomingInternalItems = queue.dropFirst(currentIndex + 1)
            .filter { $0.status == .queued }
            .filter { item in
                // Only include items NOT already in the player queue
                guard let appleMusicId = item.appleMusicId else { return false }
                return !songsAddedToPlayerQueue.contains(appleMusicId)
            }

        // Always try to add the next available song if we have one
        if let nextItem = upcomingInternalItems.first, let appleMusicId = nextItem.appleMusicId {
            do {
                let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleMusicId))
                let response = try await songRequest.response()
                if let song = response.items.first {
                    try await player.queue.insert(song, position: .tail)
                    songsAddedToPlayerQueue.insert(appleMusicId)
                    log("➕ Added to player queue: \(song.title)")
                }
            } catch {
                log("Failed to add song to queue: \(error)")
            }
        }

        // Fetch more suggestions if our internal queue is running low
        let queuedCount = queue.filter { $0.status == .queued }.count
        if queuedCount < queueLowThreshold && !isLoadingSongs {
            Task {
                try? await fetchSongSuggestions()
            }
        }
    }

    // MARK: - Persistence

    private func saveStationState() {
        guard let station = station else { return }

        station.lastPlayedAt = Date()
        station.llmTasteProfile = tasteProfile

        if let context = modelContext {
            try? context.save()
        }
    }

    private func loadFeedbackHistory() {
        guard let context = modelContext, let station = station else { return }

        let stationId = station.id
        let predicate = #Predicate<Feedback> { feedback in
            feedback.stationId == stationId
        }
        let descriptor = FetchDescriptor<Feedback>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        do {
            let feedbacks = try context.fetch(descriptor)
            feedbackHistory = feedbacks.map { feedback in
                FeedbackRecord(
                    title: feedback.trackTitle ?? "",
                    artist: feedback.trackArtist ?? "",
                    type: feedback.feedbackType,
                    estimatedFeatures: feedback.trackFeatures
                )
            }
        } catch {
            log("Failed to load feedback history: \(error)")
        }
    }

    // MARK: - Helpers

    private func stationTypeFromCategory(_ category: StationCategory) -> StationType {
        switch category {
        case .mood:
            return .mood
        case .activity:
            return .fitness
        case .genre:
            return .genreSeed
        case .decade:
            return .decadeSeed
        case .custom:
            return .llmGenerated
        }
    }

    // MARK: - Manual Actions

    /// Manually request more song suggestions
    func requestMoreSongs() async {
        guard !isLoadingSongs else { return }

        statusMessage = "Getting more songs..."
        do {
            try await fetchSongSuggestions()
            statusMessage = "Found \(queue.filter { $0.status == .queued }.count) songs"
        } catch {
            errorMessage = "Couldn't get more songs"
        }
    }

    /// Reset the station (clear feedback, start fresh)
    func resetStation() async {
        feedbackHistory = []
        likeCount = 0
        dislikeCount = 0
        skipCount = 0
        tasteProfile = .empty
        queue = []

        station?.thompsonParameters.reset()
        station?.llmTasteProfile = nil

        if let context = modelContext {
            try? context.save()
        }

        // Fetch fresh suggestions
        do {
            try await fetchSongSuggestions()
            if !queue.isEmpty {
                await playNext()
            }
        } catch {
            errorMessage = "Failed to reset station"
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        debugLog.insert(entry, at: 0)
        if debugLog.count > 100 {
            debugLog = Array(debugLog.prefix(100))
        }
        print("🎵 LLMStation: \(message)")
    }

    // MARK: - Future Thompson Sampling Hooks

    /// Placeholder for Thompson Sampling parameter updates
    /// Will be implemented when adding Thompson Sampling
    private func updateThompsonParameters(for suggestion: LLMSongSuggestion, feedback: FeedbackType) {
        guard var params = station?.thompsonParameters else { return }

        let features = suggestion.toEstimatedFeatures()

        switch feedback {
        case .like:
            params.update(for: features, liked: true)
        case .dislike:
            params.update(for: features, liked: false)
        case .skip:
            params.update(for: features, liked: false)
        case .listenThrough:
            params.update(for: features, liked: true)
        }

        station?.thompsonParameters = params
    }
}

// MARK: - Supporting Types

/// Internal feedback record
private struct FeedbackRecord {
    let title: String
    let artist: String
    let type: FeedbackType
    let estimatedFeatures: TrackFeatures?
}

// MARK: - Station Extension for LLM Data
extension Station {

    /// Original natural language prompt
    var originalPrompt: String? {
        get {
            // Store in seedMood field for now (reusing existing field)
            // In production, add a dedicated field
            if type == .llmGenerated {
                return seedMood
            }
            return nil
        }
        set {
            if type == .llmGenerated {
                seedMood = newValue
            }
        }
    }

    /// LLM-generated station configuration
    var llmStationConfig: LLMStationConfig? {
        get {
            guard let data = llmConfigData else { return nil }
            return try? JSONDecoder().decode(LLMStationConfig.self, from: data)
        }
        set {
            llmConfigData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Learned taste profile
    var llmTasteProfile: LLMTasteProfile? {
        get {
            guard let data = llmTasteProfileData else { return nil }
            return try? JSONDecoder().decode(LLMTasteProfile.self, from: data)
        }
        set {
            llmTasteProfileData = try? JSONEncoder().encode(newValue)
        }
    }
}
