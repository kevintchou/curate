//
//  UnifiedStationConfig.swift
//  Curate
//
//  Protocol-based configuration system for LLM-powered stations.
//  Allows Mood, Activity, Genre, and Decade tabs to share the same LLM engine.
//

import Foundation

// MARK: - Station Category
/// The category of station (determines which tab it belongs to)
enum StationCategory: String, Codable, CaseIterable {
    case mood
    case activity
    case genre
    case decade
    case custom  // For free-form LLM prompts
}

// MARK: - Unified Station Config Protocol
/// Protocol that all station configurations must conform to.
/// This enables the LLM engine to work with any station type.
protocol UnifiedStationConfigProtocol: Identifiable, Equatable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var description: String { get }
    var category: StationCategory { get }

    // MARK: - Feature Ranges (for LLM prompt guidance)
    var valenceRange: FeatureRange? { get }
    var energyRange: FeatureRange? { get }
    var danceabilityRange: FeatureRange? { get }
    var bpmRange: FeatureRange? { get }
    var acousticnessRange: FeatureRange? { get }
    var instrumentalnessRange: FeatureRange? { get }

    // MARK: - Feature Weights (how important each feature is)
    var valenceWeight: Float { get }
    var energyWeight: Float { get }
    var danceabilityWeight: Float { get }
    var bpmWeight: Float { get }
    var acousticnessWeight: Float { get }
    var instrumentalnessWeight: Float { get }

    // MARK: - Contextual Hints for LLM
    var suggestedGenres: [String] { get }
    var suggestedDecades: [Int]? { get }
    var moodKeywords: [String] { get }
    var contextDescription: String { get }

    // MARK: - Station Settings
    var defaultTemperature: Float { get }
    var filterTolerance: Float { get }
}

// MARK: - Default Implementations
extension UnifiedStationConfigProtocol {
    var valenceWeight: Float { 1.0 }
    var energyWeight: Float { 1.0 }
    var danceabilityWeight: Float { 0.8 }
    var bpmWeight: Float { 0.8 }
    var acousticnessWeight: Float { 0.5 }
    var instrumentalnessWeight: Float { 0.5 }
    var defaultTemperature: Float { 0.5 }
    var filterTolerance: Float { 0.1 }
    var suggestedGenres: [String] { [] }
    var suggestedDecades: [Int]? { nil }
}

// MARK: - Convert to LLMStationConfig
extension UnifiedStationConfigProtocol {
    /// Convert this config to an LLMStationConfig for the LLM service
    func toLLMStationConfig() -> LLMStationConfig {
        LLMStationConfig(
            name: name,
            description: description,
            originalPrompt: buildPromptFromConfig(),
            valenceRange: valenceRange.map { FeatureRangeLLM(min: $0.min, max: $0.max) },
            energyRange: energyRange.map { FeatureRangeLLM(min: $0.min, max: $0.max) },
            danceabilityRange: danceabilityRange.map { FeatureRangeLLM(min: $0.min, max: $0.max) },
            bpmRange: bpmRange.map { FeatureRangeLLM(min: $0.min, max: $0.max) },
            acousticnessRange: acousticnessRange.map { FeatureRangeLLM(min: $0.min, max: $0.max) },
            instrumentalnessRange: instrumentalnessRange.map { FeatureRangeLLM(min: $0.min, max: $0.max) },
            valenceWeight: valenceWeight,
            energyWeight: energyWeight,
            danceabilityWeight: danceabilityWeight,
            bpmWeight: bpmWeight,
            acousticnessWeight: acousticnessWeight,
            instrumentalnessWeight: instrumentalnessWeight,
            suggestedGenres: suggestedGenres,
            suggestedDecades: suggestedDecades,
            moodKeywords: moodKeywords,
            contextDescription: contextDescription
        )
    }

