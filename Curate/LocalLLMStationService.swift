//
//  LocalLLMStationService.swift
//  Curate
//
//  LLMStationServiceProtocol implementation that runs entirely on-device
//  using any LocalLLMProvider (Apple Foundation Models, llama.cpp, etc.)
//

import Foundation

final class LocalLLMStationService: LLMStationServiceProtocol {
    private let provider: LocalLLMProvider

    init(provider: LocalLLMProvider) {
        self.provider = provider
    }

    // MARK: - Generate Config

    func generateConfig(from prompt: String, tasteProfile: LLMTasteProfile?) async throws -> LLMStationConfig {
        let system = """
        You are a music station curator. Given a user's request, generate a JSON music station configuration.
        Respond ONLY with valid JSON, no other text.

        The JSON must have this exact structure:
        {
          "name": "Station Name",
          "description": "Brief description of the vibe",
          "originalPrompt": "the user's original request",
          "valenceRange": {"min": 0.0, "max": 1.0},
          "energyRange": {"min": 0.0, "max": 1.0},
          "danceabilityRange": {"min": 0.0, "max": 1.0},
          "bpmRange": {"min": 0.0, "max": 1.0},
          "acousticnessRange": {"min": 0.0, "max": 1.0},
          "instrumentalnessRange": {"min": 0.0, "max": 1.0},
          "valenceWeight": 1.0,
          "energyWeight": 1.0,
          "danceabilityWeight": 0.8,
          "bpmWeight": 0.8,
          "acousticnessWeight": 0.5,
          "instrumentalnessWeight": 0.5,
          "suggestedGenres": ["Genre1", "Genre2"],
          "suggestedDecades": [2010, 2020],
          "moodKeywords": ["keyword1", "keyword2"],
          "contextDescription": "Detailed vibe description"
        }

        All range values are 0.0-1.0 floats. BPM is normalized (0=60bpm, 1=200bpm).
        Weights indicate importance (0.0-2.0). Set ranges to null if not relevant.
        """

        var userPrompt = "Create a music station for: \(prompt)"
        if let taste = tasteProfile, !taste.preferredGenres.isEmpty {
            userPrompt += "\n\nUser preferences: likes \(taste.preferredGenres.joined(separator: ", "))"
            if !taste.avoidedGenres.isEmpty {
                userPrompt += ", avoids \(taste.avoidedGenres.joined(separator: ", "))"
            }
            userPrompt += ", energy: \(taste.energyPreference), mood: \(taste.moodPreference)"
        }

        let response = try await provider.generate(system: system, user: userPrompt)
        return try parseConfig(from: response, originalPrompt: prompt)
    }

    // MARK: - Suggest Songs

    func suggestSongs(request: LLMSongRequest) async throws -> [LLMSongSuggestion] {
        let system = """
        You are a music recommendation engine. Suggest songs that match the station configuration.
        Respond ONLY with a JSON array, no other text.

        Each song object must have:
        {
          "title": "Song Title",
          "artist": "Artist Name",
          "album": "Album Name",
          "year": 2020,
          "reason": "Why this fits",
          "estimatedBpm": 120,
          "estimatedEnergy": 0.7,
          "estimatedValence": 0.6,
          "estimatedDanceability": 0.5,
          "estimatedAcousticness": 0.2,
          "estimatedInstrumentalness": 0.0
        }

        BPM is actual BPM (60-200). All other values are 0.0-1.0.
        Suggest real, well-known songs. Do not invent songs.
        """

        var userPrompt = "Station: \(request.config.name) - \(request.config.description)\n"
        userPrompt += "Genres: \(request.config.suggestedGenres.joined(separator: ", "))\n"
        userPrompt += "Mood: \(request.config.moodKeywords.joined(separator: ", "))\n"
        userPrompt += "Suggest \(request.count) songs."

        if !request.likedSongs.isEmpty {
            let liked = request.likedSongs.map { "\($0.title) by \($0.artist)" }.joined(separator: ", ")
            userPrompt += "\nUser liked: \(liked)"
        }
        if !request.dislikedSongs.isEmpty {
            let disliked = request.dislikedSongs.map { "\($0.title) by \($0.artist)" }.joined(separator: ", ")
            userPrompt += "\nUser disliked: \(disliked)"
        }
        if !request.recentlyPlayed.isEmpty {
            userPrompt += "\nAvoid these (recently played): \(request.recentlyPlayed.joined(separator: ", "))"
        }

        let response = try await provider.generate(system: system, user: userPrompt)
        return try parseSongs(from: response)
    }

