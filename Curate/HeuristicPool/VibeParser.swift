//
//  VibeParser.swift
//  Curate
//
//  Rule-based parser for extracting mood, activity, and time context
//  from natural language user input. Runs entirely on-device.
//
//  Future: Add Core ML model for handling ambiguous inputs.
//

import Foundation

// MARK: - Protocol

protocol VibeParserProtocol {
    /// Parse user input into a structured vibe representation
    func parse(input: String) -> ParsedVibe
}

// MARK: - Rule-Based Implementation

/// Rule-based vibe parser using keyword matching
final class RuleBasedVibeParser: VibeParserProtocol {

    // MARK: - Dependencies

    private let moodKeywords: MoodKeywordMappings
    private let genreSynonyms: GenreSynonymMappings

    // MARK: - Configuration

    private let maxInputLength = 200
    private let minTokenLength = 2

    // MARK: - Initialization

    init(
        moodKeywords: MoodKeywordMappings? = nil,
        genreSynonyms: GenreSynonymMappings? = nil
    ) {
        self.moodKeywords = moodKeywords ?? MoodKeywordMappings.loadFromBundle()
        self.genreSynonyms = genreSynonyms ?? GenreSynonymMappings.loadFromBundle()
    }

    // MARK: - Parse

    func parse(input: String) -> ParsedVibe {
        // 1. Sanitize and tokenize
        let sanitized = sanitize(input)
        let tokens = tokenize(sanitized)

        guard !tokens.isEmpty else {
            return ParsedVibe.empty(input: input)
        }

        // 2. Extract moods
        let moods = extractMoods(from: tokens)

        // 3. Extract activity
        let activity = extractActivity(from: tokens)

        // 4. Extract time context
        let timeContext = extractTimeContext(from: tokens)

        // 5. Calculate confidence
        let confidence = calculateConfidence(
            moods: moods,
            activity: activity,
            timeContext: timeContext,
            tokenCount: tokens.count
        )

        print("🎯 VibeParser: \"\(input)\" → moods: \(moods.map { $0.rawValue }), " +
              "activity: \(activity?.rawValue ?? "nil"), " +
              "time: \(timeContext?.rawValue ?? "nil"), " +
              "confidence: \(String(format: "%.2f", confidence))")

        return ParsedVibe(
            rawInput: input,
            moods: moods,
            activity: activity,
            timeContext: timeContext,
            confidence: confidence
        )
    }

    // MARK: - Sanitization

    /// Sanitize user input to prevent issues and normalize text
    private func sanitize(_ input: String) -> String {
        var result = input

        // Truncate to max length
        if result.count > maxInputLength {
            result = String(result.prefix(maxInputLength))
        }

        // Remove special characters that could cause issues
        let allowedCharacters = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-'&"))

        result = result.unicodeScalars
            .filter { allowedCharacters.contains($0) }
            .map { Character($0) }
            .reduce("") { $0 + String($1) }

        // Normalize whitespace
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return result.lowercased()
    }

    // MARK: - Tokenization

    /// Tokenize input into searchable tokens
    private func tokenize(_ input: String) -> [String] {
        // Split by whitespace
        var tokens = input.components(separatedBy: .whitespaces)
            .filter { $0.count >= minTokenLength }

        // Also create n-grams for multi-word phrases
        let words = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Bigrams
        for i in 0..<max(0, words.count - 1) {
            tokens.append("\(words[i]) \(words[i + 1])")
        }

        // Trigrams
        for i in 0..<max(0, words.count - 2) {
            tokens.append("\(words[i]) \(words[i + 1]) \(words[i + 2])")
        }

        return tokens
    }

    // MARK: - Mood Extraction

    /// Extract mood categories from tokens
    private func extractMoods(from tokens: [String]) -> [MoodCategory] {
        let matchingMoods = moodKeywords.matchingMoods(for: tokens)

        // Take top 3 moods by match count
        let topMoods = matchingMoods.prefix(3).map { $0.0 }

        // If no moods found, try to infer from common patterns
        if topMoods.isEmpty {
            return inferMoodsFromPatterns(tokens: tokens)
        }

        return Array(topMoods)
    }

    /// Infer moods when keyword matching fails
    private func inferMoodsFromPatterns(tokens: [String]) -> [MoodCategory] {
        let joinedInput = tokens.joined(separator: " ")

        // Common pattern inference
        if joinedInput.contains("vibe") || joinedInput.contains("vibes") {
            return [.chill]
        }

        if joinedInput.contains("good") || joinedInput.contains("nice") {
            return [.uplifting]
        }

        if joinedInput.contains("music") || joinedInput.contains("songs") {
            // Generic request, return empty to trigger low confidence
            return []
        }

        return []
    }

    // MARK: - Activity Extraction

    /// Extract activity context from tokens
    private func extractActivity(from tokens: [String]) -> ActivityContext? {
        return ActivityKeywords.matchingActivity(for: tokens)
    }

    // MARK: - Time Context Extraction

    /// Extract time-of-day context from tokens
    private func extractTimeContext(from tokens: [String]) -> TimeContext? {
        return TimeContextKeywords.matchingTimeContext(for: tokens)
    }

    // MARK: - Confidence Calculation

    /// Calculate confidence score based on parse results
    private func calculateConfidence(
        moods: [MoodCategory],
        activity: ActivityContext?,
        timeContext: TimeContext?,
        tokenCount: Int
    ) -> Float {
        var confidence: Float = 0.0

        // Mood contribution (most important)
        switch moods.count {
        case 0:
            confidence += 0.0
        case 1:
            confidence += 0.4
        case 2:
            confidence += 0.5
        default:
            confidence += 0.55
        }

        // Activity contribution
        if activity != nil {
            confidence += 0.25
        }

        // Time context contribution
        if timeContext != nil {
            confidence += 0.15
        }

        // Token count contribution (more specific inputs are better)
        if tokenCount >= 3 {
            confidence += 0.05
        }

        // Cap at 1.0
        return min(1.0, confidence)
    }
}

// MARK: - Mock Implementation for Testing

final class MockVibeParser: VibeParserProtocol {
    var mockResult: ParsedVibe?
    var parseCallCount = 0
    var lastInput: String?

    func parse(input: String) -> ParsedVibe {
        parseCallCount += 1
        lastInput = input

        if let mock = mockResult {
            return mock
        }

        // Return a default mock
        return ParsedVibe(
            rawInput: input,
            moods: [.chill, .relaxed],
            activity: nil,
            timeContext: nil,
            confidence: 0.7
        )
    }
}
