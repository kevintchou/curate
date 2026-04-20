//
//  UnifiedNowPlayingView.swift
//  Curate
//
//  Unified full-screen now playing view for all station types
//

import SwiftUI
import MusicKit
import UIKit
import MediaPlayer

struct UnifiedNowPlayingView: View {
    var curateViewModel: CurateViewModel?
    var llmViewModel: LLMStationViewModel?
    @Binding var isPresented: Bool

    // For drag-to-dismiss gesture
    @State private var dragOffset: CGFloat = 0
    @State private var isPlaying: Bool = false

    // For swipe-to-skip gesture on artwork
    @State private var artworkSwipeOffset: CGFloat = 0

    // Playback progress tracking
    @State private var playbackTime: TimeInterval = 0
    @State private var songDuration: TimeInterval = 0

    // Direct observation of SystemMusicPlayer for reliable UI updates
    @State private var playerCurrentSong: Song?

    // Dynamic background color extraction
    @StateObject private var colorExtractor = AlbumArtColorExtractor()

    // Computed properties based on which view model is active
    private var currentTrack: Track? {
        curateViewModel?.currentTrack ?? llmViewModel?.currentTrack
    }

    // Use playerCurrentSong (from SystemMusicPlayer) as primary source,
    // but only if ViewModel also has a current song (prevents stale data during station loading)
    private var currentSong: Song? {
        let viewModelSong = curateViewModel?.currentAppleMusicSong ?? llmViewModel?.currentSong
        // Only use playerCurrentSong if ViewModel confirms we have a song playing
        if viewModelSong != nil {
            return playerCurrentSong ?? viewModelSong
        }
        return nil
    }

    // For track info display, prefer player's song when ViewModel is stale
    private var displayTitle: String {
        if let track = currentTrack,
           track.title == playerCurrentSong?.title || playerCurrentSong == nil {
            return track.title
        }
        return playerCurrentSong?.title ?? currentTrack?.title ?? ""
    }

    private var displayArtist: String {
        if let track = currentTrack,
           track.title == playerCurrentSong?.title || playerCurrentSong == nil {
            return track.artistName
        }
        return playerCurrentSong?.artistName ?? currentTrack?.artistName ?? ""
    }

    private var previousSong: Song? {
        curateViewModel?.previousAppleMusicSong ?? llmViewModel?.previousAppleMusicSong
    }

    private var nextSong: Song? {
        curateViewModel?.nextAppleMusicSong ?? llmViewModel?.nextAppleMusicSong
    }

    private var stationName: String {
        if let curate = curateViewModel {
            if let song = curate.selectedSong {
                return "\(song.title) Radio"
            } else if let artist = curate.selectedArtist {
                return "\(artist.name) Radio"
            }
            return "Station Radio"
        } else if let llm = llmViewModel {
            return llm.stationConfig?.name ?? llm.originalConfig?.name ?? "AI Station"
        }
        return "Station"
    }

    private var gradientColors: [Color] {
        if llmViewModel != nil {
            // Purple/pink gradient for LLM stations
            return [
                Color(red: 0.4, green: 0.1, blue: 0.6),  // Deep purple
                Color(red: 0.7, green: 0.2, blue: 0.5)   // Pink-purple
            ]
        } else {
            // Default purple/pink gradient
            return [
                Color(red: 0.5, green: 0.15, blue: 0.7), // Purple
                Color(red: 0.8, green: 0.25, blue: 0.45) // Pink
            ]
        }
    }

    private var isStationActive: Bool {
        curateViewModel?.isStationActive ?? llmViewModel?.isStationActive ?? false
    }

    private var isLoadingNextTrack: Bool {
        curateViewModel?.isLoadingNextTrack ?? llmViewModel?.isLoadingSongs ?? false
    }

    private var isStationLoading: Bool {
        // Check if any ViewModel is in its initial loading/creating state
        if let curate = curateViewModel {
            return curate.isLoadingNextTrack && curate.currentTrack == nil
        } else if let llm = llmViewModel {
            return llm.isCreatingStation
        }
        return false
    }

