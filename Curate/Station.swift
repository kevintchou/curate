//
//  Station.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation
import SwiftData

// MARK: - Station Type
enum StationType: String, Codable, CaseIterable {
    case songSeed = "song_seed"
    case artistSeed = "artist_seed"
    case genreSeed = "genre_seed"
    case decadeSeed = "decade_seed"
    case mood = "mood"
    case fitness = "fitness"
    case llmGenerated = "llm_generated"  // NEW: LLM-generated station
}

// MARK: - Station Model (SwiftData for local persistence)
@Model
final class Station {
    var id: UUID
    var name: String
    var stationType: String  // StationType raw value
    
    // Seed information
    var seedTrackISRC: String?
    var seedTrackTitle: String?
    var seedTrackArtist: String?
    var seedGenre: String?
    var seedDecade: Int?
    var seedMood: String?  // Also used as originalPrompt for LLM stations
    var seedActivity: String?
    
    // Thompson Sampling learned parameters (stored as JSON)
    var thompsonParametersData: Data?
    
    // User settings
    var temperature: Float  // 0.0 = exploit only, 1.0 = max exploration
    var bpmMin: Float?
    var bpmMax: Float?
    var energyMin: Float?
    var energyMax: Float?
    
    // Filters (stored as comma-separated strings for SwiftData compatibility)
    var genreFilterString: String?
    var decadeFilterString: String?
    
    // Timestamps
    var createdAt: Date
    var lastPlayedAt: Date
    
    // Play history (ISRCs of recently played tracks to avoid repeats)
    var recentlyPlayedISRCs: String  // Comma-separated, last 50 tracks
    
    // MARK: - NEW: LLM Station Fields
    
    /// LLM-generated configuration (JSON data)
    var llmConfigData: Data?
    
    /// Learned taste profile from feedback (JSON data)
    var llmTasteProfileData: Data?
    
    /// Cached song suggestions from LLM (JSON data)
    var llmSuggestionsData: Data?
    
    /// When LLM suggestions were last refreshed
    var llmLastRefreshAt: Date?

    /// Station description (can be updated as station evolves)
    var stationDescription: String?

    // MARK: - Hybrid Candidate Pool Fields

    /// The canonical intent this station maps to (for pool lookup)
    var canonicalIntent: String?

    /// Whether this station uses the hybrid pool system (vs legacy artist seeds)
    var usesHybridPool: Bool

    /// Station policy overrides (JSON data)
    var policyOverridesData: Data?
    
    init(
        id: UUID = UUID(),
        name: String,
        stationType: StationType,
        seedTrackISRC: String? = nil,
        seedTrackTitle: String? = nil,
        seedTrackArtist: String? = nil,
        seedGenre: String? = nil,
        seedDecade: Int? = nil,
        seedMood: String? = nil,
        seedActivity: String? = nil,
        temperature: Float = 0.5,
        bpmMin: Float? = nil,
        bpmMax: Float? = nil,
        energyMin: Float? = nil,
        energyMax: Float? = nil,
        genreFilter: [String]? = nil,
        decadeFilter: [Int]? = nil
    ) {
        self.id = id
        self.name = name
        self.stationType = stationType.rawValue
        self.seedTrackISRC = seedTrackISRC
        self.seedTrackTitle = seedTrackTitle
        self.seedTrackArtist = seedTrackArtist
        self.seedGenre = seedGenre
        self.seedDecade = seedDecade
        self.seedMood = seedMood
        self.seedActivity = seedActivity
        self.temperature = temperature
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.energyMin = energyMin
        self.energyMax = energyMax
        self.genreFilterString = genreFilter?.joined(separator: ",")
        self.decadeFilterString = decadeFilter?.map { String($0) }.joined(separator: ",")
        self.createdAt = Date()
        self.lastPlayedAt = Date()
        self.recentlyPlayedISRCs = ""
        self.thompsonParametersData = try? JSONEncoder().encode(ThompsonParameters())
        
        // LLM fields initialized to nil
        self.llmConfigData = nil
        self.llmTasteProfileData = nil
        self.llmSuggestionsData = nil
        self.llmLastRefreshAt = nil
        self.stationDescription = nil

        // Hybrid pool fields
        self.canonicalIntent = nil
        self.usesHybridPool = true  // Default to new system
        self.policyOverridesData = nil
    }
    
