//
//  AuthManager.swift
//  Curate
//
//  Created by Kevin Chou on 1/12/26.
//

import AuthenticationServices
import Combine
import SwiftUI
import Supabase

// MARK: - User Info Model (to avoid importing Auth module)

struct UserInfo {
    let id: UUID
    let email: String?
    let displayName: String?
    let createdAt: Date
    let provider: String?
}

// MARK: - Profile Update Model

private struct ProfileUpdate: Encodable {
    let display_name: String
}

// MARK: - Auth Manager

class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var currentUser: UserInfo?
    @Published var errorMessage: String?

    private let supabase = SupabaseConfig.client

    init() {
        Task { @MainActor in
            await checkSession()
        }
    }

    /// Check for existing session on app launch
    @MainActor
    func checkSession() async {
        isLoading = true
        do {
            let session = try await supabase.auth.session
            let displayName = await fetchDisplayName(userId: session.user.id)

            currentUser = UserInfo(
                id: session.user.id,
                email: session.user.email,
                displayName: displayName,
                createdAt: session.user.createdAt,
                provider: session.user.appMetadata["provider"]?.value as? String
            )
            isAuthenticated = true
        } catch {
            isAuthenticated = false
            currentUser = nil
        }
        isLoading = false
    }

    /// Sign in with Apple
    @MainActor
    func signInWithApple() async {
        isLoading = true
        errorMessage = nil

        do {
            let helper = AppleSignInHelper()
            let result = try await helper.performSignIn()

            guard let appleIDCredential = result.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: identityToken, encoding: .utf8) else {
                throw AuthError.invalidCredential
            }

            // Extract full name from Apple credential (only available on first sign-in)
            let fullName = appleIDCredential.fullName
            let displayName = [fullName?.givenName, fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty

            // Sign in to Supabase with the Apple ID token
            let session = try await supabase.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: idTokenString
                )
            )

            // If we got a name from Apple, update the profile
            if let name = displayName {
                await updateDisplayName(userId: session.user.id, name: name)
            }

            // Fetch the display name (either just set or previously stored)
            let storedDisplayName = await fetchDisplayName(userId: session.user.id)

            currentUser = UserInfo(
                id: session.user.id,
                email: session.user.email,
                displayName: storedDisplayName,
                createdAt: session.user.createdAt,
                provider: session.user.appMetadata["provider"]?.value as? String
            )
            isAuthenticated = true

        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User canceled - don't show error
            print("Apple Sign-In: User canceled")
            errorMessage = nil
        } catch let error as ASAuthorizationError {
            print("Apple Sign-In ASAuthorizationError: \(error.code.rawValue) - \(error.localizedDescription)")
            errorMessage = "Apple Sign-In failed (code: \(error.code.rawValue))"
        } catch {
            print("Apple Sign-In error: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Sign out
    @MainActor
    func signOut() async {
        isLoading = true
        do {
            try await supabase.auth.signOut()
            isAuthenticated = false
            currentUser = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Profile Helpers

    /// Fetch display name from profiles table
    private func fetchDisplayName(userId: UUID) async -> String? {
        do {
            let response: [ProfileResponse] = try await supabase
                .from("profiles")
                .select("display_name")
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value

            return response.first?.display_name
        } catch {
            print("Failed to fetch display name: \(error)")
            return nil
        }
    }

    /// Update display name in profiles table
    private func updateDisplayName(userId: UUID, name: String) async {
        do {
            try await supabase
                .from("profiles")
                .update(ProfileUpdate(display_name: name))
                .eq("id", value: userId.uuidString)
                .execute()
        } catch {
            print("Failed to update display name: \(error)")
        }
    }
}

// MARK: - Profile Response Model

private struct ProfileResponse: Decodable {
    let display_name: String?
}

// MARK: - String Extension

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Apple Sign In Helper

private class AppleSignInHelper: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    @MainActor
    func performSignIn() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            fatalError("No window found")
        }
        return window
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Invalid Apple ID credential"
        }
    }
}
