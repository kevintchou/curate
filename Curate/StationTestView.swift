//
//  StationTestView.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//
//  LEGACY CODE - DISABLED
//  ======================
//  This View used the Thompson Sampling StationTestViewModel which has been
//  replaced by the HybridRecommender in the CandidatePool/ folder.
//
//  The hybrid candidate pool architecture provides better recommendations with:
//  - Global pools shared across users (reduces API calls ~90%)
//  - Per-user overlays for personalization
//  - LLM-only for intent parsing, not per-track decisions
//
//  See HYBRID_CANDIDATE_POOL_PLAN.md for architecture details.
//
//  To re-enable: Uncomment the code below and uncomment StationTestViewModel
//  in StationTestViewModel.swift.
//

import Foundation

/*
// LEGACY: Thompson Sampling Test View
// ====================================
// Commented out in favor of HybridRecommender.
// Preserved for reference and potential A/B testing.

import SwiftUI
import MusicKit

/// Test view for the Thompson Sampling recommendation engine
struct StationTestView: View {
    @State private var viewModel = StationTestViewModel()
    @FocusState private var isSearchFocused: Bool
    @State private var showDebugLog: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // Search Section
                searchSection

                // Station Controls
                if viewModel.isStationActive {
                    stationControlsSection
                }

                // Stats
                statsSection

                // Debug Log Toggle
                debugSection
            }
            .padding()
            .padding(.bottom, 110) // Add space for bottom input area
        }
        .onTapGesture {
            isSearchFocused = false
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.blue)

            Text("Station Test")
                .font(.title2)
                .fontWeight(.bold)

            Text("Thompson Sampling Recommendation Engine")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    // MARK: - Search Section

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seed Song")
                .font(.headline)

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search for a song to seed...", text: $viewModel.searchQuery)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            // Search results
            if !viewModel.searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(viewModel.searchResults, id: \.id) { song in
                        Button {
                            viewModel.selectSeedSong(song)
                            isSearchFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                // Album artwork
                                if let artwork = song.artwork {
                                    ArtworkImage(artwork, width: 44, height: 44)
                                        .cornerRadius(6)
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Image(systemName: "music.note")
                                                .foregroundStyle(.secondary)
                                        )
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(song.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if song.contentRating == .explicit {
                                            Text("E")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 3)
                                                .padding(.vertical, 1)
                                                .background(Color.red)
                                                .cornerRadius(2)
                                        }
                                    }

                                    Text(song.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if viewModel.selectedSeedSong?.id == song.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if song.id != viewModel.searchResults.last?.id {
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }

            // Selected seed display
            if let seed = viewModel.selectedSeedSong, viewModel.searchResults.isEmpty {
                HStack(spacing: 12) {
                    if let artwork = seed.artwork {
                        ArtworkImage(artwork, width: 60, height: 60)
                            .cornerRadius(8)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(seed.title)
                            .font(.headline)
                        Text(seed.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let isrc = seed.isrc {
                            Text("ISRC: \(isrc)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if !viewModel.isStationActive {
                        Button {
                            Task {
                                await viewModel.startStation()
                            }
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }

            // Status message
            if !viewModel.stationStatus.isEmpty {
                Text(viewModel.stationStatus)
                    .font(.subheadline)
                    .foregroundStyle(viewModel.stationStatus.contains("❌") ? .red : .secondary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Station Controls Section

    private var stationControlsSection: some View {
        VStack(spacing: 16) {
            // Now Playing
            if let track = viewModel.currentTrack {
                VStack(spacing: 8) {
                    Text("Now Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(track.title)
                        .font(.headline)

                    Text(track.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Track features
                    HStack(spacing: 16) {
                        featureBadge(label: "BPM", value: track.bpm.map { String(Int($0)) } ?? "-")
                        featureBadge(label: "Energy", value: track.energy.map { String(format: "%.1f", $0) } ?? "-")
                        featureBadge(label: "Dance", value: track.danceability.map { String(format: "%.1f", $0) } ?? "-")
                    }
                    .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
            } else if let seed = viewModel.currentAppleMusicSong {
                VStack(spacing: 8) {
                    Text("Now Playing (Seed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(seed.title)
                        .font(.headline)

                    Text(seed.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.1))
                .cornerRadius(12)
            }

            // Playback controls
            HStack(spacing: 24) {
                // Dislike
                Button {
                    viewModel.dislike()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "hand.thumbsdown.fill")
                            .font(.system(size: 28))
                        Text("Dislike")
                            .font(.caption2)
                    }
                    .foregroundStyle(.red)
                }

                // Skip
                Button {
                    viewModel.skip()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 28))
                        Text("Skip")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                // Next (primary)
                Button {
                    Task {
                        await viewModel.playNext()
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                }
                .disabled(viewModel.isLoadingNextTrack)

                // Like
                Button {
                    viewModel.like()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup.fill")
                            .font(.system(size: 28))
                        Text("Like")
                            .font(.caption2)
                    }
                    .foregroundStyle(.green)
                }

                // Stop
                Button {
                    viewModel.stopStation()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 28))
                        Text("Stop")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Stats")
                .font(.headline)

            HStack(spacing: 20) {
                statItem(icon: "hand.thumbsup.fill", value: "\(viewModel.likeCount)", label: "Likes", color: .green)
                statItem(icon: "hand.thumbsdown.fill", value: "\(viewModel.dislikeCount)", label: "Dislikes", color: .red)
                statItem(icon: "forward.fill", value: "\(viewModel.skipCount)", label: "Skips", color: .gray)
                statItem(icon: "music.note.list", value: "\(viewModel.candidatePoolSize)", label: "Pool", color: .blue)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation {
                    showDebugLog.toggle()
                }
            } label: {
                HStack {
                    Text("Debug Log")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showDebugLog ? "chevron.up" : "chevron.down")
                }
                .foregroundStyle(.primary)
            }

            if showDebugLog {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.debugLog, id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Helper Views

    private func featureBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .cornerRadius(8)
    }

    private func statItem(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    StationTestView()
}
*/