    private var playbackProgress: Double {
        guard songDuration > 0 else { return 0 }
        return min(playbackTime / songDuration, 1.0)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Helper to fetch MusicKit Song from Apple Music store ID
    private func fetchAndSetCurrentSong(storeId: String) async {
        do {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(storeId))
            let response = try await request.response()
            if let song = response.items.first {
                playerCurrentSong = song
                print("🔍 FullPlayer: Fetched song: \(song.title)")
            }
        } catch {
            print("🔍 FullPlayer: Failed to fetch song: \(error)")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dynamic gradient background extracted from album artwork
                DynamicGradientBackground(
                    dominantColor: colorExtractor.dominantColor,
                    secondaryColor: colorExtractor.secondaryColor,
                    blurRadius: 120,
                    showGlow: true
                )

                VStack(spacing: 0) {
                    // Drag indicator
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)

                    // Header with dismiss and station info
                    headerSection

                    Spacer()
                        .frame(maxHeight: 60)

                    // Track info (right above artwork)
                    trackInfoSection
                        .padding(.horizontal, 24)
                        .padding(.bottom, 36)

                    // Album artwork with time display integrated
                    artworkSection
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 72)

                    // Playback controls
                    playbackControlsSection
                        .padding(.horizontal, 24)

                    // Feedback buttons
                    feedbackSection
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    Spacer()
                }
                .offset(y: dragOffset)
            }
        }
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    // Only respond to vertical drags (dismiss gesture)
                    if abs(value.translation.height) > abs(value.translation.width) && value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 150 {
                        isPresented = false
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .contentShape(Rectangle())
        .statusBarHidden(true)
        .task {
            let player = SystemMusicPlayer.shared
            let mpPlayer = MPMusicPlayerController.systemMusicPlayer
            print("🔍 FullPlayer: Task started - polling MPMusicPlayerController.nowPlayingItem")

            // Initial sync on task start - only if station is active and playing
            if isStationActive && player.state.playbackStatus == .playing {
                if let nowPlaying = mpPlayer.nowPlayingItem,
                   let storeId = nowPlaying.playbackStoreID as String?,
                   !storeId.isEmpty {
                    print("🔍 FullPlayer: Initial song from MPPlayer: \(nowPlaying.title ?? "Unknown")")
                    await fetchAndSetCurrentSong(storeId: storeId)
                }
            } else {
                print("🔍 FullPlayer: Station not active or not playing, skipping initial sync")
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
                        print("🔍 FullPlayer: Song changed! Old: \(currentId ?? "nil") -> New: \(newId)")
                        print("🔍 FullPlayer: New song title: \(mpPlayer.nowPlayingItem?.title ?? "Unknown")")
                        await fetchAndSetCurrentSong(storeId: newId)
                    }
                }

                // Only update playback time if we have a current song and player is active
                if currentSong != nil && (status == .playing || status == .paused) {
                    playbackTime = player.playbackTime
                }

                // Get duration from current song if available
                if let duration = currentSong?.duration {
                    songDuration = duration
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            print("🔍 FullPlayer: Task ended")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Force refresh when app returns to foreground - only if station is active
            print("🔍 FullPlayer: App returning to foreground - forcing refresh")
            guard isStationActive else {
                print("🔍 FullPlayer: Station not active, skipping foreground sync")
                return
            }
            let mpPlayer = MPMusicPlayerController.systemMusicPlayer
            if let nowPlaying = mpPlayer.nowPlayingItem,
               let storeId = nowPlaying.playbackStoreID as String?,
               !storeId.isEmpty {
                print("🔍 FullPlayer: Foreground sync - current song: \(nowPlaying.title ?? "Unknown")")
                Task {
                    await fetchAndSetCurrentSong(storeId: storeId)
                }
            } else {
                print("🔍 FullPlayer: Foreground sync - no nowPlayingItem available")
            }
        }
        .task(id: playerCurrentSong?.id) {
            // Reset playback time and swipe offset when song changes (tracked via playerCurrentSong)
            playbackTime = 0
            songDuration = playerCurrentSong?.duration ?? currentSong?.duration ?? 0

            // Reset swipe offset instantly - the incoming artwork is already at center position
            // (animating this would cause the NEW song's artwork to animate from side to center)
            artworkSwipeOffset = 0

            // Extract colors from album artwork when song changes
            await colorExtractor.extractColors(from: currentSong?.artwork)
        }
        .onChange(of: isStationLoading) { _, isLoading in
            // Clear stale playerCurrentSong when a new station starts loading
            if isLoading {
                playerCurrentSong = nil
                playbackTime = 0
                songDuration = 0
            }
        }
        .onDisappear {
            colorExtractor.reset()
        }
    }

    // MARK: - Artwork Section

    private let vinylSize: CGFloat = 380
    private var maxArtworkSize: CGFloat { vinylSize - 100 }  // 280 - size when at center
    private var minArtworkSize: CGFloat { maxArtworkSize * 0.65 }  // ~182 - size when at side position

    // Distance from center to side artwork position
    private var sideArtworkOffset: CGFloat { vinylSize / 2 + minArtworkSize / 6 }

    // Calculate artwork size based on distance from center (linear interpolation)
    private func artworkSize(forPositionX positionX: CGFloat) -> CGFloat {
        let distanceFromCenter = abs(positionX)
        // Clamp progress between 0 and 1
        let progress = min(distanceFromCenter / sideArtworkOffset, 1.0)
        // At center (progress=0) -> maxArtworkSize, at side (progress=1) -> minArtworkSize
        return maxArtworkSize - (maxArtworkSize - minArtworkSize) * progress
    }

    // Calculate opacity based on distance from center
    private func artworkOpacity(forPositionX positionX: CGFloat) -> Double {
        let distanceFromCenter = abs(positionX)
        let progress = min(distanceFromCenter / sideArtworkOffset, 1.0)
        // At center (progress=0) -> 1.0, at side (progress=1) -> 0.7
        return 1.0 - 0.3 * progress
    }

    // Current artwork position (at center + swipe offset)
    private var currentArtworkPositionX: CGFloat { artworkSwipeOffset }

    // Previous artwork position (left side + swipe offset)
    private var previousArtworkPositionX: CGFloat { -sideArtworkOffset + artworkSwipeOffset }

    // Next artwork position (right side + swipe offset)
    private var nextArtworkPositionX: CGFloat { sideArtworkOffset + artworkSwipeOffset }

    private var artworkSection: some View {
        ZStack {
            // Previous song artwork (left side) - moves with swipe
            sideArtwork(song: previousSong, isLeft: true)
                .offset(x: -sideArtworkOffset + artworkSwipeOffset)

            // Next song artwork (right side) - moves with swipe
            sideArtwork(song: nextSong, isLeft: false)
                .offset(x: sideArtworkOffset + artworkSwipeOffset)

            // Current artwork - slides with swipe, BEHIND the vinyl ring
            // The clipShape is applied directly to the image so it stays circular during swipe
            currentArtworkView
                .offset(x: artworkSwipeOffset)

            // Vinyl ring (stays stationary, in FRONT of sliding artwork)
            vinylRecord(artworkSize: maxArtworkSize, vinylSize: vinylSize)
        }
        .frame(width: vinylSize, height: vinylSize)
        .shadow(color: .black.opacity(0.4), radius: 25, x: 0, y: 10)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    // Only allow horizontal swipes
                    if abs(value.translation.width) > abs(value.translation.height) {
                        artworkSwipeOffset = value.translation.width
                    }
                }
                .onEnded { value in
                    let threshold: CGFloat = 80

                    if value.translation.width < -threshold && nextSong != nil {
                        // Swiped left - play next
                        // Animate so next artwork (starting at +sideArtworkOffset) lands at center
                        withAnimation(.easeOut(duration: 0.3)) {
                            artworkSwipeOffset = -sideArtworkOffset
                        }
                        Task {
                            if let curate = curateViewModel {
                                await curate.playNext()
                            } else if let llm = llmViewModel {
                                llm.skip()
                            }
                        }
                        // Reset is handled in .task(id: playerCurrentSong?.id) when song changes
                    } else if value.translation.width > threshold && previousSong != nil {
                        // Swiped right - go to previous (only if there's a previous song)
                        // Animate so previous artwork (starting at -sideArtworkOffset) lands at center
                        withAnimation(.easeOut(duration: 0.3)) {
                            artworkSwipeOffset = sideArtworkOffset
                        }
                        Task {
                            if let llm = llmViewModel {
                                await llm.playPrevious()
                            } else if let curate = curateViewModel {
                                await curate.playPrevious()
                            }
                        }
                        // Reset is handled in .task(id: playerCurrentSong?.id) when song changes
                    } else {
                        // Snap back
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            artworkSwipeOffset = 0
                        }
                    }
                }
        )
    }

    // Current artwork as a separate view for cleaner code
    private var currentArtworkView: some View {
        let size = artworkSize(forPositionX: currentArtworkPositionX)
        let opacity = artworkOpacity(forPositionX: currentArtworkPositionX)

        return Group {
            if let song = currentSong, let artwork = song.artwork {
                // Always request max size image, scale down via frame
                AsyncImage(url: artwork.url(width: Int(maxArtworkSize * 2), height: Int(maxArtworkSize * 2))) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    } else {
                        placeholderCenter(artworkSize: size)
                    }
                }
            } else {
                placeholderCenter(artworkSize: size)
            }
        }
        .opacity(opacity)
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 2)
                .frame(width: size, height: size)
        )
    }

    // MARK: - Side Artwork

    private func sideArtwork(song: Song?, isLeft: Bool) -> some View {
        let positionX = isLeft ? previousArtworkPositionX : nextArtworkPositionX
        let size = artworkSize(forPositionX: positionX)
        let opacity = artworkOpacity(forPositionX: positionX)

        return Group {
            if let song = song, let artwork = song.artwork {
                // Always request max size image, scale down via frame
                AsyncImage(url: artwork.url(width: Int(maxArtworkSize * 2), height: Int(maxArtworkSize * 2))) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    } else {
                        sideArtworkPlaceholder(size: size)
                    }
                }
                .opacity(opacity)
            } else {
                // Show placeholder only for "next" side, hide completely for "previous" when nil
                if !isLeft {
                    sideArtworkPlaceholder(size: size)
                        .opacity(0.3)
                }
            }
        }
    }

    private func sideArtworkPlaceholder(size: CGFloat) -> some View {
        Circle()
            .fill(Color.white.opacity(0.1))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white.opacity(0.3))
            )
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            // Dismiss button
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // Station name
            VStack(spacing: 2) {
                Text("PLAYING FROM")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.7))

                Text(stationName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }

            Spacer()

            // Spacer for symmetry
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func vinylRecord(artworkSize: CGFloat, vinylSize: CGFloat) -> some View {
        let middleRingSize = artworkSize + 50  // Progress bar ring
        let outerRingSize = vinylSize - 10
        // Smaller gap at bottom for time display
        let gapSize: Double = 0.03

        return ZStack {
            // Glass effect fill for the vinyl area with border
            vinylGlassBackground(outerRingSize: outerRingSize)

            // Middle ring (progress bar track) - with gap at bottom for time
            Circle()
                .trim(from: gapSize, to: 1.0 - gapSize)
                .stroke(Color.white.opacity(0.15), lineWidth: 2)
                .frame(width: middleRingSize, height: middleRingSize)
                .rotationEffect(.degrees(90)) // Gap at bottom

            // Progress arc on middle ring - starts left of time, goes clockwise
            Circle()
                .trim(from: 0, to: playbackProgress * (1.0 - 2 * gapSize))
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 115/255, green: 146/255, blue: 227/255).opacity(0.4),
                            Color(red: 115/255, green: 146/255, blue: 227/255)
                        ],
                        center: .center,
                        startAngle: .degrees(90 + gapSize * 360),
                        endAngle: .degrees(90 + gapSize * 360 + 360 * (1.0 - 2 * gapSize))
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: middleRingSize, height: middleRingSize)
                .rotationEffect(.degrees(90 + gapSize * 360)) // Start just after the gap

            // Time display at bottom center, vertically centered with the middle ring stroke
            Text(formatTime(playbackTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .offset(y: middleRingSize / 2 - 1)
        }
    }

    @ViewBuilder
    private func vinylGlassBackground(outerRingSize: CGFloat) -> some View {
        // Create a ring shape that excludes the inner artwork area
        // The ring should span from the artwork edge to the outer edge (no gap)
        let innerRadius = maxArtworkSize / 2  // Exactly at artwork edge
        let outerRadius = outerRingSize / 2
        let ringWidth = outerRadius - innerRadius
        let ringDiameter = innerRadius * 2 + ringWidth  // Center of the ring stroke

        if #available(iOS 26.0, *) {
            // iOS 26+ uses the new glassEffect API
            // Use a ring shape via stroke instead of filled circle
            ZStack {
                // Glass ring using stroke
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: ringWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
                    .background {
                        // Apply glass effect to the ring area only
                        Circle()
                            .stroke(.ultraThinMaterial, lineWidth: ringWidth)
                            .frame(width: ringDiameter, height: ringDiameter)
                    }

                // Outer border
                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 2)
                    .frame(width: outerRingSize, height: outerRingSize)
            }
        } else {
            // Fallback for older iOS versions
            ZStack {
                // Glass ring using stroke with material
                Circle()
                    .stroke(.ultraThinMaterial, lineWidth: ringWidth)
                    .frame(width: ringDiameter, height: ringDiameter)

                // Subtle gradient overlay on the ring
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.05),
                                Color(red: 0.6, green: 0.5, blue: 0.7).opacity(0.1),
                                Color.white.opacity(0.15)
                            ],
                            center: .center
                        ),
                        lineWidth: ringWidth
                    )
                    .frame(width: ringDiameter, height: ringDiameter)

                // Outer border
                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 2)
                    .frame(width: outerRingSize, height: outerRingSize)
            }
        }
    }

    private func placeholderCenter(artworkSize: CGFloat) -> some View {
        Circle()
            .fill(Color.white.opacity(0.1))
            .frame(width: artworkSize, height: artworkSize)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.5))
            )
    }

    // MARK: - Track Info Section

    private var trackInfoSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if isStationLoading {
                    ShimmerText(text: "Curating station...", font: .system(size: 28, weight: .regular))
                        .frame(height: 34)

                    Text("Finding songs for you")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                } else {
                    // Use display properties that sync with SystemMusicPlayer
                    Text(displayTitle.isEmpty ? " " : displayTitle)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(!displayTitle.isEmpty ? .white : .clear)
                        .lineLimit(1)

                    Text(displayArtist.isEmpty ? " " : displayArtist)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(!displayArtist.isEmpty ? .white.opacity(0.6) : .clear)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Heart button (like in concept)
            Button {
                // Like action
                curateViewModel?.like()
                llmViewModel?.like()
            } label: {
                Image(systemName: "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .disabled(currentSong == nil || isStationLoading)
        }
        .frame(height: 50)
    }

    // MARK: - Playback Controls Section

    private var playbackControlsSection: some View {
        HStack(spacing: 60) {
            // Previous
            Button {
                Task {
                    if let llm = llmViewModel {
                        await llm.playPrevious()
                    } else if let curate = curateViewModel {
                        await curate.playPrevious()
                    }
                }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(previousSong != nil ? .white : .white.opacity(0.5))
            }
            .disabled(previousSong == nil)

            // Play/Pause
            Button {
                Task {
                    if isStationActive {
                        // Toggle play/pause
                        let player = SystemMusicPlayer.shared
                        if player.state.playbackStatus == .playing {
                            player.pause()
                        } else {
                            try? await player.play()
                        }
                    }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
            }
            .disabled(currentSong == nil)

            // Next
            Button {
                Task {
                    if let curate = curateViewModel {
                        await curate.playNext()
                    } else if let llm = llmViewModel {
                        llm.skip()
                    }
                }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(isLoadingNextTrack || currentSong == nil ? .white.opacity(0.5) : .white)
            }
            .disabled(isLoadingNextTrack || currentSong == nil)
        }
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        HStack(spacing: 40) {
            // Dislike
            Button {
                curateViewModel?.dislike()
                llmViewModel?.dislike()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 24))
                    Text("Dislike")
                        .font(.caption2)
                }
                .foregroundStyle(currentSong == nil ? .white.opacity(0.4) : .white.opacity(0.8))
                .frame(width: 60)
            }
            .disabled(currentSong == nil)

            // Skip
            Button {
                curateViewModel?.skip()
                llmViewModel?.skip()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24))
                    Text("Skip")
                        .font(.caption2)
                }
                .foregroundStyle(currentSong == nil ? .white.opacity(0.4) : .white.opacity(0.8))
                .frame(width: 60)
            }
            .disabled(currentSong == nil)

            // Like
            Button {
                curateViewModel?.like()
                llmViewModel?.like()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "heart")
                        .font(.system(size: 24))
                    Text("Like")
                        .font(.caption2)
                }
                .foregroundStyle(currentSong == nil ? .white.opacity(0.4) : .white.opacity(0.8))
                .frame(width: 60)
            }
            .disabled(currentSong == nil)
        }
    }

}

// MARK: - Shimmer Text Effect

struct ShimmerText: View {
    let text: String
    let font: Font

    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        ZStack(alignment: .leading) {
            // Base text (dimmed)
            Text(text)
                .font(font)
                .foregroundStyle(.white.opacity(0.4))

            // Shimmer overlay
            Text(text)
                .font(font)
                .foregroundStyle(.white)
                .mask(
                    LinearGradient(
                        colors: [.clear, .white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 80)
                    .offset(x: shimmerOffset)
                )
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.8)
                .repeatForever(autoreverses: false)
            ) {
                shimmerOffset = 300
            }
        }
    }
}
