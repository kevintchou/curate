//
//  LibraryPlaylistsView.swift
//  Curate
//
//  Displays the user's Apple Music library playlists.
//

import SwiftUI
import MusicKit

struct LibraryPlaylistsView: View {
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isLoading && playlists.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 60)
                } else if let errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.4))
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 60)
                } else if playlists.isEmpty {
                    Text("No playlists")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 60)
                } else {
                    ForEach(playlists, id: \.id) { playlist in
                        playlistRow(playlist)
                        Divider()
                            .background(Color.white.opacity(0.08))
                            .padding(.leading, 80)
                    }
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await loadPlaylists()
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(playlist.artwork, width: 56, height: 56)
                .cornerRadius(6)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let curator = playlist.curatorName {
                    Text(curator)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func loadPlaylists() async {
        guard playlists.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                errorMessage = "Apple Music access required"
                isLoading = false
                return
            }

            var request = MusicLibraryRequest<Playlist>()
            request.limit = 100
            let response = try await request.response()
            playlists = Array(response.items)
        } catch {
            errorMessage = "Failed to load playlists"
            print("LibraryPlaylists error: \(error)")
        }
        isLoading = false
    }
}

// MARK: - Artwork Helper

private struct ArtworkImage: View {
    let artwork: Artwork?
    let width: Int
    let height: Int

    init(_ artwork: Artwork?, width: Int, height: Int) {
        self.artwork = artwork
        self.width = width
        self.height = height
    }

    var body: some View {
        if let artwork, let url = artwork.url(width: width * 2, height: height * 2) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.08)
            }
        } else {
            Image(systemName: "music.note.list")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: CGFloat(width), height: CGFloat(height))
        }
    }
}
