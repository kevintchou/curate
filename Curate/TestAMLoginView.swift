//
//  TestAMLogin.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//

import SwiftUI
import MusicKit

struct TestAMLoginView: View {
    @State private var authStatus: MusicAuthorization.Status?
    @State private var hasSubscription: Bool?
    @State private var canBecomeSubscriber: Bool?
    
    var body: some View {
        VStack(spacing: 20) {
            Button {
                Task {
                    // Check subscription status first
                    do {
                        let subscription = try await MusicSubscription.current
                        hasSubscription = subscription.canPlayCatalogContent
                        canBecomeSubscriber = subscription.canBecomeSubscriber
                        
                        print("Has Apple Music Subscription: \(subscription.canPlayCatalogContent)")
                        print("Can become subscriber: \(subscription.canBecomeSubscriber)")
                        
                        // Only proceed with authorization if user has a subscription
                        if subscription.canPlayCatalogContent {
                            // User has subscription, proceed with authorization
                            let status = await MusicAuthorization.request()
                            authStatus = status
                            print("Authorization status: \(status)")
                            
                            switch status {
                            case .authorized:
                                print("✅ Authorized")
                            case .denied:
                                print("❌ Denied")
                            case .notDetermined:
                                print("⏳ Not determined")
                            case .restricted:
                                print("🔒 Restricted")
                            @unknown default:
                                print("❓ Unknown status")
                            }
                        } else {
                            // User does not have a subscription, don't proceed
                            print("❌ No Apple Music subscription")
                            authStatus = nil
                        }
                    } catch {
                        print("Error checking subscription: \(error)")
                        hasSubscription = nil
                        canBecomeSubscriber = nil
                    }
                }
            } label: {
                Label("Login to Apple Music", systemImage: "apple.logo")
            }
            .buttonStyle(.borderedProminent)
            
            Button("Check Current Status") {
                let status = MusicAuthorization.currentStatus
                print("Current status: \(status)")
                
                if let authStatus = authStatus {
                    print("Stored authorization status: \(authStatus)")
                }
                
                if let hasSubscription = hasSubscription {
                    print("Has Apple Music Subscription: \(hasSubscription ? "✅ Yes" : "❌ No")")
                } else {
                    print("Subscription status: Not checked yet")
                }
                
                if let canBecomeSubscriber = canBecomeSubscriber {
                    print("Can become subscriber: \(canBecomeSubscriber ? "Yes" : "No")")
                }
            }
            .buttonStyle(.bordered)
            
            Button("Fetch My Playlists") {
                Task {
                    do {
                        let request = MusicLibraryRequest<Playlist>()
                        let response = try await request.response()
                        
                        let playlists = Array(response.items.prefix(5))
                        
                        if playlists.isEmpty {
                            print("No playlists found")
                        } else {
                            print("First \(playlists.count) playlists:")
                            for (index, playlist) in playlists.enumerated() {
                                print("\(index + 1). \(playlist.name)")
                            }
                        }
                    } catch {
                        print("Error fetching playlists: \(error)")
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

#Preview {
    TestAMLoginView()
}
