//
//  TestSpotifyLoginView.swift
//  Curate
//
//  Created by Kevin Chou on 11/19/25.
//

import SwiftUI
import AuthenticationServices
import CryptoKit

class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    
    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return anchor
    }
}

struct TestSpotifyLoginView: View {
    @State private var accessToken: String?
    @State private var authorizationStatus: String?
    @State private var loginError: String?
    @State private var hasPremium: Bool?
    @State private var authContextProvider: WebAuthContextProvider?
    @State private var codeVerifier: String?
    
    let clientID = "2bbd31fbbf9e4812b5e7a2026b26380d"
    let redirectURI = "curate://spotify-callback"
    let scopes = "playlist-read-private playlist-read-collaborative user-read-private"
    
    var body: some View {
        VStack(spacing: 20) {
            Button {
                loginToSpotify()
            } label: {
                HStack {
                    Image("Spotify_Primary_Logo_RGB_Black")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 20)
                    Text("Login to Spotify")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            
            Button("Check current status") {
                checkCurrentStatus()
            }
            .buttonStyle(.bordered)
            
            Button("Fetch my playlists") {
                fetchPlaylists()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - PKCE Helpers
    func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - Login to Spotify
    func loginToSpotify() {
        // Generate PKCE values
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)
        
        // Build Spotify authorization URL with PKCE
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        
        guard let authURL = components.url else {
            print("❌ Failed to create authorization URL")
            return
        }
        
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "curate"
        ) { callbackURL, error in
            if let error = error {
                print("❌ Authentication error: \(error.localizedDescription)")
                authorizationStatus = "Failed"
                loginError = error.localizedDescription
                return
            }
            
            guard let callbackURL = callbackURL else {
                print("❌ No callback URL received")
                authorizationStatus = "Failed"
                return
            }
            
            print("📍 Callback URL: \(callbackURL.absoluteString)")
            
            // Parse the authorization code from query params
            if let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems {
                // Check for error
                if let error = queryItems.first(where: { $0.name == "error" })?.value {
                    print("❌ Spotify error: \(error)")
                    authorizationStatus = "Failed"
                    loginError = error
                    return
                }
                
                // Get authorization code
                if let code = queryItems.first(where: { $0.name == "code" })?.value {
                    print("✅ Got authorization code")
                    // Exchange code for access token
                    Task {
                        await exchangeCodeForToken(code: code)
                    }
                    return
                }
            }
            
            print("❌ Failed to extract authorization code")
            authorizationStatus = "Failed"
        }
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            authContextProvider = WebAuthContextProvider(anchor: window)
            session.presentationContextProvider = authContextProvider
        }
        
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }
    
    // MARK: - Exchange Code for Token
    func exchangeCodeForToken(code: String) async {
        guard let verifier = codeVerifier else {
            print("❌ No code verifier found")
            return
        }
        
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ]
        
        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
        
        request.httpBody = bodyString.data(using: .utf8)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response")
                return
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = json["access_token"] as? String {
                    
                    await MainActor.run {
                        accessToken = token
                        authorizationStatus = "Authorized"
                    }
                    
                    print("✅ Successfully got access token")
                    print("Access Token: \(token.prefix(20))...")
                    
                    // Check premium status
                    await checkPremiumStatus(token: token)
                }
            } else {
                print("❌ Token exchange failed: HTTP \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Response: \(errorString)")
                }
            }
        } catch {
            print("❌ Error exchanging code: \(error.localizedDescription)")
        }
    }
     
    
    // MARK: - Check Current Status
    func checkCurrentStatus() {
        print("--- Current Status ---")
        
        if let status = authorizationStatus {
            print("Authorization Status: \(status)")
        } else {
            print("Authorization Status: Not attempted yet")
        }
        
        if let token = accessToken {
            print("Access Token: \(token.prefix(20))...")
            print("Has valid access token: ✅ Yes")
        } else {
            print("Has valid access token: ❌ No")
        }
        
        if let premium = hasPremium {
            print("Spotify Premium: \(premium ? "✅ Yes" : "❌ No (Free tier)")")
        } else {
            print("Spotify Premium: Not checked yet")
        }
        
        if let error = loginError {
            print("Last Error: \(error)")
        }
    }
    
    // MARK: - Check Premium Status
    func checkPremiumStatus(token: String) async {
        print("🔍 Checking premium status...")
        
        do {
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response when checking premium status")
                return
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let product = json["product"] as? String {
                    
                    await MainActor.run {
                        hasPremium = (product == "premium")
                    }
                    
                    print("✅ Spotify Product Type: \(product)")
                    print("✅ Has Premium: \(product == "premium")")
                } else {
                    print("❌ Could not parse product from response")
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("Response: \(responseString)")
                    }
                }
            } else {
                print("❌ Error checking premium status: HTTP \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Response: \(errorString)")
                }
            }
        } catch {
            print("❌ Error checking premium status: \(error.localizedDescription)")
        }
    }
        
    
    // MARK: - Fetch Playlists
    func fetchPlaylists() {
        guard let token = accessToken else {
            print("❌ No access token. Please login first.")
            return
        }
        
        Task {
            do {
                // Create request to fetch user's playlists
                var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/playlists?limit=5")!)
                request.httpMethod = "GET"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid response")
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    // Parse JSON response
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let items = json["items"] as? [[String: Any]] {
                        
                        if items.isEmpty {
                            print("No playlists found")
                        } else {
                            print("First \(items.count) playlists:")
                            for (index, playlist) in items.enumerated() {
                                if let name = playlist["name"] as? String {
                                    print("\(index + 1). \(name)")
                                }
                            }
                        }
                    }
                } else if httpResponse.statusCode == 401 {
                    print("❌ Unauthorized. Access token may be expired.")
                } else {
                    print("❌ Error: HTTP \(httpResponse.statusCode)")
                    if let errorString = String(data: data, encoding: .utf8) {
                        print("Response: \(errorString)")
                    }
                }
            } catch {
                print("❌ Error fetching playlists: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    TestSpotifyLoginView()
}