    /// Build a natural language prompt from the config for LLM
    private func buildPromptFromConfig() -> String {
        var prompt = "\(name) - \(description)"

        // Add feature guidance
        var featureHints: [String] = []

        if let valence = valenceRange {
            let moodDesc = valence.target > 0.6 ? "happy/uplifting" : valence.target < 0.4 ? "melancholic/sad" : "balanced mood"
            featureHints.append(moodDesc)
        }

        if let energy = energyRange {
            let energyDesc = energy.target > 0.7 ? "high energy" : energy.target < 0.4 ? "calm/relaxed" : "moderate energy"
            featureHints.append(energyDesc)
        }

        if let bpm = bpmRange {
            // Convert normalized BPM back to actual BPM for description
            let actualBpmMin = Int(bpm.min * 140 + 60)
            let actualBpmMax = Int(bpm.max * 140 + 60)
            featureHints.append("\(actualBpmMin)-\(actualBpmMax) BPM")
        }

        if let acousticness = acousticnessRange {
            if acousticness.target > 0.6 {
                featureHints.append("acoustic/organic")
            } else if acousticness.target < 0.3 {
                featureHints.append("electronic/produced")
            }
        }

        if let instrumentalness = instrumentalnessRange {
            if instrumentalness.target > 0.5 {
                featureHints.append("instrumental preferred")
            } else if instrumentalness.target < 0.3 {
                featureHints.append("with vocals")
            }
        }

        if !featureHints.isEmpty {
            prompt += " (\(featureHints.joined(separator: ", ")))"
        }

        if !moodKeywords.isEmpty {
            prompt += ". Keywords: \(moodKeywords.joined(separator: ", "))"
        }

        if !suggestedGenres.isEmpty {
            prompt += ". Genres: \(suggestedGenres.joined(separator: ", "))"
        }

        if let decades = suggestedDecades, !decades.isEmpty {
            prompt += ". Decades: \(decades.map { "\($0)s" }.joined(separator: ", "))"
        }

        return prompt
    }
}

// MARK: - Activity Station Config
/// Configuration for activity-based stations (Running, Gym, Yoga, etc.)
struct ActivityStationConfig: UnifiedStationConfigProtocol {
    let id: String
    let name: String
    let icon: String
    let description: String
    let category: StationCategory = .activity

    let valenceRange: FeatureRange?
    let energyRange: FeatureRange?
    let danceabilityRange: FeatureRange?
    let bpmRange: FeatureRange?
    let acousticnessRange: FeatureRange?
    let instrumentalnessRange: FeatureRange?

    let valenceWeight: Float
    let energyWeight: Float
    let danceabilityWeight: Float
    let bpmWeight: Float
    let acousticnessWeight: Float
    let instrumentalnessWeight: Float

    let suggestedGenres: [String]
    let suggestedDecades: [Int]?
    let moodKeywords: [String]
    let contextDescription: String

    let defaultTemperature: Float
    let filterTolerance: Float
}

// MARK: - Pre-defined Activity Configs
extension ActivityStationConfig {

