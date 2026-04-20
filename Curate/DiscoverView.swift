//
//  DiscoverView.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//
//  NOTE: This view is kept for testing purposes only.
//  The main app now uses CurateView directly.
//

import SwiftUI

struct DiscoverView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Featured Playlists Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Featured Playlists")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        
                        SnapScrollView {
                            LazyHStack(spacing: 16) {
                                ForEach(0..<10, id: \.self) { index in
                                    PlaylistCard(
                                        title: "Playlist \(index + 1)",
                                        subtitle: "Curated Mix",
                                        imageName: "music.note"
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Recently Played Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recently Played")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        
                        SnapScrollView {
                            LazyHStack(spacing: 16) {
                                ForEach(0..<8, id: \.self) { index in
                                    PlaylistCard(
                                        title: "Recent \(index + 1)",
                                        subtitle: "Last played today",
                                        imageName: "clock.fill"
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Made For You Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Made For You")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        
                        SnapScrollView {
                            LazyHStack(spacing: 16) {
                                ForEach(0..<6, id: \.self) { index in
                                    PlaylistCard(
                                        title: "Daily Mix \(index + 1)",
                                        subtitle: "Personalized for you",
                                        imageName: "sparkles"
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Playlists")
        }
    }
}

// MARK: - Snap Scroll View
struct SnapScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var scrollPosition: Int?
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollPosition)
    }
}

// MARK: - Playlist Card
struct PlaylistCard: View {
    let title: String
    let subtitle: String
    let imageName: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.6),
                                Color.purple.opacity(0.6)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Image(systemName: imageName)
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 160, height: 160)
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            
            // Title
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            
            // Subtitle
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 160)
    }
}

#Preview {
    DiscoverView()
}
