//
//  TestAuthView.swift
//  Curate
//
//  Created by Kevin Chou on 1/12/26.
//

import SwiftUI
import AuthenticationServices

struct TestAuthView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                Text("Profile")
                    .font(.title)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Auth Status Card
                VStack(spacing: 16) {
                    // Status indicator
                    HStack {
                        Circle()
                            .fill(authManager.isAuthenticated ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(authManager.isAuthenticated ? "Signed In" : "Not Signed In")
                            .font(.headline)
                        Spacer()
                    }

                    Divider()

                    if authManager.isLoading {
                        ProgressView()
                            .padding()
                    } else if authManager.isAuthenticated {
                        // Signed in state
                        signedInContent
                    } else {
                        // Signed out state
                        signedOutContent
                    }
                }
                .padding()
                .background(Color(.systemGray6).opacity(0.5))
                .cornerRadius(16)

                // Error message
                if let error = authManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 160) // Space for bottom bar
        }
    }

    // MARK: - Signed In Content

    @ViewBuilder
    private var signedInContent: some View {
        VStack(spacing: 16) {
            // User info
            if let user = authManager.currentUser {
                VStack(alignment: .leading, spacing: 12) {
                    if let name = user.displayName {
                        infoRow(label: "Name", value: name)
                    }

                    if let email = user.email {
                        infoRow(label: "Email", value: email)
                    }

                    infoRow(label: "User ID", value: String(user.id.uuidString.prefix(8)) + "...")

                    infoRow(label: "Created", value: formatDate(user.createdAt))

                    if let provider = user.provider {
                        infoRow(label: "Provider", value: provider.capitalized)
                    }
                }
            }

            Divider()

            // Sign out button
            Button {
                Task {
                    await authManager.signOut()
                }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign Out")
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }

    // MARK: - Signed Out Content

    @ViewBuilder
    private var signedOutContent: some View {
        VStack(spacing: 16) {
            Text("Sign in to sync your stations and preferences across devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Sign in with Apple button
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { _ in
                // We handle this in AuthManager instead
                Task {
                    await authManager.signInWithApple()
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .cornerRadius(10)
        }
    }

    // MARK: - Helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

#Preview {
    TestAuthView()
        .environmentObject(AuthManager())
        .preferredColorScheme(.dark)
}