    // MARK: - Computed Properties
    
    var type: StationType {
        StationType(rawValue: stationType) ?? .songSeed
    }
    
    var genreFilter: [String]? {
        get { genreFilterString?.split(separator: ",").map { String($0) } }
        set { genreFilterString = newValue?.joined(separator: ",") }
    }
    
    var decadeFilter: [Int]? {
        get { decadeFilterString?.split(separator: ",").compactMap { Int($0) } }
        set { decadeFilterString = newValue?.map { String($0) }.joined(separator: ",") }
    }
    
    var thompsonParameters: ThompsonParameters {
        get {
            guard let data = thompsonParametersData,
                  let params = try? JSONDecoder().decode(ThompsonParameters.self, from: data) else {
                return ThompsonParameters()
            }
            return params
        }
        set {
            thompsonParametersData = try? JSONEncoder().encode(newValue)
        }
    }
    
    var recentlyPlayed: [String] {
        get { recentlyPlayedISRCs.split(separator: ",").map { String($0) } }
        set {
            // Keep only last 50
            let trimmed = Array(newValue.suffix(50))
            recentlyPlayedISRCs = trimmed.joined(separator: ",")
        }
    }
    
    // MARK: - NEW: LLM Computed Properties
    
    /// Whether this is an LLM-generated station
    var isLLMStation: Bool {
        type == .llmGenerated
    }
    
