//
//  ArtistSeedService.swift
//  Curate
//
//  Main orchestrator for artist-seeded recommendations.
//  Coordinates LLM seed generation, Apple Music fetching, and local filtering.
//

import Foundation

// MARK: - Artist Seed Service

final class ArtistSeedService: ArtistSeedServiceProtocol {

    // MARK: - Dependencies

    private let seedGenerator: ArtistSeedGeneratorProtocol
    private let musicProvider: MusicProviderProtocol
    private let feedbackRepository: FeedbackRepositoryProtocol
    private let artistCache: ArtistCacheRepositoryProtocol
    private let seedCache: SeedCacheRepositoryProtocol
    private let trackFilter: TrackFilterProtocol

    // MARK: - Configuration

    private let defaultSeedCount = 5
    private let tracksPerArtist = 10
    private let recencyWindowDays = 45
    private let maxTracksPerArtist = 2

    // MARK: - Initialization

    init(
        seedGenerator: ArtistSeedGeneratorProtocol,
        musicProvider: MusicProviderProtocol,
        feedbackRepository: FeedbackRepositoryProtocol,
        artistCache: ArtistCacheRepositoryProtocol,
        seedCache: SeedCacheRepositoryProtocol,
        trackFilter: TrackFilterProtocol
    ) {
        self.seedGenerator = seedGenerator
        self.musicProvider = musicProvider
        self.feedbackRepository = feedbackRepository
        self.artistCache = artistCache
        self.seedCache = seedCache
        self.trackFilter = trackFilter
    }

    /// Convenience initializer with default implementations
    convenience init() {
        self.init(
            seedGenerator: BackendArtistSeedGenerator(),
            musicProvider: AppleMusicProvider(),
            feedbackRepository: FeedbackRepository(),
            artistCache: ArtistCacheRepository(),
            seedCache: SeedCacheRepository(),
            trackFilter: TrackFilter()
        )
    }

    // MARK: - Get Recommended Tracks

