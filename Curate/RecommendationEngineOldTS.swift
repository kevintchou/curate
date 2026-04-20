//
//  RecommendationEngine.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation

// MARK: - Recommendation Engine
/// Contextualized Thompson Sampling recommendation engine
/// Learns user preferences from feedback and recommends tracks accordingly
final class RecommendationEngineOld {
    
    // MARK: - Configuration
    struct Config {
        /// Weight multipliers for different features (based on station type)
        var bpmWeight: Float = 1.0
        var energyWeight: Float = 1.0
        var danceabilityWeight: Float = 0.8
        var valenceWeight: Float = 0.8
        var acousticnessWeight: Float = 0.5
        var instrumentalnessWeight: Float = 0.5
        
        /// Temperature: 0.0 = pure exploitation, 1.0 = pure exploration
        var temperature: Float = 0.5
        
        /// Minimum similarity to seed for candidates (0-1)
        var minSimilarity: Float = 0.0
        
        /// Primary feature config for song seed stations
        static var songSeed: Config {
            var config = Config()
            config.bpmWeight = 1.0
            config.energyWeight = 0.9
            config.danceabilityWeight = 0.8
            config.valenceWeight = 0.7
            config.acousticnessWeight = 0.5
            config.instrumentalnessWeight = 0.5
            return config
        }
        
        /// Config for fitness/workout stations - BPM is critical
        static var fitness: Config {
            var config = Config()
            config.bpmWeight = 1.5  // BPM is most important
            config.energyWeight = 1.2
            config.danceabilityWeight = 0.8
            config.valenceWeight = 0.5
            config.acousticnessWeight = 0.3
            config.instrumentalnessWeight = 0.3
            return config
        }
        
        /// Config for mood stations
        static var mood: Config {
            var config = Config()
            config.bpmWeight = 0.8
            config.energyWeight = 1.2
            config.danceabilityWeight = 0.7
            config.valenceWeight = 1.5  // Mood/valence is most important
            config.acousticnessWeight = 0.6
            config.instrumentalnessWeight = 0.4
            return config
        }
    }
    
    // MARK: - Properties
    private let config: Config
    