    /// Station policy overrides (merged with defaults at runtime)
    var policyOverrides: StationPolicy? {
        get {
            guard let data = policyOverridesData else { return nil }
            return try? JSONDecoder().decode(StationPolicy.self, from: data)
        }
        set {
            policyOverridesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Get the effective policy for this station
    func effectivePolicy(searchPlan: SearchPlan? = nil) -> StationPolicy {
        var policy = StationPolicy.default

        // Apply search plan suggestions if available
        if let searchPlan = searchPlan {
            policy = policy.merged(with: searchPlan.stationPolicy)
        }

        // Apply user overrides (takes precedence)
        if let overrides = policyOverrides {
            policy.playlistSourceRatio = overrides.playlistSourceRatio
            policy.searchSourceRatio = overrides.searchSourceRatio
            policy.artistSeedSourceRatio = overrides.artistSeedSourceRatio
            policy.baseExplorationWeight = overrides.baseExplorationWeight
            policy.artistRepeatWindow = overrides.artistRepeatWindow
        }

        return policy
    }

    /// Display subtitle based on station type
    var subtitle: String {
        switch type {
        case .llmGenerated:
            return stationDescription ?? seedMood ?? "Custom station"
        case .mood:
            return "Mood: \(seedMood ?? "Unknown")"
        case .songSeed:
            return "Based on: \(seedTrackTitle ?? "Unknown")"
        case .artistSeed:
            return "Artist: \(seedTrackArtist ?? "Unknown")"
        case .genreSeed:
            return "Genre: \(seedGenre ?? "Unknown")"
        case .decadeSeed:
            return "Decade: \(seedDecade.map { "\($0)s" } ?? "Unknown")"
        case .fitness:
            return "Activity: \(seedActivity ?? "Workout")"
        }
    }
    
    // MARK: - Methods
    
    func addToRecentlyPlayed(_ isrc: String) {
        var recent = recentlyPlayed
        recent.append(isrc)
        recentlyPlayed = recent
    }
    
    func wasRecentlyPlayed(_ isrc: String) -> Bool {
        recentlyPlayed.contains(isrc)
    }
}

// MARK: - Thompson Sampling Parameters
struct ThompsonParameters: Codable, Equatable {
    // Beta distribution parameters for each feature
    // alpha = successes + 1, beta = failures + 1
    // Higher alpha/beta ratio = stronger preference for high values of that feature
    
    var bpmAlpha: Float = 1.0
    var bpmBeta: Float = 1.0
    
    var energyAlpha: Float = 1.0
    var energyBeta: Float = 1.0
    
    var danceabilityAlpha: Float = 1.0
    var danceabilityBeta: Float = 1.0
    
    var valenceAlpha: Float = 1.0
    var valenceBeta: Float = 1.0
    
    var acousticnessAlpha: Float = 1.0
    var acousticnessBeta: Float = 1.0
    
    var instrumentalnessAlpha: Float = 1.0
    var instrumentalnessBeta: Float = 1.0
    
    /// Update parameters based on feedback for a track
    mutating func update(for features: TrackFeatures, liked: Bool) {
        // For liked tracks: increase alpha for features that match the track
        // For disliked tracks: increase beta
        
        if liked {
            // Liked - reinforce these feature values
            // The closer to 1, the more we increase alpha
            // The closer to 0, the more we increase beta (preference for low values)
            bpmAlpha += features.bpm
            bpmBeta += (1 - features.bpm)
            
            energyAlpha += features.energy
            energyBeta += (1 - features.energy)
            
            danceabilityAlpha += features.danceability
            danceabilityBeta += (1 - features.danceability)
            
            valenceAlpha += features.valence
            valenceBeta += (1 - features.valence)
            
            acousticnessAlpha += features.acousticness
            acousticnessBeta += (1 - features.acousticness)
            
            instrumentalnessAlpha += features.instrumentalness
            instrumentalnessBeta += (1 - features.instrumentalness)
        } else {
            // Disliked - push away from these feature values
            bpmAlpha += (1 - features.bpm)
            bpmBeta += features.bpm
            
            energyAlpha += (1 - features.energy)
            energyBeta += features.energy
            
            danceabilityAlpha += (1 - features.danceability)
            danceabilityBeta += features.danceability
            
            valenceAlpha += (1 - features.valence)
            valenceBeta += features.valence
            
            acousticnessAlpha += (1 - features.acousticness)
            acousticnessBeta += features.acousticness
            
            instrumentalnessAlpha += (1 - features.instrumentalness)
            instrumentalnessBeta += features.instrumentalness
        }
    }
    
    /// Reset parameters to uniform prior
    mutating func reset() {
        bpmAlpha = 1.0
        bpmBeta = 1.0
        energyAlpha = 1.0
        energyBeta = 1.0
        danceabilityAlpha = 1.0
        danceabilityBeta = 1.0
        valenceAlpha = 1.0
        valenceBeta = 1.0
        acousticnessAlpha = 1.0
        acousticnessBeta = 1.0
        instrumentalnessAlpha = 1.0
        instrumentalnessBeta = 1.0
    }
    
    /// Get mean preference for each feature (for display/debugging)
    var meanPreferences: [String: Float] {
        [
            "bpm": bpmAlpha / (bpmAlpha + bpmBeta),
            "energy": energyAlpha / (energyAlpha + energyBeta),
            "danceability": danceabilityAlpha / (danceabilityAlpha + danceabilityBeta),
            "valence": valenceAlpha / (valenceAlpha + valenceBeta),
            "acousticness": acousticnessAlpha / (acousticnessAlpha + acousticnessBeta),
            "instrumentalness": instrumentalnessAlpha / (instrumentalnessAlpha + instrumentalnessBeta)
        ]
    }
    
    /// Total number of feedback signals received
    var totalFeedbackCount: Float {
        // Sum of all alpha + beta values minus the initial priors (6 features * 2)
        let total = bpmAlpha + bpmBeta + energyAlpha + energyBeta +
                    danceabilityAlpha + danceabilityBeta + valenceAlpha + valenceBeta +
                    acousticnessAlpha + acousticnessBeta + instrumentalnessAlpha + instrumentalnessBeta
        return max(0, total - 12)  // Subtract initial values
    }
}
