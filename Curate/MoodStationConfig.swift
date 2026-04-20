//
//  MoodStationConfig.swift
//  Curate
//
//  Pre-defined mood station configurations with target feature ranges and weights.
//  Designed to be extensible for future features like lyrics sentiment analysis.
//

import Foundation

// MARK: - Feature Range
/// Represents a target range for a feature with soft boundaries
struct FeatureRange: Codable, Equatable {
    let min: Float
    let max: Float
    
    /// The ideal target value (midpoint of range)
    var target: Float {
        (min + max) / 2
    }
    
    /// Check if a value is within the range
    func contains(_ value: Float) -> Bool {
        value >= min && value <= max
    }
    
    /// Calculate score for a value (1.0 if in range, penalized if outside)
    func score(for value: Float) -> Float {
        if contains(value) {
            return 1.0
        } else if value < min {
            // Below range - penalize based on distance
            return Swift.max(0, 1.0 - (min - value))
        } else {
            // Above range - penalize based on distance
            return Swift.max(0, 1.0 - (value - self.max))
        }
    }
    
    /// Check if value is within tolerance of the range (for soft filtering)
    func isWithinTolerance(_ value: Float, tolerance: Float) -> Bool {
        value >= (min - tolerance) && value <= (max + tolerance)
    }
}

// MARK: - Mood Station Config
/// Configuration for a pre-defined mood station
/// Conforms to UnifiedStationConfigProtocol for use with the unified LLM engine
struct MoodStationConfig: UnifiedStationConfigProtocol, Codable, Equatable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let category: StationCategory = .mood

    // MARK: - Feature Ranges (soft filters + scoring targets)
    let valenceRange: FeatureRange?
    let energyRange: FeatureRange?
    let danceabilityRange: FeatureRange?
    let bpmRange: FeatureRange?  // Normalized 0-1 (60-200 BPM mapped)
    let acousticnessRange: FeatureRange?
    let instrumentalnessRange: FeatureRange?

    // MARK: - Feature Weights (how important each feature is for this mood)
    let valenceWeight: Float
    let energyWeight: Float
    let danceabilityWeight: Float
    let bpmWeight: Float
    let acousticnessWeight: Float
    let instrumentalnessWeight: Float

    // MARK: - Contextual hints for LLM (UnifiedStationConfigProtocol)
    let suggestedGenres: [String]
    let suggestedDecades: [Int]?
    let moodKeywords: [String]
    let contextDescription: String

    // MARK: - Future Features (placeholders for extensibility)
    /// Lyrics sentiment target range (future feature)
    /// Values: -1.0 (very negative) to 1.0 (very positive)
    let lyricsSentimentRange: FeatureRange?
    let lyricsSentimentWeight: Float

    /// Mode preference: 1 = major (happy), 0 = minor (sad), nil = no preference
    let preferredMode: Int?
    let modeWeight: Float

    // MARK: - Candidate Pool Settings
    /// Tolerance for soft filtering (allows some tracks slightly outside range)
    let filterTolerance: Float

    /// What percentage of candidates can come from outside the primary range (for variety)
    let varietyPercentage: Float

    // MARK: - Default Temperature
    let defaultTemperature: Float
    
    // MARK: - Initialization
    init(
        id: String,
        name: String,
        icon: String,
        description: String,
        valenceRange: FeatureRange? = nil,
        energyRange: FeatureRange? = nil,
        danceabilityRange: FeatureRange? = nil,
        bpmRange: FeatureRange? = nil,
        acousticnessRange: FeatureRange? = nil,
        instrumentalnessRange: FeatureRange? = nil,
        valenceWeight: Float = 1.0,
        energyWeight: Float = 1.0,
        danceabilityWeight: Float = 0.8,
        bpmWeight: Float = 0.8,
        acousticnessWeight: Float = 0.5,
        instrumentalnessWeight: Float = 0.5,
        suggestedGenres: [String] = [],
        suggestedDecades: [Int]? = nil,
        moodKeywords: [String] = [],
        contextDescription: String = "",
        lyricsSentimentRange: FeatureRange? = nil,
        lyricsSentimentWeight: Float = 0.0,
        preferredMode: Int? = nil,
        modeWeight: Float = 0.3,
        filterTolerance: Float = 0.1,
        varietyPercentage: Float = 0.1,
        defaultTemperature: Float = 0.5
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.valenceRange = valenceRange
        self.energyRange = energyRange
        self.danceabilityRange = danceabilityRange
        self.bpmRange = bpmRange
        self.acousticnessRange = acousticnessRange
        self.instrumentalnessRange = instrumentalnessRange
        self.valenceWeight = valenceWeight
        self.energyWeight = energyWeight
        self.danceabilityWeight = danceabilityWeight
        self.bpmWeight = bpmWeight
        self.acousticnessWeight = acousticnessWeight
        self.instrumentalnessWeight = instrumentalnessWeight
        self.suggestedGenres = suggestedGenres
        self.suggestedDecades = suggestedDecades
        self.moodKeywords = moodKeywords
        self.contextDescription = contextDescription
        self.lyricsSentimentRange = lyricsSentimentRange
        self.lyricsSentimentWeight = lyricsSentimentWeight
        self.preferredMode = preferredMode
        self.modeWeight = modeWeight
        self.filterTolerance = filterTolerance
        self.varietyPercentage = varietyPercentage
        self.defaultTemperature = defaultTemperature
    }
    
    // MARK: - Target Features (for scoring)
    /// Returns the target feature values based on range midpoints
    var targetFeatures: MoodTargetFeatures {
        MoodTargetFeatures(
            valence: valenceRange?.target,
            energy: energyRange?.target,
            danceability: danceabilityRange?.target,
            bpm: bpmRange?.target,
            acousticness: acousticnessRange?.target,
            instrumentalness: instrumentalnessRange?.target,
            lyricsSentiment: lyricsSentimentRange?.target,
            mode: preferredMode
        )
    }
}