    func getRecommendedTracks(
        config: LLMStationConfig,
        userId: UUID,
        count: Int,
        preferences: UserPreferences
    ) async throws -> [ProviderTrack] {
        print("🎵 ArtistSeedService: Getting \(count) tracks for station '\(config.name)' (temp: \(preferences.temperature))")

        // Step 1: Fetch artist scores (for filtering and avoid list)
        let artistScores = try await feedbackRepository.getArtistScores(userId: userId)
        let artistScoresDict = Dictionary(
            artistScores.map { ($0.artistName.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        print("📊 Loaded \(artistScores.count) artist scores")

        // Build avoid list from disliked artists
        let avoidArtists = artistScores
            .filter { $0.shouldAvoid }
            .map { $0.artistName }
        print("🚫 Avoiding \(avoidArtists.count) disliked artists")

        // Step 2: Get artist seeds (from cache or LLM)
        let seeds = try await getArtistSeeds(
            config: config,
            userId: userId,
            avoidArtists: avoidArtists,
            artistScores: artistScoresDict,
            temperature: preferences.temperature,
            preferredGenres: preferences.preferredGenres,
            nonPreferredGenres: preferences.nonPreferredGenres
        )
        print("🌱 Got \(seeds.count) artist seeds: \(seeds.map { $0.name }.joined(separator: ", "))")

        // Step 3: Resolve artists to provider IDs
        let resolvedArtists = try await musicProvider.resolveArtists(seeds.map { $0.name })
        print("✅ Resolved \(resolvedArtists.count) artists in Apple Music")

        // Step 4: Fetch top tracks (from cache or API)
        var allTracks: [ProviderTrack] = []
        for artist in resolvedArtists {
            let tracks = try await getTopTracks(for: artist)
            allTracks.append(contentsOf: tracks)
        }
        print("🎶 Fetched \(allTracks.count) total tracks")

        // Step 5: Build filter context
        let recentlyPlayedISRCs = try await feedbackRepository.getRecentlyPlayedISRCs(
            userId: userId,
            days: recencyWindowDays
        )
        let recentlyPlayedIds = try await feedbackRepository.getRecentlyPlayedTrackIds(
            userId: userId,
            days: recencyWindowDays
        )

        let filterContext = TrackFilterContext(
            recentlyPlayedISRCs: Set(recentlyPlayedISRCs),
            recentlyPlayedIds: Set(recentlyPlayedIds),
            artistScores: artistScoresDict,
            maxTracksPerArtist: maxTracksPerArtist,
            recencyWindowDays: recencyWindowDays,
            stationId: nil
        )

        // Step 6: Filter and return
        let filteredTracks = trackFilter.filter(
            tracks: allTracks,
            context: filterContext,
            targetCount: count
        )
        print("🎯 Returning \(filteredTracks.count) filtered tracks")

        return filteredTracks
    }

    // MARK: - Record Feedback

    func recordFeedback(_ feedback: TrackFeedbackRecord) async throws {
        try await feedbackRepository.recordFeedback(feedback)
        print("💬 Recorded \(feedback.feedbackType.rawValue) feedback for '\(feedback.trackTitle)'")
    }

    // MARK: - Invalidate Caches

    func invalidateCaches(for userId: UUID) async throws {
        try await seedCache.invalidateUserCache(userId: userId)
        print("🗑️ Invalidated caches for user \(userId)")
    }

    // MARK: - Private: Get Artist Seeds

    private func getArtistSeeds(
        config: LLMStationConfig,
        userId: UUID,
        avoidArtists: [String],
        artistScores: [String: ArtistScore],
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) async throws -> [ArtistSeed] {
        let configHash = config.configHash
        let tasteHash = buildTasteHash(from: artistScores, preferredGenres: preferredGenres, temperature: temperature)

        // Check cache first
        if let cachedSeeds = try await seedCache.getCachedSeeds(
            userId: userId,
            configHash: configHash,
            tasteHash: tasteHash
        ) {
            print("📦 Using cached artist seeds")
            return cachedSeeds
        }

        // Generate new seeds from LLM
        let tasteSummary = buildTasteSummary(from: artistScores)
        let seeds = try await seedGenerator.generateSeeds(
            for: config,
            tasteSummary: tasteSummary,
            avoidArtists: avoidArtists,
            count: defaultSeedCount,
            temperature: temperature,
            preferredGenres: preferredGenres,
            nonPreferredGenres: nonPreferredGenres
        )

        // Cache the seeds
        try await seedCache.cacheSeeds(
            userId: userId,
            configHash: configHash,
            tasteHash: tasteHash,
            seeds: seeds
        )

        return seeds
    }

    // MARK: - Private: Get Top Tracks

    private func getTopTracks(for artist: ResolvedArtist) async throws -> [ProviderTrack] {
        // Check cache first
        if let cached = try await artistCache.getCachedArtist(canonicalId: artist.id) {
            // Fetch tracks by cached IDs
            let tracks = try await musicProvider.fetchTracks(byIds: cached.topTrackIds)
            if !tracks.isEmpty {
                print("📦 Using cached tracks for \(artist.name)")
                return tracks
            }
        }

        // Fetch from provider
        let tracks = try await musicProvider.fetchTopTracks(for: artist, limit: tracksPerArtist)

        // Cache the result
        if !tracks.isEmpty {
            try await artistCache.cacheArtist(artist, topTrackIds: tracks.map { $0.id })
        }

        return tracks
    }

    // MARK: - Private: Build Taste Summary

    private func buildTasteSummary(from artistScores: [String: ArtistScore]) -> String {
        let preferredArtists = artistScores.values
            .filter { $0.isPreferred }
            .sorted { $0.weightedScore > $1.weightedScore }
            .prefix(10)
            .map { $0.artistName }

        let avoidedArtists = artistScores.values
            .filter { $0.shouldAvoid }
            .prefix(5)
            .map { $0.artistName }

        var summary = ""

        if !preferredArtists.isEmpty {
            summary += "Preferred artists: \(preferredArtists.joined(separator: ", ")). "
        }

        if !avoidedArtists.isEmpty {
            summary += "Avoided artists: \(avoidedArtists.joined(separator: ", ")). "
        }

        if summary.isEmpty {
            summary = "No significant listening history yet."
        }

        return summary
    }

    // MARK: - Private: Build Taste Hash

    private func buildTasteHash(
        from artistScores: [String: ArtistScore],
        preferredGenres: [String],
        temperature: Double
    ) -> String {
        // Create a hash from the top preferred and avoided artists
        let preferred = artistScores.values
            .filter { $0.isPreferred }
            .sorted { $0.artistName < $1.artistName }
            .prefix(10)
            .map { $0.artistName }

        let avoided = artistScores.values
            .filter { $0.shouldAvoid }
            .sorted { $0.artistName < $1.artistName }
            .prefix(5)
            .map { $0.artistName }

        // Include genres and temperature in hash so cache invalidates when preferences change
        let tempBucket = temperature < 0.3 ? "low" : (temperature < 0.7 ? "mid" : "high")
        let genresSorted = preferredGenres.sorted().joined(separator: ",")

        let combined = "p:\(preferred.joined(separator: ","))|a:\(avoided.joined(separator: ","))|g:\(genresSorted)|t:\(tempBucket)"
        return combined.sha256Hash
    }
}

// MARK: - Backend Artist Seed Generator

/// Generates artist seeds via Supabase Edge Function
final class BackendArtistSeedGenerator: ArtistSeedGeneratorProtocol {
    private let supabase = SupabaseConfig.client

    func generateSeeds(
        for config: LLMStationConfig,
        tasteSummary: String,
        avoidArtists: [String],
        count: Int,
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) async throws -> [ArtistSeed] {
        print("🤖 Calling generate-artist-seeds Edge Function (temp: \(temperature), genres: \(preferredGenres.count) preferred)")

        // Build request payload
        let requestBody = GenerateArtistSeedsRequest(
            config: config,
            tasteSummary: tasteSummary.isEmpty ? nil : tasteSummary,
            avoidArtists: avoidArtists.isEmpty ? nil : avoidArtists,
            count: count,
            temperature: temperature,
            preferredGenres: preferredGenres,
            nonPreferredGenres: nonPreferredGenres
        )

        // Call Edge Function with JWT - Supabase SDK directly decodes the response
        let result: GenerateArtistSeedsResponse = try await supabase.functions.invoke(
            "generate-artist-seeds",
            options: FunctionInvokeOptions(body: requestBody)
        )

        return result.seeds
    }
}

// MARK: - Request/Response Types

private struct GenerateArtistSeedsRequest: Encodable {
    let config: ConfigPayload
    let tasteSummary: String?
    let avoidArtists: [String]?
    let count: Int
    let temperature: Double
    let preferredGenres: [String]?
    let nonPreferredGenres: [String]?

    init(
        config: LLMStationConfig,
        tasteSummary: String?,
        avoidArtists: [String]?,
        count: Int,
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) {
        self.config = ConfigPayload(from: config)
        self.tasteSummary = tasteSummary
        self.avoidArtists = avoidArtists
        self.count = count
        self.temperature = temperature
        self.preferredGenres = preferredGenres.isEmpty ? nil : preferredGenres
        self.nonPreferredGenres = nonPreferredGenres.isEmpty ? nil : nonPreferredGenres
    }

    struct ConfigPayload: Encodable {
        let name: String
        let description: String
        let originalPrompt: String
        let contextDescription: String
        let suggestedGenres: [String]
        let suggestedDecades: [Int]?
        let moodKeywords: [String]
        let valenceRange: FeatureRangePayload?
        let energyRange: FeatureRangePayload?
        let danceabilityRange: FeatureRangePayload?
        let bpmRange: FeatureRangePayload?
        let acousticnessRange: FeatureRangePayload?
        let instrumentalnessRange: FeatureRangePayload?
        let valenceWeight: Float
        let energyWeight: Float
        let danceabilityWeight: Float
        let bpmWeight: Float
        let acousticnessWeight: Float
        let instrumentalnessWeight: Float

        init(from config: LLMStationConfig) {
            self.name = config.name
            self.description = config.description
            self.originalPrompt = config.originalPrompt
            self.contextDescription = config.contextDescription
            self.suggestedGenres = config.suggestedGenres
            self.suggestedDecades = config.suggestedDecades
            self.moodKeywords = config.moodKeywords
            self.valenceRange = config.valenceRange.map { FeatureRangePayload(min: $0.min, max: $0.max) }
            self.energyRange = config.energyRange.map { FeatureRangePayload(min: $0.min, max: $0.max) }
            self.danceabilityRange = config.danceabilityRange.map { FeatureRangePayload(min: $0.min, max: $0.max) }
            self.bpmRange = config.bpmRange.map { FeatureRangePayload(min: $0.min, max: $0.max) }
            self.acousticnessRange = config.acousticnessRange.map { FeatureRangePayload(min: $0.min, max: $0.max) }
            self.instrumentalnessRange = config.instrumentalnessRange.map { FeatureRangePayload(min: $0.min, max: $0.max) }
            self.valenceWeight = config.valenceWeight
            self.energyWeight = config.energyWeight
            self.danceabilityWeight = config.danceabilityWeight
            self.bpmWeight = config.bpmWeight
            self.acousticnessWeight = config.acousticnessWeight
            self.instrumentalnessWeight = config.instrumentalnessWeight
        }
    }

    struct FeatureRangePayload: Encodable {
        let min: Float
        let max: Float
    }
}

private struct GenerateArtistSeedsResponse: Decodable {
    let seeds: [ArtistSeed]
}

// MARK: - Supabase Import

import Supabase
