//
//  UnifiedMiniPlayerView.swift
//  Curate
//
//  Unified mini player view for all station types
//

import SwiftUI
import MusicKit

struct UnifiedMiniPlayerView: View {
    var curateViewModel: CurateViewModel?
    var llmViewModel: LLMStationViewModel?
    let onTap: () -> Void
    @State private var isPlaying: Bool = false

    private var currentTrack: Track? {
        curateViewModel?.currentTrack ?? llmViewModel?.currentTrack
    }

    private var currentSong: Song? {
        curateViewModel?.currentAppleMusicSong ?? llmViewModel?.currentSong
    }

    // Theme colors
    private let accentColor = Color(red: 0.6, green: 0.2, blue: 0.8)

    var body: some View {
        HStack(spacing: 12) {
            // Album artwork thumbnail
            if let song = currentSong, let artwork = song.artwork {
                ArtworkImage(artwork, width: 44, height: 44)
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(accentColor.opacity(0.3))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.7))
                    )
            }

            // Track info
            if let track = currentTrack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading...")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            // Play/Pause button
            Button {
                Task {
                    let player = SystemMusicPlayer.shared
                    if player.state.playbackStatus == .playing {
                        player.pause()
                    } else {
                        try? await player.play()
                    }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(accentColor)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.15, green: 0.08, blue: 0.2),
                            Color(red: 0.1, green: 0.05, blue: 0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accentColor.opacity(0.3), lineWidth: 0.5)
        }
        .padding(.horizontal, 12)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            onTap()
        }
        .task {
            let player = SystemMusicPlayer.shared
            while !Task.isCancelled {
                let status = player.state.playbackStatus
                isPlaying = (status == .playing)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