    static let running = ActivityStationConfig(
        id: "running",
        name: "Running",
        icon: "figure.run",
        description: "High-energy tracks to fuel your run",
        valenceRange: FeatureRange(min: 0.5, max: 0.9),
        energyRange: FeatureRange(min: 0.7, max: 1.0),
        danceabilityRange: FeatureRange(min: 0.6, max: 0.9),
        bpmRange: FeatureRange(min: 0.5, max: 0.79),  // 130-170 BPM
        acousticnessRange: FeatureRange(min: 0.0, max: 0.3),
        instrumentalnessRange: nil,
        valenceWeight: 0.8,
        energyWeight: 1.5,
        danceabilityWeight: 1.0,
        bpmWeight: 1.3,
        acousticnessWeight: 0.4,
        instrumentalnessWeight: 0.3,
        suggestedGenres: ["Pop", "Hip Hop", "Electronic", "Dance"],
        suggestedDecades: nil,
        moodKeywords: ["motivating", "pumped", "powerful", "driven"],
        contextDescription: "Fast-paced, motivating music to maintain running cadence",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let gym = ActivityStationConfig(
        id: "gym",
        name: "Gym",
        icon: "figure.strengthtraining.traditional",
        description: "Powerful beats for your workout",
        valenceRange: FeatureRange(min: 0.4, max: 0.9),
        energyRange: FeatureRange(min: 0.75, max: 1.0),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.9),
        bpmRange: FeatureRange(min: 0.43, max: 0.71),  // 120-160 BPM
        acousticnessRange: FeatureRange(min: 0.0, max: 0.2),
        instrumentalnessRange: nil,
        valenceWeight: 0.6,
        energyWeight: 1.5,
        danceabilityWeight: 0.9,
        bpmWeight: 1.2,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.3,
        suggestedGenres: ["Hip Hop", "Electronic", "Rock", "Metal"],
        suggestedDecades: nil,
        moodKeywords: ["intense", "powerful", "aggressive", "pump-up"],
        contextDescription: "Heavy, intense music for lifting and strength training",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let walking = ActivityStationConfig(
        id: "walking",
        name: "Walking",
        icon: "figure.walk",
        description: "Pleasant tunes for a nice walk",
        valenceRange: FeatureRange(min: 0.4, max: 0.8),
        energyRange: FeatureRange(min: 0.4, max: 0.7),
        danceabilityRange: FeatureRange(min: 0.4, max: 0.7),
        bpmRange: FeatureRange(min: 0.29, max: 0.5),  // 100-130 BPM
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 0.7,
        bpmWeight: 0.9,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.4,
        suggestedGenres: ["Pop", "Indie", "Folk", "Soft Rock"],
        suggestedDecades: nil,
        moodKeywords: ["pleasant", "easy-going", "comfortable", "breezy"],
        contextDescription: "Comfortable, mid-tempo music for a leisurely walk",
        defaultTemperature: 0.45,
        filterTolerance: 0.12
    )

    static let yoga = ActivityStationConfig(
        id: "yoga",
        name: "Yoga",
        icon: "figure.yoga",
        description: "Calming sounds for mindful practice",
        valenceRange: FeatureRange(min: 0.3, max: 0.7),
        energyRange: FeatureRange(min: 0.0, max: 0.4),
        danceabilityRange: FeatureRange(min: 0.1, max: 0.4),
        bpmRange: FeatureRange(min: 0.0, max: 0.29),  // 60-100 BPM
        acousticnessRange: FeatureRange(min: 0.4, max: 1.0),
        instrumentalnessRange: FeatureRange(min: 0.3, max: 1.0),
        valenceWeight: 0.6,
        energyWeight: 1.3,
        danceabilityWeight: 0.4,
        bpmWeight: 0.8,
        acousticnessWeight: 1.0,
        instrumentalnessWeight: 0.8,
        suggestedGenres: ["Ambient", "New Age", "Classical", "World"],
        suggestedDecades: nil,
        moodKeywords: ["peaceful", "serene", "meditative", "flowing"],
        contextDescription: "Gentle, flowing music for yoga and meditation practice",
        defaultTemperature: 0.35,
        filterTolerance: 0.15
    )

    static let driving = ActivityStationConfig(
        id: "driving",
        name: "Driving",
        icon: "car.fill",
        description: "Great driving music for the road",
        valenceRange: FeatureRange(min: 0.4, max: 0.85),
        energyRange: FeatureRange(min: 0.5, max: 0.8),
        danceabilityRange: FeatureRange(min: 0.4, max: 0.8),
        bpmRange: FeatureRange(min: 0.29, max: 0.57),  // 100-140 BPM
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.4),
        valenceWeight: 1.0,
        energyWeight: 1.1,
        danceabilityWeight: 0.8,
        bpmWeight: 0.9,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Rock", "Pop", "Alternative", "Indie"],
        suggestedDecades: nil,
        moodKeywords: ["road trip", "cruising", "adventurous", "free"],
        contextDescription: "Feel-good driving music for the open road",
        defaultTemperature: 0.5,
        filterTolerance: 0.12
    )