    // MARK: - Analyze Taste

    func analyzeTaste(
        originalPrompt: String,
        currentProfile: LLMTasteProfile?,
        feedbackSummary: StationFeedbackSummary
    ) async throws -> LLMTasteProfile {
        let system = """
        You are a music taste analyst. Based on user feedback, generate an updated taste profile.
        Respond ONLY with valid JSON, no other text.

        The JSON must have:
        {
          "preferredGenres": ["Genre1"],
          "avoidedGenres": ["Genre2"],
          "preferredArtists": ["Artist1"],
          "avoidedArtists": ["Artist2"],
          "preferredDecades": [2010, 2020],
          "energyPreference": "medium",
          "moodPreference": "happy",
          "notablePatterns": ["pattern1"]
        }

        energyPreference: "low", "medium", "high", or "varied"
        moodPreference: "happy", "melancholic", "intense", "calm", or "varied"
        """

        var userPrompt = "Station prompt: \(originalPrompt)\n"
        userPrompt += "Likes: \(feedbackSummary.totalLikes), Dislikes: \(feedbackSummary.totalDislikes), Skips: \(feedbackSummary.totalSkips)\n"

        if !feedbackSummary.likedSongs.isEmpty {
            let liked = feedbackSummary.likedSongs.map { "\($0.title) by \($0.artist)" }.joined(separator: ", ")
            userPrompt += "Liked songs: \(liked)\n"
        }
        if !feedbackSummary.dislikedSongs.isEmpty {
            let disliked = feedbackSummary.dislikedSongs.map { "\($0.title) by \($0.artist)" }.joined(separator: ", ")
            userPrompt += "Disliked songs: \(disliked)\n"
        }

        if let current = currentProfile {
            userPrompt += "Current preferences: genres=\(current.preferredGenres.joined(separator: ",")), energy=\(current.energyPreference), mood=\(current.moodPreference)\n"
        }

        let response = try await provider.generate(system: system, user: userPrompt)
        return try parseTasteProfile(from: response, feedbackCount: feedbackSummary.totalLikes + feedbackSummary.totalDislikes)
    }

    // MARK: - Generate Artist Seeds

    func generateArtistSeeds(
        config: LLMStationConfig,
        tasteSummary: String,
        avoidArtists: [String],
        count: Int,
        temperature: Double,
        preferredGenres: [String],
        nonPreferredGenres: [String]
    ) async throws -> [ArtistSeed] {
        let system = """
        You are a music recommendation engine. Suggest artists that would seed a great radio station.
        Respond ONLY with a JSON array, no other text.

        Each artist object must have:
        {
          "name": "Artist Name",
          "reason": "Why this artist fits",
          "similarityType": "direct",
          "expectedGenres": ["Genre1", "Genre2"]
        }

        similarityType must be one of: "direct" (core match), "adjacent" (related style), "discovery" (stretch pick).
        Include a mix: ~50% direct, ~30% adjacent, ~20% discovery.
        """

        var userPrompt = "Station: \(config.name) - \(config.description)\n"
        userPrompt += "Genres: \(config.suggestedGenres.joined(separator: ", "))\n"
        userPrompt += "Mood: \(config.moodKeywords.joined(separator: ", "))\n"
        userPrompt += "Suggest \(count) artists."

        if !tasteSummary.isEmpty {
            userPrompt += "\nUser taste: \(tasteSummary)"
        }
        if !avoidArtists.isEmpty {
            userPrompt += "\nAvoid: \(avoidArtists.joined(separator: ", "))"
        }
        if !preferredGenres.isEmpty {
            userPrompt += "\nPreferred genres: \(preferredGenres.joined(separator: ", "))"
        }
        if !nonPreferredGenres.isEmpty {
            userPrompt += "\nAvoid genres: \(nonPreferredGenres.joined(separator: ", "))"
        }

        let explorationNote = temperature > 0.7 ? "\nBe adventurous and suggest unexpected artists." :
                              temperature < 0.3 ? "\nStick closely to the core style." : ""
        userPrompt += explorationNote

        let response = try await provider.generate(system: system, user: userPrompt)
        return try parseArtistSeeds(from: response)
    }

