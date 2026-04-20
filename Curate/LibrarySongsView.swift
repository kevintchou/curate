//
//  LibrarySongsView.swift
//  Curate
//
//  Displays the user's Apple Music library songs.
//

import SwiftUI
import MusicKit

struct LibrarySongsView: View {
    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isLoading && songs.isEmpty {
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
                } else if songs.isEmpty {
                    Text("No songs in your library")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 60)
                } else {
                    ForEach(songs, id: \.id) { song in
                        Button {
                            Task { await playSong(song) }
                        } label: {
                            songRow(song)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .background(Color.white.opacity(0.08))
                            .padding(.leading, 80)
                    }
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await loadSongs()
        }
    }

    @ViewBuilder
    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            SongArtworkImage(artwork: song.artwork, size: 48)
                .frame(width: 48, height: 48)
                .cornerRadius(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func loadSongs() async {
        guard songs.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                errorMessage = "Apple Music access required"
                isLoading = false
                return
            }

            var request = MusicLibraryRequest<Song>()
            request.limit = 500
            let response = try await request.response()
            songs = Array(response.items)
        } catch {
            errorMessage = "Failed to load songs"
            print("LibrarySongs error: \(error)")
        }
        isLoading = false
    }

    private func playSong(_ song: Song) async {
        do {
            let player = SystemMusicPlayer.shared
            player.queue = [song]
            try await player.play()
        } catch {
            print("Play song error: \(error)")
        }
    }
}

// MARK: - Artwork Helper

private struct SongArtworkImage: View {
    let artwork: Artwork?
    let size: Int

    var body: some View {
        if let artwork, let url = artwork.url(width: size * 2, height: size * 2) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.08)
            }
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: CGFloat(size), height: CGFloat(size))
        }
    }
}