    static let commuting = ActivityStationConfig(
        id: "commuting",
        name: "Commuting",
        icon: "train.side.front.car",
        description: "Music to make your commute better",
        valenceRange: FeatureRange(min: 0.35, max: 0.75),
        energyRange: FeatureRange(min: 0.3, max: 0.65),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.65),
        bpmRange: FeatureRange(min: 0.21, max: 0.5),  // 90-130 BPM
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 0.9,
        energyWeight: 0.9,
        danceabilityWeight: 0.6,
        bpmWeight: 0.7,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Indie", "Pop", "Electronic", "R&B"],
        suggestedDecades: nil,
        moodKeywords: ["smooth", "engaging", "comfortable", "headphone-friendly"],
        contextDescription: "Perfect music for public transit or commute time",
        defaultTemperature: 0.45,
        filterTolerance: 0.12
    )

    static let relaxing = ActivityStationConfig(
        id: "relaxing",
        name: "Relaxing",
        icon: "figure.cooldown",
        description: "Unwind and destress",
        valenceRange: FeatureRange(min: 0.3, max: 0.7),
        energyRange: FeatureRange(min: 0.1, max: 0.45),
        danceabilityRange: FeatureRange(min: 0.2, max: 0.5),
        bpmRange: FeatureRange(min: 0.0, max: 0.36),  // 60-110 BPM
        acousticnessRange: FeatureRange(min: 0.3, max: 1.0),
        instrumentalnessRange: nil,
        valenceWeight: 0.7,
        energyWeight: 1.2,
        danceabilityWeight: 0.5,
        bpmWeight: 0.8,
        acousticnessWeight: 0.9,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Acoustic", "Indie Folk", "Jazz", "Lo-fi"],
        suggestedDecades: nil,
        moodKeywords: ["relaxing", "soothing", "mellow", "peaceful"],
        contextDescription: "Calming music to help you unwind and relax",
        defaultTemperature: 0.4,
        filterTolerance: 0.15
    )

    static let reading = ActivityStationConfig(
        id: "reading",
        name: "Reading",
        icon: "book.fill",
        description: "Background music for reading",
        valenceRange: FeatureRange(min: 0.3, max: 0.6),
        energyRange: FeatureRange(min: 0.1, max: 0.4),
        danceabilityRange: FeatureRange(min: 0.1, max: 0.4),
        bpmRange: FeatureRange(min: 0.0, max: 0.29),  // 60-100 BPM
        acousticnessRange: FeatureRange(min: 0.3, max: 1.0),
        instrumentalnessRange: FeatureRange(min: 0.4, max: 1.0),
        valenceWeight: 0.5,
        energyWeight: 1.2,
        danceabilityWeight: 0.4,
        bpmWeight: 0.7,
        acousticnessWeight: 0.8,
        instrumentalnessWeight: 1.2,
        suggestedGenres: ["Classical", "Ambient", "Jazz", "Lo-fi"],
        suggestedDecades: nil,
        moodKeywords: ["unobtrusive", "atmospheric", "contemplative", "gentle"],
        contextDescription: "Non-distracting instrumental music for reading focus",
        defaultTemperature: 0.35,
        filterTolerance: 0.15
    )

    static let cooking = ActivityStationConfig(
        id: "cooking",
        name: "Cooking",
        icon: "fork.knife",
        description: "Fun music for the kitchen",
        valenceRange: FeatureRange(min: 0.5, max: 0.85),
        energyRange: FeatureRange(min: 0.4, max: 0.75),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.8),
        bpmRange: FeatureRange(min: 0.29, max: 0.57),  // 100-140 BPM
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.4),
        valenceWeight: 1.1,
        energyWeight: 0.9,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Pop", "Soul", "Jazz", "Latin", "Funk"],
        suggestedDecades: nil,
        moodKeywords: ["fun", "groovy", "upbeat", "kitchen-friendly"],
        contextDescription: "Feel-good music that makes cooking enjoyable",
        defaultTemperature: 0.5,
        filterTolerance: 0.12
    )

    static let sleeping = ActivityStationConfig(
        id: "sleeping",
        name: "Sleeping",
        icon: "bed.double.fill",
        description: "Gentle sounds for sleep",
        valenceRange: FeatureRange(min: 0.2, max: 0.5),
        energyRange: FeatureRange(min: 0.0, max: 0.25),
        danceabilityRange: FeatureRange(min: 0.0, max: 0.3),
        bpmRange: FeatureRange(min: 0.0, max: 0.21),  // 60-90 BPM
        acousticnessRange: FeatureRange(min: 0.5, max: 1.0),
        instrumentalnessRange: FeatureRange(min: 0.5, max: 1.0),
        valenceWeight: 0.4,
        energyWeight: 1.5,
        danceabilityWeight: 0.3,
        bpmWeight: 1.0,
        acousticnessWeight: 1.0,
        instrumentalnessWeight: 1.2,
        suggestedGenres: ["Ambient", "Classical", "Sleep", "New Age"],
        suggestedDecades: nil,
        moodKeywords: ["dreamy", "soft", "peaceful", "sleep-inducing"],
        contextDescription: "Ultra-calm music to help you fall asleep",
        defaultTemperature: 0.3,
        filterTolerance: 0.15
    )

    static let working = ActivityStationConfig(
        id: "working",
        name: "Working",
        icon: "briefcase.fill",
        description: "Focus music for productivity",
        valenceRange: FeatureRange(min: 0.3, max: 0.7),
        energyRange: FeatureRange(min: 0.3, max: 0.6),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.6),
        bpmRange: FeatureRange(min: 0.14, max: 0.43),  // 80-120 BPM
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.4, max: 1.0),
        valenceWeight: 0.5,
        energyWeight: 1.0,
        danceabilityWeight: 0.5,
        bpmWeight: 0.8,
        acousticnessWeight: 0.6,
        instrumentalnessWeight: 1.3,
        suggestedGenres: ["Lo-fi", "Electronic", "Ambient", "Post-Rock"],
        suggestedDecades: nil,
        moodKeywords: ["focus", "productive", "steady", "unobtrusive"],
        contextDescription: "Concentration-friendly music for deep work",
        defaultTemperature: 0.35,
        filterTolerance: 0.12
    )

    static let socializing = ActivityStationConfig(
        id: "socializing",
        name: "Socializing",
        icon: "person.2.fill",
        description: "Background music for gatherings",
        valenceRange: FeatureRange(min: 0.5, max: 0.85),
        energyRange: FeatureRange(min: 0.4, max: 0.75),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.8),
        bpmRange: FeatureRange(min: 0.29, max: 0.57),  // 100-140 BPM
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.4),
        valenceWeight: 1.2,
        energyWeight: 0.9,
        danceabilityWeight: 1.0,
        bpmWeight: 0.7,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Pop", "R&B", "Indie", "House", "Disco"],
        suggestedDecades: nil,
        moodKeywords: ["social", "fun", "crowd-pleasing", "conversational"],
        contextDescription: "Great background music for parties and get-togethers",
        defaultTemperature: 0.5,
        filterTolerance: 0.12
    )

    // MARK: - All Activity Configs
    static let allActivities: [ActivityStationConfig] = [
        .running, .gym, .walking, .yoga, .driving,
        .commuting, .relaxing, .reading, .cooking,
        .sleeping, .working, .socializing
    ]

    static func config(for id: String) -> ActivityStationConfig? {
        allActivities.first { $0.id == id }
    }
}

