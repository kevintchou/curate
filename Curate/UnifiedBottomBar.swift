//
//  UnifiedBottomBar.swift
//  Curate
//
//  Combines MiniPlayer and Bottom Navigation into a unified glass pill container
//

import SwiftUI
import MusicKit
import UIKit
import MediaPlayer

struct UnifiedBottomBar: View {
    let onMiniPlayerTap: () -> Void
    let onSubmitQuery: (String) -> Void

    // ViewModels for playback state
    var curateViewModel: CurateViewModel?
    var llmViewModel: LLMStationViewModel?

    // Whether full player is currently visible (hides miniplayer)
    var isFullPlayerVisible: Bool = false

    // Check if any station has active playback
    private var hasActivePlayback: Bool {
        let curateActive = curateViewModel?.isStationActive == true && curateViewModel?.currentTrack != nil
        let llmActive = llmViewModel?.isStationActive == true && llmViewModel?.currentSong != nil
        return curateActive || llmActive
    }

    // Show miniplayer only when playing AND full player is not visible
    private var showMiniPlayer: Bool {
        hasActivePlayback && !isFullPlayerVisible
    }

    var body: some View {
        VStack(spacing: 0) {
            // MiniPlayer (shown when music is playing AND full player is NOT visible)
            // Has its own glass container that overlaps/shares borders with nav bar container
            // No padding on top/sides so borders overlap, only bottom spacing
            if showMiniPlayer {
                MiniPlayerContent(
                    curateViewModel: curateViewModel,
                    llmViewModel: llmViewModel,
                    onTap: onMiniPlayerTap
                )
                .modifier(MiniPlayerGlassModifier(cornerRadius: 32))
                .padding(.bottom, 8) // Only bottom spacing to separate from nav icons
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Text input
            TextInputContent(onSubmit: onSubmitQuery)
        }
        .modifier(GlassBackgroundModifier(cornerRadius: 32))
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .animation(.easeInOut(duration: 0.3), value: showMiniPlayer)
    }
}

// MARK: - Glass Background Modifier (iOS 26+ glassEffect, fallback to ultraThinMaterial)

private struct GlassBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                }
        }
    }
}

// MARK: - Mini Player Content (nested pill inside unified container)

private struct MiniPlayerContent: View {
    var curateViewModel: CurateViewModel?
    var llmViewModel: LLMStationViewModel?
    let onTap: () -> Void
    @State private var isPlaying: Bool = false

    // Direct observation of SystemMusicPlayer for reliable UI updates
    @State private var playerCurrentSong: Song?

    private var currentTrack: Track? {
        curateViewModel?.currentTrack ?? llmViewModel?.currentTrack
    }

    // Use playerCurrentSong (from SystemMusicPlayer) as primary source,
    // fall back to ViewModel state
    private var currentSong: Song? {
        playerCurrentSong ?? curateViewModel?.currentAppleMusicSong ?? llmViewModel?.currentSong
    }

    // For track info, prefer ViewModel's Track (has more metadata),
    // but use player song if ViewModel is stale
    private var displayTitle: String {
        if let track = currentTrack,
           track.title == playerCurrentSong?.title || playerCurrentSong == nil {
            return track.title
        }
        return playerCurrentSong?.title ?? currentTrack?.title ?? "Loading..."
    }

    private var displayArtist: String {
        if let track = currentTrack,
           track.title == playerCurrentSong?.title || playerCurrentSong == nil {
            return track.artistName
        }
        return playerCurrentSong?.artistName ?? currentTrack?.artistName ?? ""
    }

    private let accentColor = Color(red: 0.6, green: 0.2, blue: 0.8)

    // Check if any station is active
    private var isStationActive: Bool {
        curateViewModel?.isStationActive == true || llmViewModel?.isStationActive == true
    }