    // MARK: - JSON Parsing Helpers

    private func extractJSON(from text: String) -> String {
        // Try to find JSON within the response (handle markdown code blocks, preamble, etc.)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for ```json ... ``` blocks
        if let jsonBlockRange = trimmed.range(of: "```json\n", options: .caseInsensitive),
           let endRange = trimmed.range(of: "\n```", options: .caseInsensitive, range: jsonBlockRange.upperBound..<trimmed.endIndex) {
            return String(trimmed[jsonBlockRange.upperBound..<endRange.lowerBound])
        }

        // Check for ``` ... ``` blocks
        if let start = trimmed.range(of: "```\n"),
           let end = trimmed.range(of: "\n```", range: start.upperBound..<trimmed.endIndex) {
            return String(trimmed[start.upperBound..<end.lowerBound])
        }

        // Find first { or [ to last } or ]
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            return String(trimmed[firstBrace...lastBrace])
        }
        if let firstBracket = trimmed.firstIndex(of: "["),
           let lastBracket = trimmed.lastIndex(of: "]") {
            return String(trimmed[firstBracket...lastBracket])
        }

        return trimmed
    }

    private func parseConfig(from text: String, originalPrompt: String) throws -> LLMStationConfig {
        let json = extractJSON(from: text)
        guard let data = json.data(using: .utf8) else {
            throw LocalLLMError.parsingFailed("Invalid UTF-8 in response")
        }

        let decoder = JSONDecoder()

        // Try direct decode first
        if let config = try? decoder.decode(LLMStationConfig.self, from: data) {
            return config
        }

        // Fallback: parse as dictionary and build manually
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalLLMError.parsingFailed("Could not parse config JSON")
        }

        func parseRange(_ key: String) -> FeatureRangeLLM? {
            guard let r = dict[key] as? [String: Any],
                  let min = (r["min"] as? NSNumber)?.floatValue,
                  let max = (r["max"] as? NSNumber)?.floatValue else { return nil }
            return FeatureRangeLLM(min: min, max: max)
        }

        func floatVal(_ key: String, default defaultVal: Float) -> Float {
            (dict[key] as? NSNumber)?.floatValue ?? defaultVal
        }

        return LLMStationConfig(
            name: dict["name"] as? String ?? originalPrompt,
            description: dict["description"] as? String ?? "Custom station",
            originalPrompt: originalPrompt,
            valenceRange: parseRange("valenceRange"),
            energyRange: parseRange("energyRange"),
            danceabilityRange: parseRange("danceabilityRange"),
            bpmRange: parseRange("bpmRange"),
            acousticnessRange: parseRange("acousticnessRange"),
            instrumentalnessRange: parseRange("instrumentalnessRange"),
            valenceWeight: floatVal("valenceWeight", default: 1.0),
            energyWeight: floatVal("energyWeight", default: 1.0),
            danceabilityWeight: floatVal("danceabilityWeight", default: 0.8),
            bpmWeight: floatVal("bpmWeight", default: 0.8),
            acousticnessWeight: floatVal("acousticnessWeight", default: 0.5),
            instrumentalnessWeight: floatVal("instrumentalnessWeight", default: 0.5),
            suggestedGenres: dict["suggestedGenres"] as? [String] ?? [],
            suggestedDecades: dict["suggestedDecades"] as? [Int],
            moodKeywords: dict["moodKeywords"] as? [String] ?? [],
            contextDescription: dict["contextDescription"] as? String ?? ""
        )
    }

    private func parseSongs(from text: String) throws -> [LLMSongSuggestion] {
        let json = extractJSON(from: text)
        guard let data = json.data(using: .utf8) else {
            throw LocalLLMError.parsingFailed("Invalid UTF-8 in response")
        }

        // Try direct decode
        if let songs = try? JSONDecoder().decode([LLMSongSuggestion].self, from: data) {
            return songs
        }

        // Fallback: parse as array of dictionaries
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LocalLLMError.parsingFailed("Could not parse songs JSON")
        }

        return arr.compactMap { dict -> LLMSongSuggestion? in
            guard let title = dict["title"] as? String,
                  let artist = dict["artist"] as? String else { return nil }

            return LLMSongSuggestion(
                title: title,
                artist: artist,
                album: dict["album"] as? String,
                year: dict["year"] as? Int,
                reason: dict["reason"] as? String ?? "Fits the vibe",
                estimatedBpm: (dict["estimatedBpm"] as? NSNumber)?.floatValue,
                estimatedEnergy: (dict["estimatedEnergy"] as? NSNumber)?.floatValue,
                estimatedValence: (dict["estimatedValence"] as? NSNumber)?.floatValue,
                estimatedDanceability: (dict["estimatedDanceability"] as? NSNumber)?.floatValue,
                estimatedAcousticness: (dict["estimatedAcousticness"] as? NSNumber)?.floatValue,
                estimatedInstrumentalness: (dict["estimatedInstrumentalness"] as? NSNumber)?.floatValue
            )
        }
    }

    private func parseTasteProfile(from text: String, feedbackCount: Int) throws -> LLMTasteProfile {
        let json = extractJSON(from: text)
        guard let data = json.data(using: .utf8) else {
            throw LocalLLMError.parsingFailed("Invalid UTF-8 in response")
        }

        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalLLMError.parsingFailed("Could not parse taste profile JSON")
        }

        return LLMTasteProfile(
            preferredGenres: dict["preferredGenres"] as? [String] ?? [],
            avoidedGenres: dict["avoidedGenres"] as? [String] ?? [],
            preferredArtists: dict["preferredArtists"] as? [String] ?? [],
            avoidedArtists: dict["avoidedArtists"] as? [String] ?? [],
            preferredDecades: dict["preferredDecades"] as? [Int] ?? [],
            energyPreference: dict["energyPreference"] as? String ?? "varied",
            moodPreference: dict["moodPreference"] as? String ?? "varied",
            notablePatterns: dict["notablePatterns"] as? [String] ?? [],
            lastUpdatedAt: Date(),
            feedbackCountAtUpdate: feedbackCount
        )
    }

    private func parseArtistSeeds(from text: String) throws -> [ArtistSeed] {
        let json = extractJSON(from: text)
        guard let data = json.data(using: .utf8) else {
            throw LocalLLMError.parsingFailed("Invalid UTF-8 in response")
        }

        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LocalLLMError.parsingFailed("Could not parse artist seeds JSON")
        }

        return arr.compactMap { dict -> ArtistSeed? in
            guard let name = dict["name"] as? String else { return nil }

            let similarityTypeStr = dict["similarityType"] as? String ?? "direct"
            let similarityType = SimilarityType(rawValue: similarityTypeStr) ?? .direct

            return ArtistSeed(
                name: name,
                reason: dict["reason"] as? String ?? "Fits the station vibe",
                similarityType: similarityType,
                expectedGenres: dict["expectedGenres"] as? [String]
            )
        }
    }
}