    // MARK: - Initialization
    init(config: Config = Config()) {
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Select the next track using Thompson Sampling
    /// - Parameters:
    ///   - candidates: Pool of candidate tracks to choose from
    ///   - parameters: Current Thompson Sampling parameters (learned preferences)
    ///   - seedFeatures: Optional seed track features for similarity bonus
    ///   - temperature: Override temperature (0=exploit, 1=explore)
    ///   - genreWeights: Optional genre preferences (genre -> weight multiplier)
    /// - Returns: The selected track, or nil if no candidates
    func selectNext(
        from candidates: [Track],
        parameters: ThompsonParameters,
        seedFeatures: TrackFeatures? = nil,
        temperature: Float? = nil,
        genreWeights: [String: Float]? = nil
    ) -> Track? {
        guard !candidates.isEmpty else { return nil }
        
        let effectiveTemp = temperature ?? config.temperature
        
        // Score each candidate
        let scored = candidates.map { track -> (Track, Float) in
            let score = computeScore(
                for: track,
                parameters: parameters,
                seedFeatures: seedFeatures,
                temperature: effectiveTemp,
                genreWeights: genreWeights
            )
            return (track, score)
        }
        
        // Sort by score descending
        let sorted = scored.sorted { $0.1 > $1.1 }
        
        // With temperature, we might not always pick the top one
        // Higher temperature = more randomness in selection
        if effectiveTemp > 0.8 {
            // High exploration: pick from top 20%
            let topCount = max(1, Int(Float(sorted.count) * 0.2))
            let topCandidates = Array(sorted.prefix(topCount))
            return topCandidates.randomElement()?.0
        } else if effectiveTemp > 0.5 {
            // Medium exploration: pick from top 10%
            let topCount = max(1, Int(Float(sorted.count) * 0.1))
            let topCandidates = Array(sorted.prefix(topCount))
            return topCandidates.randomElement()?.0
        } else if effectiveTemp > 0.2 {
            // Low exploration: pick from top 5%
            let topCount = max(1, Int(Float(sorted.count) * 0.05))
            let topCandidates = Array(sorted.prefix(topCount))
            return topCandidates.randomElement()?.0
        } else {
            // Pure exploitation: pick the best
            return sorted.first?.0
        }
    }
    
    /// Update Thompson Sampling parameters based on feedback
    /// - Parameters:
    ///   - parameters: Current parameters (will be modified)
    ///   - track: The track that received feedback
    ///   - feedbackType: Type of feedback
    /// - Returns: Updated parameters
    func updateParameters(
        _ parameters: ThompsonParameters,
        for track: Track,
        feedback feedbackType: FeedbackType
    ) -> ThompsonParameters {
        var updated = parameters
        let features = track.featureVector()
        
        switch feedbackType {
        case .like:
            updated.update(for: features, liked: true)
        case .dislike:
            updated.update(for: features, liked: false)
        case .skip:
            // Weak negative - update with reduced weight
            var weakFeatures = features
            // Scale down the impact
            updated.update(for: weakFeatures, liked: false)
            // But less strongly - we'll compensate by doing a partial counter-update
            // This effectively reduces the update magnitude
        case .listenThrough:
            // Moderate positive
            updated.update(for: features, liked: true)
        }
        
        return updated
    }
    
    // MARK: - Private Methods
    
    /// Compute Thompson Sampling score for a track
    private func computeScore(
        for track: Track,
        parameters: ThompsonParameters,
        seedFeatures: TrackFeatures?,
        temperature: Float,
        genreWeights: [String: Float]?
    ) -> Float {
        let features = track.featureVector()
        
        // Sample from Beta distributions for each feature preference
        let sampledBPMPref = sampleBeta(alpha: parameters.bpmAlpha, beta: parameters.bpmBeta, temperature: temperature)
        let sampledEnergyPref = sampleBeta(alpha: parameters.energyAlpha, beta: parameters.energyBeta, temperature: temperature)
        let sampledDanceabilityPref = sampleBeta(alpha: parameters.danceabilityAlpha, beta: parameters.danceabilityBeta, temperature: temperature)
        let sampledValencePref = sampleBeta(alpha: parameters.valenceAlpha, beta: parameters.valenceBeta, temperature: temperature)
        let sampledAcousticnessPref = sampleBeta(alpha: parameters.acousticnessAlpha, beta: parameters.acousticnessBeta, temperature: temperature)
        let sampledInstrumentalnessPref = sampleBeta(alpha: parameters.instrumentalnessAlpha, beta: parameters.instrumentalnessBeta, temperature: temperature)
        
        // Compute how well this track matches the sampled preferences
        // Score = weighted sum of (1 - |feature - preference|)
        // This gives higher scores to tracks that match preferences
        
        var score: Float = 0
        var totalWeight: Float = 0
        
        // BPM score
        let bpmScore = 1 - abs(features.bpm - sampledBPMPref)
        score += bpmScore * config.bpmWeight
        totalWeight += config.bpmWeight
        
        // Energy score
        let energyScore = 1 - abs(features.energy - sampledEnergyPref)
        score += energyScore * config.energyWeight
        totalWeight += config.energyWeight
        
        // Danceability score
        let danceabilityScore = 1 - abs(features.danceability - sampledDanceabilityPref)
        score += danceabilityScore * config.danceabilityWeight
        totalWeight += config.danceabilityWeight
        
        // Valence score
        let valenceScore = 1 - abs(features.valence - sampledValencePref)
        score += valenceScore * config.valenceWeight
        totalWeight += config.valenceWeight
        
        // Acousticness score
        let acousticnessScore = 1 - abs(features.acousticness - sampledAcousticnessPref)
        score += acousticnessScore * config.acousticnessWeight
        totalWeight += config.acousticnessWeight
        
        // Instrumentalness score
        let instrumentalnessScore = 1 - abs(features.instrumentalness - sampledInstrumentalnessPref)
        score += instrumentalnessScore * config.instrumentalnessWeight
        totalWeight += config.instrumentalnessWeight
        
        // Normalize
        score = score / totalWeight
        
        // Apply genre weight multiplier if specified
        if let genreWeights = genreWeights,
           let trackGenre = track.genre {
            // Case-insensitive matching for genre
            let trackGenreLower = trackGenre.lowercased()
            
            // Check if this genre is in the preferred list (case-insensitive)
            let isPreferred = genreWeights.keys.contains { preferredGenre in
                preferredGenre.lowercased() == trackGenreLower
            }
            
            if isPreferred {
                // Preferred genre: 3x weight boost
                score *= 3.0
            } else {
                // Non-preferred genre: 0.3x weight (allows exploration but deprioritizes)
                score *= 0.3
            }
        }
        
        // Add similarity bonus if we have seed features
        if let seedFeatures = seedFeatures {
            let similarity = features.similarity(to: seedFeatures)
            // Blend: score gets 70%, similarity gets 30%
            score = score * 0.7 + similarity * 0.3
        }
        
        // Add small random noise for tie-breaking
        score += Float.random(in: 0...0.01)
        
        return score
    }
    
    /// Sample from a Beta distribution
    /// Uses temperature to control exploration vs exploitation
    private func sampleBeta(alpha: Float, beta: Float, temperature: Float) -> Float {
        // Simple approximation of Beta distribution sampling
        // For low temperature, return the mean (exploitation)
        // For high temperature, add more variance (exploration)
        
        let mean = alpha / (alpha + beta)
        
        if temperature < 0.1 {
            // Pure exploitation - return mean
            return mean
        }
        
        // Approximate variance of Beta distribution
        let variance = (alpha * beta) / ((alpha + beta) * (alpha + beta) * (alpha + beta + 1))
        let stdDev = sqrt(variance)
        
        // Sample with temperature-scaled noise
        // Using Box-Muller transform for Gaussian approximation
        let u1 = Float.random(in: 0.001...0.999)
        let u2 = Float.random(in: 0.001...0.999)
        let gaussian = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        
        let sample = mean + gaussian * stdDev * temperature * 2
        
        // Clamp to [0, 1]
        return max(0, min(1, sample))
    }
}

// MARK: - Candidate Pool Builder
/// Helper to build filtered candidate pools from the track repository
struct CandidatePoolBuilderOld {
    
