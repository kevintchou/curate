//
//  AppleFoundationModelService.swift
//  Curate
//
//  Created by Kevin Chou on 12/23/24.
//

import Foundation
import FoundationModels

@MainActor
@Observable
class AppleFoundationModelService {
    // Reference to the system language model
    private let model = SystemLanguageModel.default

    var isAvailable: Bool {
        model.availability == .available
    }

    var availability: SystemLanguageModel.Availability {
        model.availability
    }

    /// Generate a response from the Apple Foundation Model
    func generateResponse(for prompt: String) async throws -> String {
        guard model.availability == .available else {
            throw AppleFoundationModelError.modelNotAvailable
        }

        // Create a new session
        let session = LanguageModelSession()

        // Generate response from the model
        let response = try await session.respond(to: prompt)

        return response.content
    }
}

// MARK: - Error Types

enum AppleFoundationModelError: LocalizedError {
    case modelNotAvailable

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable:
            return "Apple Foundation Model is not available"
        }
    }
}
