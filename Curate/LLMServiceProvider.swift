//
//  LLMServiceProvider.swift
//  Curate
//
//  Centralized provider for LLM services. Enables dependency injection
//  and runtime swapping between local (on-device) and backend implementations.
//

import Foundation
import SwiftUI

// MARK: - Service Type

enum LLMServiceType: String, CaseIterable {
    case backend = "backend"
    case local = "local"

    var displayName: String {
        switch self {
        case .backend: return "Cloud AI"
        case .local: return "On-Device AI"
        }
    }

    var description: String {
        switch self {
        case .backend: return "Uses server-side AI via Supabase Edge Functions. More capable, requires internet."
        case .local: return "Uses Apple Intelligence on-device. Private, works offline, but may be less capable."
        }
    }

    var icon: String {
        switch self {
        case .backend: return "cloud.fill"
        case .local: return "iphone"
        }
    }
}

// MARK: - LLM Service Provider

/// Provides the active LLM service instance across the app.
/// Supports runtime switching between backend and local services.
@MainActor
@Observable
final class LLMServiceProvider {

    /// Shared singleton instance
    static let shared = LLMServiceProvider()

    /// The currently active LLM service
    private(set) var llmService: LLMStationServiceProtocol

    /// Which service type is currently active
    private(set) var activeServiceType: LLMServiceType

    /// The local LLM provider (for checking availability)
    private(set) var localProvider: LocalLLMProvider?

    /// Whether the local model is available on this device
    var isLocalAvailable: Bool {
        localProvider?.isAvailable ?? false
    }

    /// Reason local model is unavailable (if applicable)
    var localUnavailableReason: String? {
        localProvider?.unavailableReason
    }

    private let backendService: LLMStationServiceProtocol
    private var localService: LLMStationServiceProtocol?

    private init() {
        let backend = BackendStationService()
        let appleProvider = AppleFoundationModelProvider()
        let local = LocalLLMStationService(provider: appleProvider)

        let savedType = UserDefaults.standard.string(forKey: "llmServiceType")
            .flatMap { LLMServiceType(rawValue: $0) } ?? .backend

        let useLocal = savedType == .local && appleProvider.isAvailable

        // Initialize all stored properties before any self usage
        self.backendService = backend
        self.localProvider = appleProvider
        self.localService = local
        self.llmService = useLocal ? local : backend
        self.activeServiceType = useLocal ? .local : .backend

        if useLocal {
            print("🔧 LLMServiceProvider: Using Local AI (Apple Intelligence)")
        } else if savedType == .local {
            print("🔧 LLMServiceProvider: Local AI unavailable, falling back to Backend")
        } else {
            print("🔧 LLMServiceProvider: Using Backend service (Supabase)")
        }
    }

    /// For testing: Create a provider with a specific service
    init(service: LLMStationServiceProtocol, type: LLMServiceType) {
        self.backendService = service
        self.llmService = service
        self.activeServiceType = type
    }

    /// Switch the active service at runtime
    func switchService(to type: LLMServiceType) {
        guard type != activeServiceType else { return }

        switch type {
        case .backend:
            llmService = backendService
            activeServiceType = .backend
            print("🔧 LLMServiceProvider: Switched to Backend service")

        case .local:
            guard let local = localService else {
                print("🔧 LLMServiceProvider: Local service not available")
                return
            }
            llmService = local
            activeServiceType = .local
            print("🔧 LLMServiceProvider: Switched to Local AI")
        }

        // Persist the preference
        UserDefaults.standard.set(type.rawValue, forKey: "llmServiceType")
    }

    /// Register a custom local LLM provider (e.g., llama.cpp, MLX)
    func registerLocalProvider(_ provider: LocalLLMProvider) {
        self.localProvider = provider
        self.localService = LocalLLMStationService(provider: provider)

        // If currently using local, swap to the new provider
        if activeServiceType == .local {
            llmService = self.localService!
            print("🔧 LLMServiceProvider: Updated local provider to \(provider.displayName)")
        }
    }
}

// MARK: - Environment Key

private struct LLMServiceProviderKey: EnvironmentKey {
    @MainActor static let defaultValue: LLMServiceProvider = .shared
}

extension EnvironmentValues {
    var llmServiceProvider: LLMServiceProvider {
        get { self[LLMServiceProviderKey.self] }
        set { self[LLMServiceProviderKey.self] = newValue }
    }
}

// MARK: - View Extension for convenience

extension View {
    /// Injects the LLM service provider into the environment
    func withLLMServiceProvider(_ provider: LLMServiceProvider = .shared) -> some View {
        self.environment(\.llmServiceProvider, provider)
    }
}