    /// Build a candidate pool for a song-seeded station
    static func forSongSeed(
        seedTrack: Track,
        allTracks: [Track],
        excludeISRCs: [String],
        temperature: Float,
        limit: Int = 200
    ) -> [Track] {
        let seedFeatures = seedTrack.featureVector()
        
        // Calculate similarity ranges based on temperature
        // Higher temperature = wider range
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
        
        return Array(sorted.prefix(limit))
    }
    
    /// Build a candidate pool for genre-filtered station
    static func forGenre(
        genre: String,
        allTracks: [Track],
        excludeISRCs: [String],
        limit: Int = 200
    ) -> [Track] {
        let filtered = allTracks.filter { track in
            guard !excludeISRCs.contains(track.isrc) else { return false }
            guard track.hasAudioFeatures else { return false }
            guard track.genre?.lowercased() == genre.lowercased() else { return false }
            return true
        }
        
        return Array(filtered.shuffled().prefix(limit))
    }
    
    /// Build a candidate pool for decade-filtered station
    static func forDecade(
        decade: Int,
        allTracks: [Track],
        excludeISRCs: [String],
        limit: Int = 200
    ) -> [Track] {
        let filtered = allTracks.filter { track in
            guard !excludeISRCs.contains(track.isrc) else { return false }
            guard track.hasAudioFeatures else { return false }
            guard track.decade == decade else { return false }
            return true
        }
        
        return Array(filtered.shuffled().prefix(limit))
    }
}