// MARK: - Genre Station Config
/// Configuration for genre-based stations
struct GenreStationConfig: UnifiedStationConfigProtocol {
    let id: String
    let name: String
    let icon: String
    let description: String
    let category: StationCategory = .genre

    let valenceRange: FeatureRange?
    let energyRange: FeatureRange?
    let danceabilityRange: FeatureRange?
    let bpmRange: FeatureRange?
    let acousticnessRange: FeatureRange?
    let instrumentalnessRange: FeatureRange?

    let valenceWeight: Float
    let energyWeight: Float
    let danceabilityWeight: Float
    let bpmWeight: Float
    let acousticnessWeight: Float
    let instrumentalnessWeight: Float

    let suggestedGenres: [String]
    let suggestedDecades: [Int]?
    let moodKeywords: [String]
    let contextDescription: String

    let defaultTemperature: Float
    let filterTolerance: Float
}

// MARK: - Pre-defined Genre Configs
extension GenreStationConfig {

    static let pop = GenreStationConfig(
        id: "pop",
        name: "Pop",
        icon: "music.note",
        description: "Popular hits and catchy tunes",
        valenceRange: FeatureRange(min: 0.4, max: 0.9),
        energyRange: FeatureRange(min: 0.5, max: 0.85),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.85),
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.3),
        valenceWeight: 1.1,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.7,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.6,
        suggestedGenres: ["Pop", "Dance Pop", "Synth Pop", "Electropop"],
        suggestedDecades: nil,
        moodKeywords: ["catchy", "mainstream", "radio-friendly", "upbeat"],
        contextDescription: "Mainstream pop music with catchy hooks and melodies",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let rock = GenreStationConfig(
        id: "rock",
        name: "Rock",
        icon: "guitars.fill",
        description: "Guitar-driven rock music",
        valenceRange: FeatureRange(min: 0.3, max: 0.8),
        energyRange: FeatureRange(min: 0.5, max: 0.95),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.7),
        bpmRange: nil,
        acousticnessRange: FeatureRange(min: 0.0, max: 0.5),
        instrumentalnessRange: nil,
        valenceWeight: 0.8,
        energyWeight: 1.3,
        danceabilityWeight: 0.6,
        bpmWeight: 0.7,
        acousticnessWeight: 0.7,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Rock", "Alternative Rock", "Classic Rock", "Hard Rock"],
        suggestedDecades: nil,
        moodKeywords: ["guitar-driven", "powerful", "raw", "energetic"],
        contextDescription: "Rock music featuring guitars, drums, and powerful vocals",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let hipHop = GenreStationConfig(
        id: "hiphop",
        name: "Hip Hop",
        icon: "music.mic",
        description: "Hip hop and rap tracks",
        valenceRange: FeatureRange(min: 0.3, max: 0.8),
        energyRange: FeatureRange(min: 0.5, max: 0.9),
        danceabilityRange: FeatureRange(min: 0.6, max: 0.95),
        bpmRange: FeatureRange(min: 0.21, max: 0.57),  // 90-140 BPM
        acousticnessRange: FeatureRange(min: 0.0, max: 0.3),
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.2),
        valenceWeight: 0.7,
        energyWeight: 1.1,
        danceabilityWeight: 1.2,
        bpmWeight: 1.0,
        acousticnessWeight: 0.6,
        instrumentalnessWeight: 0.7,
        suggestedGenres: ["Hip Hop", "Rap", "Trap", "R&B"],
        suggestedDecades: nil,
        moodKeywords: ["beats", "flow", "bars", "urban"],
        contextDescription: "Hip hop music with hard-hitting beats and lyrical flow",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let jazz = GenreStationConfig(
        id: "jazz",
        name: "Jazz",
        icon: "music.note.list",
        description: "Smooth jazz and classic standards",
        valenceRange: FeatureRange(min: 0.3, max: 0.7),
        energyRange: FeatureRange(min: 0.2, max: 0.6),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.7),
        bpmRange: nil,
        acousticnessRange: FeatureRange(min: 0.3, max: 0.9),
        instrumentalnessRange: FeatureRange(min: 0.2, max: 0.9),
        valenceWeight: 0.8,
        energyWeight: 0.9,
        danceabilityWeight: 0.7,
        bpmWeight: 0.6,
        acousticnessWeight: 1.0,
        instrumentalnessWeight: 0.8,
        suggestedGenres: ["Jazz", "Smooth Jazz", "Bebop", "Cool Jazz"],
        suggestedDecades: nil,
        moodKeywords: ["sophisticated", "smooth", "improvisational", "classy"],
        contextDescription: "Jazz music from smooth to bebop, featuring improvisation",
        defaultTemperature: 0.45,
        filterTolerance: 0.12
    )

    static let electronic = GenreStationConfig(
        id: "electronic",
        name: "Electronic",
        icon: "waveform",
        description: "Electronic and EDM tracks",
        valenceRange: FeatureRange(min: 0.4, max: 0.9),
        energyRange: FeatureRange(min: 0.6, max: 1.0),
        danceabilityRange: FeatureRange(min: 0.6, max: 0.95),
        bpmRange: FeatureRange(min: 0.43, max: 0.79),  // 120-170 BPM
        acousticnessRange: FeatureRange(min: 0.0, max: 0.2),
        instrumentalnessRange: FeatureRange(min: 0.3, max: 1.0),
        valenceWeight: 0.8,
        energyWeight: 1.3,
        danceabilityWeight: 1.2,
        bpmWeight: 1.0,
        acousticnessWeight: 0.8,
        instrumentalnessWeight: 0.6,
        suggestedGenres: ["Electronic", "EDM", "House", "Techno", "Trance"],
        suggestedDecades: nil,
        moodKeywords: ["synthesized", "danceable", "club", "bass-heavy"],
        contextDescription: "Electronic dance music with synths and heavy beats",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let classical = GenreStationConfig(
        id: "classical",
        name: "Classical",
        icon: "pianokeys",
        description: "Classical masterpieces",
        valenceRange: FeatureRange(min: 0.2, max: 0.7),
        energyRange: FeatureRange(min: 0.1, max: 0.7),
        danceabilityRange: FeatureRange(min: 0.1, max: 0.4),
        bpmRange: nil,
        acousticnessRange: FeatureRange(min: 0.7, max: 1.0),
        instrumentalnessRange: FeatureRange(min: 0.8, max: 1.0),
        valenceWeight: 0.7,
        energyWeight: 0.8,
        danceabilityWeight: 0.3,
        bpmWeight: 0.5,
        acousticnessWeight: 1.2,
        instrumentalnessWeight: 1.0,
        suggestedGenres: ["Classical", "Baroque", "Romantic", "Contemporary Classical"],
        suggestedDecades: nil,
        moodKeywords: ["orchestral", "timeless", "composed", "refined"],
        contextDescription: "Classical music from baroque to contemporary",
        defaultTemperature: 0.4,
        filterTolerance: 0.12
    )

    static let country = GenreStationConfig(
        id: "country",
        name: "Country",
        icon: "music.quarternote.3",
        description: "Country and Americana",
        valenceRange: FeatureRange(min: 0.3, max: 0.8),
        energyRange: FeatureRange(min: 0.3, max: 0.75),
        danceabilityRange: FeatureRange(min: 0.4, max: 0.75),
        bpmRange: nil,
        acousticnessRange: FeatureRange(min: 0.2, max: 0.8),
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.3),
        valenceWeight: 1.0,
        energyWeight: 0.9,
        danceabilityWeight: 0.8,
        bpmWeight: 0.7,
        acousticnessWeight: 0.9,
        instrumentalnessWeight: 0.6,
        suggestedGenres: ["Country", "Americana", "Country Rock", "Bluegrass"],
        suggestedDecades: nil,
        moodKeywords: ["storytelling", "twangy", "heartfelt", "rural"],
        contextDescription: "Country music with stories, guitars, and heartfelt lyrics",
        defaultTemperature: 0.45,
        filterTolerance: 0.12
    )

    static let latin = GenreStationConfig(
        id: "latin",
        name: "Latin",
        icon: "globe.americas.fill",
        description: "Latin rhythms and sounds",
        valenceRange: FeatureRange(min: 0.5, max: 0.9),
        energyRange: FeatureRange(min: 0.5, max: 0.9),
        danceabilityRange: FeatureRange(min: 0.6, max: 0.95),
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.4),
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.3,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.6,
        suggestedGenres: ["Latin", "Reggaeton", "Salsa", "Bachata", "Latin Pop"],
        suggestedDecades: nil,
        moodKeywords: ["rhythmic", "passionate", "tropical", "danceable"],
        contextDescription: "Latin music with infectious rhythms and passion",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let rnb = GenreStationConfig(
        id: "rnb",
        name: "R&B",
        icon: "headphones",
        description: "Smooth R&B and soul",
        valenceRange: FeatureRange(min: 0.3, max: 0.75),
        energyRange: FeatureRange(min: 0.3, max: 0.7),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.85),
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: FeatureRange(min: 0.0, max: 0.3),
        valenceWeight: 0.9,
        energyWeight: 0.9,
        danceabilityWeight: 1.1,
        bpmWeight: 0.7,
        acousticnessWeight: 0.6,
        instrumentalnessWeight: 0.7,
        suggestedGenres: ["R&B", "Soul", "Neo-Soul", "Contemporary R&B"],
        suggestedDecades: nil,
        moodKeywords: ["smooth", "soulful", "groovy", "sensual"],
        contextDescription: "R&B and soul music with smooth vocals and grooves",
        defaultTemperature: 0.45,
        filterTolerance: 0.12
    )

    static let indie = GenreStationConfig(
        id: "indie",
        name: "Indie",
        icon: "metronome.fill",
        description: "Independent and alternative",
        valenceRange: FeatureRange(min: 0.3, max: 0.75),
        energyRange: FeatureRange(min: 0.3, max: 0.75),
        danceabilityRange: FeatureRange(min: 0.3, max: 0.7),
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 0.9,
        energyWeight: 0.9,
        danceabilityWeight: 0.7,
        bpmWeight: 0.6,
        acousticnessWeight: 0.7,
        instrumentalnessWeight: 0.6,
        suggestedGenres: ["Indie", "Indie Rock", "Indie Pop", "Alternative"],
        suggestedDecades: nil,
        moodKeywords: ["independent", "eclectic", "artistic", "unique"],
        contextDescription: "Indie music with artistic vision and unique sounds",
        defaultTemperature: 0.5,
        filterTolerance: 0.12
    )

    // MARK: - All Genre Configs
    static let allGenres: [GenreStationConfig] = [
        .pop, .rock, .hipHop, .jazz, .electronic,
        .classical, .country, .latin, .rnb, .indie
    ]

    static func config(for id: String) -> GenreStationConfig? {
        allGenres.first { $0.id == id }
    }
}