    // Helper to fetch MusicKit Song from Apple Music store ID
    private func fetchAndSetCurrentSong(storeId: String) async {
        do {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(storeId))
            let response = try await request.response()
            if let song = response.items.first {
                playerCurrentSong = song
                print("🔍 MiniPlayer: Fetched song: \(song.title)")
            }
        } catch {
            print("🔍 MiniPlayer: Failed to fetch song: \(error)")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Album artwork thumbnail (larger for bigger miniplayer)
            if let song = currentSong, let artwork = song.artwork {
                ArtworkImage(artwork, width: 56, height: 56)
                    .cornerRadius(10)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accentColor.opacity(0.3))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                    )
            }

            // Track info - use display properties that sync with SystemMusicPlayer
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !displayArtist.isEmpty {
                    Text(displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
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
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            // Skip button
            Button {
                Task {
                    // Check which station is actually active and skip that one
                    if llmViewModel?.isStationActive == true {
                        llmViewModel?.skip()
                    } else if curateViewModel?.isStationActive == true {
                        await curateViewModel?.playNext()
                    }
                }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .task {
            let player = SystemMusicPlayer.shared
            let mpPlayer = MPMusicPlayerController.systemMusicPlayer
            print("🔍 MiniPlayer: Task started - polling MPMusicPlayerController.nowPlayingItem")

            // Initial sync on task start - only if station is active and playing
            if isStationActive && player.state.playbackStatus == .playing {
                if let nowPlaying = mpPlayer.nowPlayingItem,
                   let storeId = nowPlaying.playbackStoreID as String?,
                   !storeId.isEmpty {
                    print("🔍 MiniPlayer: Initial song from MPPlayer: \(nowPlaying.title ?? "Unknown")")
                    await fetchAndSetCurrentSong(storeId: storeId)
                }
            } else {
                print("🔍 MiniPlayer: Station not active or not playing, skipping initial sync")
            }

            while !Task.isCancelled {
                let status = player.state.playbackStatus
                isPlaying = (status == .playing)

                // Only sync with MPMusicPlayerController if our station is active and playing
                // This prevents showing random songs from system player when station is loading
                if isStationActive && (status == .playing || status == .paused) {
                    var newStoreId: String?
                    if let nowPlaying = mpPlayer.nowPlayingItem,
                       let storeId = nowPlaying.playbackStoreID as String?,
                       !storeId.isEmpty {
                        newStoreId = storeId
                    }

                    // Check if song changed
                    let currentId = playerCurrentSong?.id.rawValue
                    if let newId = newStoreId, newId != currentId {
                        print("🔍 MiniPlayer: Song changed! Old: \(currentId ?? "nil") -> New: \(newId)")
                        print("🔍 MiniPlayer: New song title: \(mpPlayer.nowPlayingItem?.title ?? "Unknown")")
                        await fetchAndSetCurrentSong(storeId: newId)
                    }
                }

                try? await Task.sleep(for: .milliseconds(300))
            }
            print("🔍 MiniPlayer: Task ended")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Force refresh when app returns to foreground - only if station is active
            print("🔍 MiniPlayer: App returning to foreground - forcing refresh")
            guard isStationActive else {
                print("🔍 MiniPlayer: Station not active, skipping foreground sync")
                return
            }
            let mpPlayer = MPMusicPlayerController.systemMusicPlayer
            let player = SystemMusicPlayer.shared
            if player.state.playbackStatus == .playing || player.state.playbackStatus == .paused {
                if let nowPlaying = mpPlayer.nowPlayingItem,
                   let storeId = nowPlaying.playbackStoreID as String?,
                   !storeId.isEmpty {
                    print("🔍 MiniPlayer: Foreground sync - current song: \(nowPlaying.title ?? "Unknown")")
                    Task {
                        await fetchAndSetCurrentSong(storeId: storeId)
                    }
                }
            } else {
                print("🔍 MiniPlayer: Foreground sync - player not active")
            }
        }
    }
}

// MARK: - Mini Player Glass Modifier (transparent with border only - no fill)
// Miniplayer: 88pt height (16pt + 56pt + 16pt), 32pt radius
// Navigation bar: 68pt height (12pt + 44pt + 12pt)
// Expanded container: 164pt height (88pt + 8pt + 68pt), 32pt radius
// Both miniplayer and container now use same 32pt corner radius

private struct MiniPlayerGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            // Subtle white tint to distinguish from navigation bar
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
            }
    }
}

// MARK: - Text Input Content (no background - sits inside unified container)

private struct TextInputContent: View {
    let onSubmit: (String) -> Void

    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    private let maxInputLength = 500

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedInput.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let query = trimmedInput
        inputText = ""
        isFocused = false
        onSubmit(query)
    }

    var body: some View {
        HStack(spacing: 12) {
            TextField("Describe what you want to listen to...", text: $inputText)
                .font(.body)
                .foregroundStyle(.white)
                .tint(.white)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
                .onChange(of: inputText) { _, newValue in
                    if newValue.count > maxInputLength {
                        inputText = String(newValue.prefix(maxInputLength))
                    }
                }

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        canSubmit
                            ? AnyShapeStyle(LinearGradient(
                                colors: [
                                    Color(red: 0.6, green: 0.2, blue: 0.8),
                                    Color(red: 0.9, green: 0.3, blue: 0.5)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                              ))
                            : AnyShapeStyle(Color.white.opacity(0.2))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        // Simulated content background
        LinearGradient(
            colors: [Color.purple.opacity(0.3), Color.black],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack {
            Spacer()

            Text("Main Content Area")
                .foregroundColor(.white)

            Spacer()

            // Unified bottom bar
            UnifiedBottomBar(
                onMiniPlayerTap: { print("Mini player tapped") },
                onSubmitQuery: { query in print("Query: \(query)") },
                curateViewModel: nil,
                llmViewModel: nil
            )
        }
    }
}
