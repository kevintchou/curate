//
//  LocalLLMProvider.swift
//  Curate
//
//  Protocol abstraction for local/on-device language models.
//  Implement this protocol to add new local LLM backends.
//

import Foundation

// MARK: - Local LLM Provider Protocol

/// Abstraction for on-device language models.
/// Conform to this protocol to plug in any local LLM (Apple Foundation Models, llama.cpp, MLX, etc.)
protocol LocalLLMProvider {
    /// Display name for the provider (shown in settings)
    var displayName: String { get }

    /// Whether the model is currently available on this device
    var isAvailable: Bool { get }

    /// A human-readable reason if the model is unavailable
    var unavailableReason: String? { get }

    /// Generate a text response from a prompt
    func generate(prompt: String) async throws -> String

    /// Generate a text response from a system instruction + user prompt
    func generate(system: String, user: String) async throws -> String
}

// MARK: - Default implementation

extension LocalLLMProvider {
    var unavailableReason: String? { nil }

    func generate(system: String, user: String) async throws -> String {
        // Default: concatenate system + user into a single prompt
        try await generate(prompt: "\(system)\n\n\(user)")
    }
}

// MARK: - Errors

enum LocalLLMError: LocalizedError {
    case modelNotAvailable(String)
    case generationFailed(String)
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable(let reason):
            return "Local model not available: \(reason)"
        case .generationFailed(let reason):
            return "Generation failed: \(reason)"
        case .parsingFailed(let reason):
            return "Failed to parse model output: \(reason)"
        }
    }
}