// MARK: - Decade Station Config
/// Configuration for decade-based stations
struct DecadeStationConfig: UnifiedStationConfigProtocol {
    let id: String
    let name: String
    let icon: String
    let description: String
    let category: StationCategory = .decade

    let valenceRange: FeatureRange?
    let energyRange: FeatureRange?
    let danceabilityRange: FeatureRange?
    let bpmRange: FeatureRange?
    let acousticnessRange: FeatureRange?
    let instrumentalnessRange: FeatureRange?

    let valenceWeight: Float
    let energyWeight: Float
    let danceabilityWeight: Float
    let bpmWeight: Float
    let acousticnessWeight: Float
    let instrumentalnessWeight: Float

    let suggestedGenres: [String]
    let suggestedDecades: [Int]?
    let moodKeywords: [String]
    let contextDescription: String

    let defaultTemperature: Float
    let filterTolerance: Float
}

// MARK: - Pre-defined Decade Configs
extension DecadeStationConfig {

    static let twenties = DecadeStationConfig(
        id: "2020s",
        name: "2020s",
        icon: "calendar",
        description: "Today's hits and new releases",
        valenceRange: nil,
        energyRange: nil,
        danceabilityRange: nil,
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: [],
        suggestedDecades: [2020],
        moodKeywords: ["current", "trending", "fresh", "contemporary"],
        contextDescription: "Music from 2020 onwards - the latest hits and new releases",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let tens = DecadeStationConfig(
        id: "2010s",
        name: "2010s",
        icon: "calendar",
        description: "Hits from the 2010s",
        valenceRange: nil,
        energyRange: nil,
        danceabilityRange: nil,
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: [],
        suggestedDecades: [2010],
        moodKeywords: ["streaming era", "viral", "EDM", "pop"],
        contextDescription: "Music from 2010-2019 - the streaming and EDM era",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let noughties = DecadeStationConfig(
        id: "2000s",
        name: "2000s",
        icon: "calendar",
        description: "2000s nostalgia",
        valenceRange: nil,
        energyRange: nil,
        danceabilityRange: nil,
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: [],
        suggestedDecades: [2000],
        moodKeywords: ["Y2K", "iPod era", "pop punk", "emo"],
        contextDescription: "Music from 2000-2009 - Y2K, iPod era, pop punk revival",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let nineties = DecadeStationConfig(
        id: "1990s",
        name: "1990s",
        icon: "calendar",
        description: "90s classics",
        valenceRange: nil,
        energyRange: nil,
        danceabilityRange: nil,
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: [],
        suggestedDecades: [1990],
        moodKeywords: ["grunge", "hip hop golden age", "boy bands", "britpop"],
        contextDescription: "Music from 1990-1999 - grunge, hip hop golden age, Britpop",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let eighties = DecadeStationConfig(
        id: "1980s",
        name: "1980s",
        icon: "calendar",
        description: "80s synth and pop",
        valenceRange: nil,
        energyRange: FeatureRange(min: 0.5, max: 0.85),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.85),
        bpmRange: nil,
        acousticnessRange: FeatureRange(min: 0.0, max: 0.5),
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.1,
        bpmWeight: 0.8,
        acousticnessWeight: 0.7,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Synth Pop", "New Wave", "Hair Metal", "Pop"],
        suggestedDecades: [1980],
        moodKeywords: ["synth", "new wave", "MTV", "neon"],
        contextDescription: "Music from 1980-1989 - synth pop, new wave, MTV era",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let seventies = DecadeStationConfig(
        id: "1970s",
        name: "1970s",
        icon: "calendar",
        description: "70s rock and disco",
        valenceRange: nil,
        energyRange: nil,
        danceabilityRange: nil,
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Classic Rock", "Disco", "Punk", "Progressive Rock"],
        suggestedDecades: [1970],
        moodKeywords: ["disco", "classic rock", "funk", "punk"],
        contextDescription: "Music from 1970-1979 - disco, classic rock, punk origins",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let sixties = DecadeStationConfig(
        id: "1960s",
        name: "1960s",
        icon: "calendar",
        description: "60s rock and soul",
        valenceRange: nil,
        energyRange: nil,
        danceabilityRange: nil,
        bpmRange: nil,
        acousticnessRange: nil,
        instrumentalnessRange: nil,
        valenceWeight: 1.0,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.5,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Rock", "Soul", "Motown", "Psychedelic"],
        suggestedDecades: [1960],
        moodKeywords: ["British invasion", "Motown", "psychedelic", "soul"],
        contextDescription: "Music from 1960-1969 - British invasion, Motown, psychedelia",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    static let fifties = DecadeStationConfig(
        id: "1950s",
        name: "1950s",
        icon: "calendar",
        description: "50s rock and roll",
        valenceRange: FeatureRange(min: 0.5, max: 0.9),
        energyRange: FeatureRange(min: 0.4, max: 0.8),
        danceabilityRange: FeatureRange(min: 0.5, max: 0.85),
        bpmRange: nil,
        acousticnessRange: FeatureRange(min: 0.3, max: 0.9),
        instrumentalnessRange: nil,
        valenceWeight: 1.1,
        energyWeight: 1.0,
        danceabilityWeight: 1.0,
        bpmWeight: 0.8,
        acousticnessWeight: 0.8,
        instrumentalnessWeight: 0.5,
        suggestedGenres: ["Rock and Roll", "Doo-Wop", "Jazz", "Blues"],
        suggestedDecades: [1950],
        moodKeywords: ["rock and roll", "doo-wop", "jukebox", "classic"],
        contextDescription: "Music from 1950-1959 - birth of rock and roll, doo-wop era",
        defaultTemperature: 0.5,
        filterTolerance: 0.1
    )

    // MARK: - All Decade Configs
    static let allDecades: [DecadeStationConfig] = [
        .twenties, .tens, .noughties, .nineties,
        .eighties, .seventies, .sixties, .fifties
    ]

    static func config(for id: String) -> DecadeStationConfig? {
        allDecades.first { $0.id == id }
    }
}
