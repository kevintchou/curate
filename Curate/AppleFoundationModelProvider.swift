//
//  AppleFoundationModelProvider.swift
//  Curate
//
//  LocalLLMProvider implementation using Apple's on-device Foundation Models.
//  Requires iOS 26+ / macOS 26+ with Apple Intelligence enabled.
//

import Foundation
import FoundationModels

@MainActor
final class AppleFoundationModelProvider: LocalLLMProvider {
    let displayName = "Apple Intelligence"

    private let model = SystemLanguageModel.default

    var isAvailable: Bool {
        model.availability == .available
    }

    var unavailableReason: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in Settings"
        case .unavailable(.modelNotReady):
            return "Model is downloading or preparing"
        case .unavailable:
            return "Apple Intelligence is not available"
        }
    }

    func generate(prompt: String) async throws -> String {
        guard isAvailable else {
            throw LocalLLMError.modelNotAvailable(unavailableReason ?? "Unknown")
        }

        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func generate(system: String, user: String) async throws -> String {
        guard isAvailable else {
            throw LocalLLMError.modelNotAvailable(unavailableReason ?? "Unknown")
        }

        // Attempt with full input, then retry with progressively shorter user content
        // if the context window is exceeded (Apple Intelligence cap: 4096 tokens).
        var attempt = user
        for truncationFactor in [1.0, 0.6, 0.35] {
            if truncationFactor < 1.0 {
                let limit = Int(Double(user.count) * truncationFactor)
                attempt = String(user.prefix(limit)) + "\n...(trimmed for context limit)"
            }
            do {
                let session = LanguageModelSession(instructions: system)
                let response = try await session.respond(to: attempt)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    // Will retry with smaller truncationFactor on next iteration
                    continue
                }
                throw error
            }
        }

        // All retries exhausted — throw a clear error
        throw LocalLLMError.modelNotAvailable("Input too large for on-device model even after trimming")
    }
}