// MARK: - Mood Target Features
/// Target feature values derived from a mood config
struct MoodTargetFeatures: Codable, Equatable {
    let valence: Float?
    let energy: Float?
    let danceability: Float?
    let bpm: Float?
    let acousticness: Float?
    let instrumentalness: Float?
    let lyricsSentiment: Float?
    let mode: Int?
}

// MARK: - Pre-defined Mood Stations
extension MoodStationConfig {
    
    /// Feel Good - Upbeat, positive, happy music
    static let feelGood = MoodStationConfig(
        id: "feel_good",
        name: "Feel Good",
        icon: "face.smiling",
        description: "Upbeat, positive vibes to lift your mood",
        // Core attributes (most important)
        valenceRange: FeatureRange(min: 0.6, max: 0.9),      // High valence = happy
        energyRange: FeatureRange(min: 0.5, max: 0.8),       // Medium-high energy
        danceabilityRange: FeatureRange(min: 0.5, max: 0.8), // Groovy but not club-heavy
        bpmRange: FeatureRange(min: 0.286, max: 0.5),        // 100-130 BPM normalized (60-200 range)
        acousticnessRange: nil,                               // No preference
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.3), // Prefer vocals
        // Weights - valence is king for feel good
        valenceWeight: 1.5,
        energyWeight: 1.2,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.3,
        instrumentalnessWeight: 0.4,
        // LLM contextual hints
        suggestedGenres: ["Pop", "Funk", "Soul", "Dance", "Disco"],
        suggestedDecades: nil,
        moodKeywords: ["upbeat", "positive", "happy", "feel-good", "cheerful", "fun"],
        contextDescription: "Upbeat, positive vibes to lift your mood with catchy melodies and feel-good energy",
        // Future: positive lyrics
        lyricsSentimentRange: FeatureRange(min: 0.3, max: 1.0), // Positive lyrics (when implemented)
        lyricsSentimentWeight: 0.0, // Set to 0 until implemented
        // Prefer major keys (happier sound)
        preferredMode: 1,
        modeWeight: 0.5,
        // Allow some variety
        filterTolerance: 0.1,
        varietyPercentage: 0.1,
        defaultTemperature: 0.4
    )
    
    /// Energetic - High energy, pump-up music
    static let energetic = MoodStationConfig(
        id: "energetic",
        name: "Energetic",
        icon: "bolt.fill",
        description: "High-energy tracks to get you moving",
        valenceRange: FeatureRange(min: 0.4, max: 0.9),
        energyRange: FeatureRange(min: 0.7, max: 1.0),       // High energy is key
        danceabilityRange: FeatureRange(min: 0.6, max: 0.9),
        bpmRange: FeatureRange(min: 0.43, max: 0.71),        // 120-160 BPM
        acousticnessRange: FeatureRange(min: 0.0, max: 0.3), // Less acoustic
        instrumentalnessRange: nil,
        valenceWeight: 0.8,
        energyWeight: 1.5,  // Energy is most important
        danceabilityWeight: 1.2,
        bpmWeight: 1.0,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.3,
        // LLM contextual hints
        suggestedGenres: ["EDM", "Pop", "Hip-Hop", "Rock", "Dance"],
        suggestedDecades: nil,
        moodKeywords: ["energetic", "pump-up", "hype", "powerful", "driving", "intense"],
        contextDescription: "High-energy tracks with driving beats to get you pumped up and moving",
        lyricsSentimentRange: nil,
        lyricsSentimentWeight: 0.0,
        preferredMode: nil,
        modeWeight: 0.2,
        filterTolerance: 0.1,
        varietyPercentage: 0.1,
        defaultTemperature: 0.5
    )
    
    /// Chill - Relaxed, calm music
    static let chill = MoodStationConfig(
        id: "chill",
        name: "Chill",
        icon: "moon.stars.fill",
        description: "Relaxed vibes to unwind",
        valenceRange: FeatureRange(min: 0.3, max: 0.7),
        energyRange: FeatureRange(min: 0.1, max: 0.5),       // Low energy
        danceabilityRange: FeatureRange(min: 0.2, max: 0.6),
        bpmRange: FeatureRange(min: 0.0, max: 0.36),         // 60-110 BPM
        acousticnessRange: FeatureRange(min: 0.3, max: 1.0), // More acoustic
        instrumentalnessRange: nil,
        valenceWeight: 0.6,
        energyWeight: 1.3,  // Low energy is important
        danceabilityWeight: 0.5,
        bpmWeight: 0.8,
        acousticnessWeight: 1.0,
        instrumentalnessWeight: 0.5,
        // LLM contextual hints
        suggestedGenres: ["Chillout", "Lo-Fi", "Indie", "R&B", "Acoustic", "Jazz"],
        suggestedDecades: nil,
        moodKeywords: ["chill", "relaxed", "laid-back", "mellow", "calm", "easy-going"],
        contextDescription: "Relaxed, laid-back vibes to help you unwind and decompress",
        lyricsSentimentRange: nil,
        lyricsSentimentWeight: 0.0,
        preferredMode: nil,
        modeWeight: 0.2,
        filterTolerance: 0.15,
        varietyPercentage: 0.15,
        defaultTemperature: 0.4
    )
    
    /// Uplifting - Inspirational, soaring music
    static let uplifting = MoodStationConfig(
        id: "uplifting",
        name: "Uplifting",
        icon: "sparkles",
        description: "Inspirational tracks that soar",
        valenceRange: FeatureRange(min: 0.5, max: 0.95),
        energyRange: FeatureRange(min: 0.5, max: 0.85),
        danceabilityRange: FeatureRange(min: 0.4, max: 0.8),
        bpmRange: FeatureRange(min: 0.29, max: 0.57),        // 100-140 BPM
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.4,
        energyWeight: 1.1,
        danceabilityWeight: 0.7,
        bpmWeight: 0.6,
        acousticnessWeight: 0.4,
        instrumentalnessWeight: 0.4,
        // LLM contextual hints
        suggestedGenres: ["Pop", "Indie", "Alternative", "Gospel", "Orchestral"],
        suggestedDecades: nil,
        moodKeywords: ["uplifting", "inspirational", "anthemic", "soaring", "hopeful", "triumphant"],
        contextDescription: "Inspirational, soaring tracks that lift your spirits and make you feel empowered",
        lyricsSentimentRange: FeatureRange(min: 0.4, max: 1.0),
        lyricsSentimentWeight: 0.0,
        preferredMode: 1,  // Major keys
        modeWeight: 0.6,
        filterTolerance: 0.1,
        varietyPercentage: 0.1,
        defaultTemperature: 0.45
    )
    
    /// Romantic - Love songs, intimate music
    static let romantic = MoodStationConfig(
        id: "romantic",
        name: "Romantic",
        icon: "heart.fill",
        description: "Love songs and intimate vibes",
        valenceRange: FeatureRange(min: 0.3, max: 0.8),
        energyRange: FeatureRange(min: 0.2, max: 0.6),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.7),
        bpmRange: FeatureRange(min: 0.14, max: 0.43),        // 80-120 BPM
        acousticnessRange: FeatureRange(min: 0.2, max: 0.8),
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.2), // Prefer vocals
        valenceWeight: 0.8,
        energyWeight: 1.0,
        danceabilityWeight: 0.6,
        bpmWeight: 0.7,
        acousticnessWeight: 0.8,
        instrumentalnessWeight: 0.6,
        // LLM contextual hints
        suggestedGenres: ["R&B", "Soul", "Pop", "Jazz", "Acoustic"],
        suggestedDecades: nil,
        moodKeywords: ["romantic", "love", "intimate", "sensual", "tender", "passionate"],
        contextDescription: "Romantic love songs and intimate tracks for special moments together",
        lyricsSentimentRange: nil,  // Romantic lyrics can be happy or melancholic
        lyricsSentimentWeight: 0.0,
        preferredMode: nil,
        modeWeight: 0.2,
        filterTolerance: 0.12,
        varietyPercentage: 0.12,
        defaultTemperature: 0.4
    )
    
    /// Feeling Blue - Melancholic, emotional music
    static let feelingBlue = MoodStationConfig(
        id: "feeling_blue",
        name: "Feeling Blue",
        icon: "cloud.rain.fill",
        description: "Melancholic tracks for reflective moments",
        valenceRange: FeatureRange(min: 0.1, max: 0.4),      // Low valence = sad
        energyRange: FeatureRange(min: 0.1, max: 0.5),
        danceabilityRange: FeatureRange(min: 0.2, max: 0.5),
        bpmRange: FeatureRange(min: 0.0, max: 0.36),         // 60-110 BPM
        acousticnessRange: FeatureRange(min: 0.3, max: 1.0),
        instrumentalnessRange: nil,
        valenceWeight: 1.5,  // Low valence is key
        energyWeight: 1.0,
        danceabilityWeight: 0.5,
        bpmWeight: 0.6,
        acousticnessWeight: 0.8,
        instrumentalnessWeight: 0.4,
        // LLM contextual hints
        suggestedGenres: ["Indie", "Alternative", "Singer-Songwriter", "Acoustic", "Blues"],
        suggestedDecades: nil,
        moodKeywords: ["melancholic", "sad", "emotional", "reflective", "bittersweet", "wistful"],
        contextDescription: "Melancholic, emotional tracks for when you're feeling introspective or need to process emotions",
        lyricsSentimentRange: FeatureRange(min: -1.0, max: 0.2), // Sad lyrics (when implemented)
        lyricsSentimentWeight: 0.0,
        preferredMode: 0,  // Minor keys
        modeWeight: 0.6,
        filterTolerance: 0.1,
        varietyPercentage: 0.1,
        defaultTemperature: 0.35
    )
    
    /// Intense - Powerful, dramatic music
    static let intense = MoodStationConfig(
        id: "intense",
        name: "Intense",
        icon: "flame.fill",
        description: "Powerful, dramatic tracks",
        valenceRange: nil,  // Can be happy or angry intense
        energyRange: FeatureRange(min: 0.7, max: 1.0),
        danceabilityRange: FeatureRange(min: 0.4, max: 0.9),
        bpmRange: FeatureRange(min: 0.36, max: 0.79),        // 110-170 BPM
        acousticnessRange: FeatureRange(min: 0.0, max: 0.4),
        instrumentalnessRange: nil,
        valenceWeight: 0.4,
        energyWeight: 1.5,
        danceabilityWeight: 0.8,
        bpmWeight: 1.0,
        acousticnessWeight: 0.6,
        instrumentalnessWeight: 0.3,
        // LLM contextual hints
        suggestedGenres: ["Rock", "Metal", "EDM", "Dubstep", "Industrial", "Hardcore"],
        suggestedDecades: nil,
        moodKeywords: ["intense", "powerful", "dramatic", "aggressive", "epic", "heavy"],
        contextDescription: "Powerful, dramatic tracks with intense energy and heavy sound",
        lyricsSentimentRange: nil,
        lyricsSentimentWeight: 0.0,
        preferredMode: nil,
        modeWeight: 0.2,
        filterTolerance: 0.1,
        varietyPercentage: 0.1,
        defaultTemperature: 0.5
    )
    
    /// Peaceful - Serene, tranquil music
    static let peaceful = MoodStationConfig(
        id: "peaceful",
        name: "Peaceful",
        icon: "leaf.fill",
        description: "Serene and tranquil sounds",
        valenceRange: FeatureRange(min: 0.4, max: 0.8),
        energyRange: FeatureRange(min: 0.0, max: 0.4),       // Very low energy
        danceabilityRange: FeatureRange(min: 0.1, max: 0.4),
        bpmRange: FeatureRange(min: 0.0, max: 0.29),         // 60-100 BPM
        acousticnessRange: FeatureRange(min: 0.5, max: 1.0), // High acoustic
        instrumentalnessRange: FeatureRange(min: 0.2, max: 1.0), // Can be instrumental
        valenceWeight: 0.7,
        energyWeight: 1.3,
        danceabilityWeight: 0.4,
        bpmWeight: 0.7,
        acousticnessWeight: 1.2,
        instrumentalnessWeight: 0.6,
        // LLM contextual hints
        suggestedGenres: ["Ambient", "Classical", "New Age", "Nature Sounds", "Acoustic"],
        suggestedDecades: nil,
        moodKeywords: ["peaceful", "serene", "tranquil", "calming", "zen", "meditative"],
        contextDescription: "Serene, tranquil sounds for meditation, relaxation, or peaceful moments",
        lyricsSentimentRange: FeatureRange(min: 0.0, max: 0.8),
        lyricsSentimentWeight: 0.0,
        preferredMode: 1,
        modeWeight: 0.4,
        filterTolerance: 0.15,
        varietyPercentage: 0.15,
        defaultTemperature: 0.35
    )
    
    /// Focus - Concentration-friendly music
    static let focus = MoodStationConfig(
        id: "focus",
        name: "Focus",
        icon: "waveform",
        description: "Music to help you concentrate",
        valenceRange: FeatureRange(min: 0.3, max: 0.7),
        energyRange: FeatureRange(min: 0.3, max: 0.6),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.6),
        bpmRange: FeatureRange(min: 0.14, max: 0.43),        // 80-120 BPM
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.3, max: 1.0), // Prefer instrumental
        valenceWeight: 0.5,
        energyWeight: 1.0,
        danceabilityWeight: 0.5,
        bpmWeight: 0.8,
        acousticnessWeight: 0.6,
        instrumentalnessWeight: 1.3,  // Instrumental is important for focus
        // LLM contextual hints
        suggestedGenres: ["Lo-Fi", "Ambient", "Electronic", "Classical", "Post-Rock"],
        suggestedDecades: nil,
        moodKeywords: ["focus", "concentration", "study", "work", "productive", "background"],
        contextDescription: "Concentration-friendly music that helps you focus without being distracting",
        lyricsSentimentRange: nil,
        lyricsSentimentWeight: 0.0,
        preferredMode: nil,
        modeWeight: 0.2,
        filterTolerance: 0.12,
        varietyPercentage: 0.1,
        defaultTemperature: 0.35
    )
    
    // MARK: - All Mood Configs
    static let allMoods: [MoodStationConfig] = [
        .feelGood,
        .energetic,
        .uplifting,
        .chill,
        .romantic,
        .feelingBlue,
        .intense,
        .peaceful,
        .focus
    ]
    
    /// Get a mood config by ID
    static func config(for id: String) -> MoodStationConfig? {
        allMoods.first { $0.id == id }
    }
    
    /// Get a mood config by name
    static func config(named name: String) -> MoodStationConfig? {
        allMoods.first { $0.name.lowercased() == name.lowercased() }
    }
}

