//
//  CurateView.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//

import SwiftUI
import SwiftData
import MusicKit
import WeatherKit
import CoreLocation
import Combine

struct CurateView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.llmServiceProvider) private var llmServiceProvider
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = CurateViewModel()
    @State private var llmStationViewModel: LLMStationViewModel?
    @State private var playlistsViewModel = PlaylistsViewModel()
    @FocusState private var isTextFieldFocused: Bool

    // Top tab state
    @State private var selectedTab: CurateTab = .home

    // Navigation state
    @State private var selectedDiscoverTab: DiscoverTab = .mood

    // Sidebar state
    @State private var showSidebar: Bool = false

    // Sheet/Cover state
    @State private var showPreferences: Bool = false
    @State private var showAddStation: Bool = false
    // @State private var showSearch: Bool = false  // Commented out - search now embedded in CreateStationSheet
    @State private var showStationNowPlaying: Bool = false
    @State private var showLLMStationNowPlaying: Bool = false
    @State private var isPlaying: Bool = false

    // Weather state
    @StateObject private var weatherManager = HomeWeatherManager()

    // Dynamic background color extraction
    @StateObject private var backgroundColorExtractor = AlbumArtColorExtractor()

    // Top-level tabs
    enum CurateTab: String, CaseIterable {
        case home = "Home"
        case library = "Library"
    }

    // Discover tabs (remaining horizontal swipeable tabs)
    enum DiscoverTab: String, CaseIterable, Identifiable {
        case mood
        case activities
        case genre
        case decade

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mood: return "Mood"
            case .activities: return "Activities"
            case .genre: return "Genre"
            case .decade: return "Decade"
            }
        }
    }

    // Bottom bar height for content padding
    private var bottomBarHeight: CGFloat {
        hasActivePlayback ? 140 : 80
    }

    private var hasActivePlayback: Bool {
        (viewModel.isStationActive && viewModel.currentTrack != nil) ||
        (llmStationViewModel?.isStationActive == true && llmStationViewModel?.currentSong != nil)
    }

    // Get the current song from whichever station is active (for background color)
    private var currentPlayingSong: Song? {
        if llmStationViewModel?.isStationActive == true {
            return llmStationViewModel?.currentSong
        } else if viewModel.isStationActive {
            return viewModel.currentAppleMusicSong
        }
        return nil
    }

    // Combined state for which now playing view is shown
    private var isAnyNowPlayingVisible: Bool {
        showStationNowPlaying || showLLMStationNowPlaying
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Layer 1: Main navigation and content
            NavigationStack {
                mainContent
                    .scrollContentBackground(.hidden)
                    .background {
                        // Dynamic gradient background that changes with album artwork
                        DynamicGradientBackground(
                            dominantColor: backgroundColorExtractor.dominantColor,
                            secondaryColor: backgroundColorExtractor.secondaryColor,
                            blurRadius: 150,
                            showGlow: hasActivePlayback,
                            useDefaultStyle: !hasActivePlayback // Use concept-style gradient when no music playing
                        )
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    showSidebar = true
                                }
                            } label: {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }

                        ToolbarItem(placement: .principal) {
                            topTabBar
                        }

                        // MARK: - Commented out - Add station and preferences moved/hidden
                        /*
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 16) {
                                // Add station button
                                Button {
                                    showAddStation = true
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)

                                // Preferences button
                                Button {
                                    showPreferences = true
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        */
                    }
                    .navigationDestination(isPresented: $showPreferences) {
                        PreferencesView()
                    }
                    // MARK: - Commented out - Add station sheet
                    /*
                    .sheet(isPresented: $showAddStation) {
                        AddStationSheet(isPresented: $showAddStation)
                    }
                    */
                    // MARK: - Commented out - Search now embedded in CreateStationSheet
                    /*
                    .fullScreenCover(isPresented: $showSearch) {
                        SearchView(
                            viewModel: viewModel,
                            isPresented: $showSearch,
                            onPlaySong: { song in
                                handlePlaySongDirectly(song)
                            },
                            onPlayArtist: { artist in
                                handlePlayArtistDirectly(artist)
                            },
                            onPlayAISearch: { query in
                                handlePlayAISearchDirectly(query)
                            }
                        )
                    }
                    */
                    .onAppear {
                        // Initialize LLM station view model with injected service
                        if llmStationViewModel == nil {
                            llmStationViewModel = LLMStationViewModel(
                                provider: llmServiceProvider
                            )
                        }
                        // Set auth manager for artist-seeded recommendations
                        llmStationViewModel?.setAuthManager(authManager)
                        startPlaybackStatusObserver()
                    }
                    .task(id: currentPlayingSong?.id) {
                        // Extract colors from album artwork when song changes
                        if let song = currentPlayingSong {
                            await backgroundColorExtractor.extractColors(from: song.artwork)
                        } else {
                            backgroundColorExtractor.reset()
                        }
                    }
            }

            // Layer 2: Full-screen now playing overlay (extends to bottom, behind nav bar)
            if isAnyNowPlayingVisible {
                nowPlayingOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }

            // Layer 3: Unified bottom bar - hidden when full player or preferences is visible
            if !isAnyNowPlayingVisible && !showPreferences {
                UnifiedBottomBar(
                    onMiniPlayerTap: handleMiniPlayerTap,
                    onSubmitQuery: { query in
                        handlePlayAISearchDirectly(query)
                    },
                    curateViewModel: viewModel,
                    llmViewModel: llmStationViewModel
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isAnyNowPlayingVisible)
        .overlay(alignment: .leading) {
            // Invisible strip along the left edge that catches swipes before
            // inner ScrollViews can consume the gesture.
            if !showSidebar {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(edgeSwipeToOpenSidebar)
                    .zIndex(9)
            }
        }
        .overlay {
            if showSidebar {
                SidebarView(
                    isOpen: $showSidebar,
                    showPreferences: $showPreferences,
                    onSelectStation: handleSelectStation,
                    onDeleteStation: handleDeleteStation
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showSidebar)
        .preferredColorScheme(.dark)
    }

    // MARK: - Edge Swipe Gesture

    /// Detects a rightward swipe starting at the left edge to open the sidebar.
    private var edgeSwipeToOpenSidebar: some Gesture {
        DragGesture(minimumDistance: 15)
            .onEnded { value in
                guard !showSidebar else { return }
                let movedRight = value.translation.width > 50
                let mostlyHorizontal = abs(value.translation.width) > abs(value.translation.height)
                if movedRight && mostlyHorizontal {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showSidebar = true
                    }
                }
            }
    }

    // MARK: - Now Playing Overlay

    @ViewBuilder
    private var nowPlayingOverlay: some View {
        // Full player - backgrounds ignore safe area, content respects top safe area
        if showStationNowPlaying {
            UnifiedNowPlayingView(
                curateViewModel: viewModel,
                llmViewModel: nil,
                isPresented: $showStationNowPlaying
            )
        } else if showLLMStationNowPlaying, let llmVM = llmStationViewModel {
            UnifiedNowPlayingView(
                curateViewModel: nil,
                llmViewModel: llmVM,
                isPresented: $showLLMStationNowPlaying
            )
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .home:
            homeStationsContent
        case .library:
            libraryPlaceholderContent
        }
    }

    // MARK: - Top Tab Bar

    @ViewBuilder
    private var topTabBar: some View {
        HStack(spacing: 4) {
            ForEach(CurateTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .medium)
                        .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background {
                            if selectedTab == tab {
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .environment(\.colorScheme, .dark)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.08))
        }
    }

    // MARK: - Library

    @ViewBuilder
    private var libraryPlaceholderContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                NavigationLink {
                    LibraryPlaylistsView()
                } label: {
                    libraryRow(icon: "music.note.list", title: "Playlists")
                }
                .buttonStyle(.plain)

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.leading, 60)

                NavigationLink {
                    LibrarySongsView()
                } label: {
                    libraryRow(icon: "music.note", title: "Songs")
                }
                .buttonStyle(.plain)

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.leading, 60)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, bottomBarHeight + 24)
    }

    @ViewBuilder
    private func libraryRow(icon: String, title: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, alignment: .center)

            Text(title)
                .font(.title3)
                .fontWeight(.regular)
                .foregroundStyle(.white)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Home Content

    @ViewBuilder
    private var homeStationsContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Top header: Greeting + Weather
                homeHeader
                    .padding(.top, 8)

                // Contextual station card based on weather/time
                contextualStationCard

                // Activity pills section
                activityPillsSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomBarHeight + 24)
        }
        .contentMargins(.bottom, 0, for: .scrollIndicators)
        .task {
            await weatherManager.fetchWeather()
        }
    }

    // MARK: - Home Header (Greeting + Weather)

    @ViewBuilder
    private var homeHeader: some View {
        HStack(alignment: .top) {
            Text(greetingText)
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Spacer()
        }
    }

    // MARK: - Contextual Station Card

    @ViewBuilder
    private var contextualStationCard: some View {
        let suggestion = contextualStationSuggestion

        Button {
            startContextualStation(suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                // Weather icon and station name
                HStack(spacing: 12) {
                    Image(systemName: suggestion.icon)
                        .font(.system(size: 36))
                        .symbolRenderingMode(.multicolor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.name)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)

                        Text(suggestion.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    // Play icon
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }

                // Description
                Text(suggestion.description)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.leading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: suggestion.gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: suggestion.gradient.first?.opacity(0.4) ?? .clear, radius: 20, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Activity Pills Section

    @ViewBuilder
    private var activityPillsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quick Start")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))

            VStack(spacing: 12) {
                ActivityPillButton(
                    icon: "figure.run",
                    title: "Start a Workout",
                    config: ActivityStationConfig.gym,
                    onTap: { startUnifiedStation(ActivityStationConfig.gym) }
                )

                ActivityPillButton(
                    icon: "car.fill",
                    title: "Going for a Drive",
                    config: ActivityStationConfig.driving,
                    onTap: { startUnifiedStation(ActivityStationConfig.driving) }
                )

                ActivityPillButton(
                    icon: "brain.head.profile",
                    title: "Focus Time",
                    config: MoodStationConfig.focus,
                    onTap: { startMoodStation(MoodStationConfig.focus) }
                )

                ActivityPillButton(
                    icon: "moon.stars.fill",
                    title: "Wind Down",
                    config: MoodStationConfig.chill,
                    onTap: { startMoodStation(MoodStationConfig.chill) }
                )
            }
        }
    }

    // MARK: - Greeting Text

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Good Morning"
        case 12..<17:
            return "Good Afternoon"
        case 17..<21:
            return "Good Evening"
        default:
            return "Good Night"
        }
    }

    // MARK: - Contextual Station Suggestion

    private var contextualStationSuggestion: ContextualStationSuggestion {
        let hour = Calendar.current.component(.hour, from: Date())
        let weather = weatherManager.weather?.currentWeather

        // Weather-based suggestions
        if let weather = weather {
            let condition = weather.condition
            let temp = weather.temperature.converted(to: .fahrenheit).value

            // Rainy/stormy weather
            if condition == .rain || condition == .drizzle || condition == .heavyRain {
                return ContextualStationSuggestion(
                    name: "Rainy Day Vibes",
                    subtitle: "Perfect for the weather",
                    description: "Cozy tunes to match the rain outside",
                    icon: "cloud.rain.fill",
                    gradient: [Color.blue.opacity(0.8), Color.gray],
                    config: MoodStationConfig.chill
                )
            }

            if condition == .thunderstorms || condition == .tropicalStorm {
                return ContextualStationSuggestion(
                    name: "Storm Sessions",
                    subtitle: "Intense & atmospheric",
                    description: "Dramatic music for dramatic weather",
                    icon: "cloud.bolt.rain.fill",
                    gradient: [Color.purple, Color.gray],
                    config: MoodStationConfig.intense
                )
            }

            // Snowy weather
            if condition == .snow || condition == .heavySnow || condition == .flurries {
                return ContextualStationSuggestion(
                    name: "Snowy Morning",
                    subtitle: "Peaceful winter vibes",
                    description: "Serene music for a snowy day",
                    icon: "snowflake",
                    gradient: [Color.cyan, Color.blue.opacity(0.6)],
                    config: MoodStationConfig.peaceful
                )
            }

            // Hot weather
            if temp > 85 {
                return ContextualStationSuggestion(
                    name: "Summer Heat",
                    subtitle: "Hot day energy",
                    description: "Chill beats to cool you down",
                    icon: "sun.max.fill",
                    gradient: [Color.orange, Color.red],
                    config: MoodStationConfig.chill
                )
            }

            // Cold weather
            if temp < 40 {
                return ContextualStationSuggestion(
                    name: "Cozy Vibes",
                    subtitle: "Warm up with music",
                    description: "Comforting tunes for cold weather",
                    icon: "thermometer.snowflake",
                    gradient: [Color.blue, Color.indigo],
                    config: MoodStationConfig.peaceful
                )
            }

            // Clear sunny day
            if condition == .clear || condition == .mostlyClear {
                if hour >= 6 && hour < 12 {
                    return ContextualStationSuggestion(
                        name: "Sunny Morning",
                        subtitle: "Start your day right",
                        description: "Uplifting music to energize your morning",
                        icon: "sun.horizon.fill",
                        gradient: [Color.yellow, Color.orange],
                        config: MoodStationConfig.uplifting
                    )
                } else {
                    return ContextualStationSuggestion(
                        name: "Beautiful Day",
                        subtitle: "Clear skies ahead",
                        description: "Feel-good music for a perfect day",
                        icon: "sun.max.fill",
                        gradient: [Color.yellow, Color.orange],
                        config: MoodStationConfig.feelGood
                    )
                }
            }
        }

        // Time-based fallbacks
        switch hour {
        case 5..<9:
            return ContextualStationSuggestion(
                name: "Morning Boost",
                subtitle: "Wake up gently",
                description: "Ease into your day with uplifting tunes",
                icon: "sunrise.fill",
                gradient: [Color.orange, Color.pink],
                config: MoodStationConfig.uplifting
            )
        case 9..<12:
            return ContextualStationSuggestion(
                name: "Productive Morning",
                subtitle: "Get things done",
                description: "Focus-enhancing music for peak productivity",
                icon: "sun.max.fill",
                gradient: [Color.yellow, Color.orange],
                config: MoodStationConfig.focus
            )
        case 12..<17:
            return ContextualStationSuggestion(
                name: "Afternoon Energy",
                subtitle: "Power through",
                description: "Keep the momentum going with energetic tracks",
                icon: "bolt.fill",
                gradient: [Color.purple, Color.pink],
                config: MoodStationConfig.energetic
            )
        case 17..<21:
            return ContextualStationSuggestion(
                name: "Evening Unwind",
                subtitle: "Time to relax",
                description: "Wind down with mellow vibes",
                icon: "sunset.fill",
                gradient: [Color.orange, Color.purple],
                config: MoodStationConfig.chill
            )
        default:
            return ContextualStationSuggestion(
                name: "Late Night",
                subtitle: "Night owl mode",
                description: "Atmospheric music for the late hours",
                icon: "moon.stars.fill",
                gradient: [Color.indigo, Color.purple],
                config: MoodStationConfig.peaceful
            )
        }
    }

    private func startContextualStation(_ suggestion: ContextualStationSuggestion) {
        startMoodStation(suggestion.config)
    }

    // MARK: - Discover Content (Swipeable Tabs)

    @ViewBuilder
    private var discoverContent: some View {
        VStack(spacing: 0) {
            // Header with tab indicators
            VStack(spacing: 16) {
                Text(selectedDiscoverTab.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                // Tab indicator bars
                HStack(spacing: 12) {
                    tabIndicator(for: .mood)
                    tabIndicator(for: .activities)
                    tabIndicator(for: .genre)
                    tabIndicator(for: .decade)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)

            // Swipeable tab content
            TabView(selection: $selectedDiscoverTab) {
                moodTabContent
                    .tag(DiscoverTab.mood)

                activitiesTabContent
                    .tag(DiscoverTab.activities)

                genreTabContent
                    .tag(DiscoverTab.genre)

                decadeTabContent
                    .tag(DiscoverTab.decade)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .contentShape(Rectangle())
            .onTapGesture {
                isTextFieldFocused = false
            }
        }
    }

    // MARK: - Playlists Content

    @ViewBuilder
    private var playlistsContent: some View {
        VStack(spacing: 0) {
            // Header
            Text("Playlists")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)

            // Playlists list
            ScrollView {
                if playlistsViewModel.isLoading {
                    VStack {
                        ProgressView()
                            .padding()
                        Text("Loading playlists...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                    .padding(.bottom, bottomBarHeight + 24)
                } else if let errorMessage = playlistsViewModel.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task {
                                await playlistsViewModel.fetchPlaylists()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                    .padding(.bottom, bottomBarHeight + 24)
                } else if playlistsViewModel.playlists.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No playlists found")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                    .padding(.bottom, bottomBarHeight + 24)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(playlistsViewModel.playlists, id: \.id) { playlist in
                            PlaylistRow(playlist: playlist) {
                                playlistsViewModel.playPlaylist(playlist)
                            }
                        }
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomBarHeight + 24)
                }
            }
            .contentMargins(.bottom, 0, for: .scrollIndicators)
            .task {
                if playlistsViewModel.playlists.isEmpty && !playlistsViewModel.isLoading {
                    await playlistsViewModel.fetchPlaylists()
                }
            }
        }
    }

    // MARK: - Profile Content

    @ViewBuilder
    private var profileContent: some View {
        TestWeatherView()
    }

    // MARK: - Placeholder Content

    @ViewBuilder
    private func placeholderContent(title: String, icon: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mood Tab Content

    @ViewBuilder
    private var moodTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                MoodOptionButton(
                    icon: "face.smiling",
                    text: "Feel Good",
                    config: .feelGood,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "bolt.fill",
                    text: "Energetic",
                    config: .energetic,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "sparkles",
                    text: "Uplifting",
                    config: .uplifting,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "moon.stars.fill",
                    text: "Chill",
                    config: .chill,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "heart.fill",
                    text: "Romantic",
                    config: .romantic,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "cloud.rain.fill",
                    text: "Feeling Blue",
                    config: .feelingBlue,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "flame.fill",
                    text: "Intense",
                    config: .intense,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "leaf.fill",
                    text: "Peaceful",
                    config: .peaceful,
                    onTap: startMoodStation
                )
                MoodOptionButton(
                    icon: "waveform",
                    text: "Focus",
                    config: .focus,
                    onTap: startMoodStation
                )
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomBarHeight + 24)
        }
        .contentMargins(.bottom, 0, for: .scrollIndicators)
    }

    // MARK: - Activities Tab Content

    @ViewBuilder
    private var activitiesTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                UnifiedStationOptionButton(config: ActivityStationConfig.running, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.gym, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.walking, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.yoga, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.driving, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.commuting, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.relaxing, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.reading, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.cooking, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.sleeping, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.working, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: ActivityStationConfig.socializing, onTap: startUnifiedStation)
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomBarHeight + 24)
        }
        .contentMargins(.bottom, 0, for: .scrollIndicators)
    }

    // MARK: - Genre Tab Content

    @ViewBuilder
    private var genreTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                UnifiedStationOptionButton(config: GenreStationConfig.pop, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.rock, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.hipHop, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.jazz, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.electronic, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.classical, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.country, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.latin, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.rnb, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: GenreStationConfig.indie, onTap: startUnifiedStation)
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomBarHeight + 24)
        }
        .contentMargins(.bottom, 0, for: .scrollIndicators)
    }

    // MARK: - Decade Tab Content

    @ViewBuilder
    private var decadeTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                UnifiedStationOptionButton(config: DecadeStationConfig.twenties, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.tens, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.noughties, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.nineties, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.eighties, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.seventies, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.sixties, onTap: startUnifiedStation)
                UnifiedStationOptionButton(config: DecadeStationConfig.fifties, onTap: startUnifiedStation)
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomBarHeight + 24)
        }
        .contentMargins(.bottom, 0, for: .scrollIndicators)
    }

    // MARK: - Helper Functions

    private func tabIndicator(for tab: DiscoverTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDiscoverTab = tab
            }
        } label: {
            Rectangle()
                .fill(selectedDiscoverTab == tab ? Color.white : Color.white.opacity(0.3))
                .frame(width: 40, height: 3)
        }
        .buttonStyle(.plain)
    }

    private func startPlaybackStatusObserver() {
        Task {
            let player = SystemMusicPlayer.shared
            while !Task.isCancelled {
                let status = player.state.playbackStatus
                await MainActor.run {
                    isPlaying = (status == .playing)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startMoodStation(_ config: MoodStationConfig) {
        guard let llmVM = llmStationViewModel else { return }

        // Stop any active stations first (synchronously clears state)
        if viewModel.isStationActive {
            viewModel.stopStation()
        }
        if llmVM.isStationActive {
            llmVM.stopStation()
        }

        // Reset all playback state before showing view to prevent stale data
        llmVM.previousAppleMusicSong = nil
        llmVM.currentSong = nil
        llmVM.nextAppleMusicSong = nil

        showLLMStationNowPlaying = true

        // Save to history
        let station = Station(name: config.name, stationType: .mood, seedMood: config.name)
        station.stationDescription = config.description
        saveStationToHistory(station)

        Task {
            await llmVM.startStation(with: config)
        }
    }

    private func startUnifiedStation<T: UnifiedStationConfigProtocol>(_ config: T) {
        guard let llmVM = llmStationViewModel else { return }

        // Stop any active stations first (synchronously clears state)
        if viewModel.isStationActive {
            viewModel.stopStation()
        }
        if llmVM.isStationActive {
            llmVM.stopStation()
        }

        // Reset all playback state before showing view to prevent stale data
        llmVM.previousAppleMusicSong = nil
        llmVM.currentSong = nil
        llmVM.nextAppleMusicSong = nil

        showLLMStationNowPlaying = true

        // Save to history - determine type from config
        let stationType: StationType = (config is ActivityStationConfig) ? .fitness : .mood
        let station = Station(name: config.name, stationType: stationType)
        if config is ActivityStationConfig {
            station.seedActivity = config.name
        } else {
            station.seedMood = config.name
        }
        station.stationDescription = config.description
        saveStationToHistory(station)

        Task {
            await llmVM.startStation(with: config)
        }
    }

    private func handleMiniPlayerTap() {
        if viewModel.isStationActive && viewModel.currentTrack != nil {
            showStationNowPlaying = true
        } else if llmStationViewModel?.isStationActive == true && llmStationViewModel?.currentSong != nil {
            showLLMStationNowPlaying = true
        }
    }

    // MARK: - Commented out - Song/Artist station handlers for future reuse
    /*
    private func handlePlayStation(_ type: CreateStationSheet.StationType) {
        switch type {
        case .song:
            if let song = viewModel.selectedSong {
                viewModel.playSong(song)
                viewModel.clearSearch()
                showStationNowPlaying = true
            }
        case .artist:
            if let artist = viewModel.selectedArtist {
                viewModel.playArtist(artist)
                viewModel.clearSearch()
                showStationNowPlaying = true
            }
        case .aiSearch:
            guard let llmVM = llmStationViewModel else { return }
            let query = viewModel.songQuery
            viewModel.clearSearch()
            showLLMStationNowPlaying = true
            Task {
                await llmVM.createStation(from: query)
            }
        }
    }

    private func handlePlaySongDirectly(_ song: Song) {
        // Stop other active stations
        if llmStationViewModel?.isStationActive == true {
            llmStationViewModel?.stopStation()
        }

        // Start playback
        viewModel.playSong(song)
        viewModel.clearSearch()

        // Close CreateStationSheet if open
        showCreateStation = false

        // Show full player after a brief delay to allow sheet to dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showStationNowPlaying = true
        }
    }

    private func handlePlayArtistDirectly(_ artist: Artist) {
        // Stop other active stations
        if llmStationViewModel?.isStationActive == true {
            llmStationViewModel?.stopStation()
        }

        // Start playback
        viewModel.playArtist(artist)
        viewModel.clearSearch()

        // Close CreateStationSheet if open
        showCreateStation = false

        // Show full player after a brief delay to allow sheet to dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showStationNowPlaying = true
        }
    }
    */

    // MARK: - AI Search Playback Handler

    private func handlePlayAISearchDirectly(_ query: String) {
        guard let llmVM = llmStationViewModel else { return }

        // Stop any active stations first (synchronously clears state)
        if viewModel.isStationActive {
            viewModel.stopStation()
        }
        if llmVM.isStationActive {
            llmVM.stopStation()
        }

        // Reset all playback state to prevent stale data
        llmVM.previousAppleMusicSong = nil
        llmVM.currentSong = nil
        llmVM.nextAppleMusicSong = nil

        // Clear search state
        viewModel.clearSearch()

        // Show full player
        showLLMStationNowPlaying = true

        // Save to history and start AI station
        let station = Station(
            name: query,
            stationType: .llmGenerated,
            seedMood: query
        )
        station.stationDescription = query
        saveStationToHistory(station)

        Task {
            await llmVM.createStation(from: query)
        }
    }

    // MARK: - Station Persistence

    private func saveStationToHistory(_ station: Station) {
        modelContext.insert(station)
        try? modelContext.save()
    }

    // MARK: - Sidebar Handlers

    private func handleSelectStation(_ station: Station) {
        // Update lastPlayedAt
        station.lastPlayedAt = Date()
        try? modelContext.save()

        // Restart the station based on its type
        switch station.type {
        case .llmGenerated:
            if let prompt = station.seedMood {
                handlePlayAISearchDirectly(prompt)
            }
        case .mood:
            if let moodName = station.seedMood,
               let config = MoodStationConfig.allMoods.first(where: { $0.name.lowercased() == moodName.lowercased() }) {
                startMoodStation(config)
            }
        case .fitness:
            if let activityName = station.seedActivity,
               let config = ActivityStationConfig.allActivities.first(where: { $0.name.lowercased() == activityName.lowercased() }) {
                startUnifiedStation(config)
            }
        case .genreSeed:
            if let genreName = station.seedGenre,
               let config = GenreStationConfig.allGenres.first(where: { $0.name.lowercased() == genreName.lowercased() }) {
                startUnifiedStation(config)
            }
        case .decadeSeed:
            if let decadeName = station.name as String?,
               let config = DecadeStationConfig.allDecades.first(where: { $0.name.lowercased() == decadeName.lowercased() }) {
                startUnifiedStation(config)
            }
        default:
            break
        }
    }

    private func handleDeleteStation(_ station: Station) {
        modelContext.delete(station)
        try? modelContext.save()
    }
}

// MARK: - Playlist Row Component

struct PlaylistRow: View {
    let playlist: Playlist
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 16) {
                if let artwork = playlist.artwork {
                    ArtworkImage(artwork, width: 60)
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let description = playlist.standardDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mood Option Component (Original - for non-mood tabs)

struct MoodOption: View {
    let icon: String
    let text: String

    var body: some View {
        Button {
            // TODO: Handle selection
        } label: {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                    .frame(width: 60, height: 60)

                Text(text)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mood Option Button Component (For Mood Tab with config)

struct MoodOptionButton: View {
    let icon: String
    let text: String
    let config: MoodStationConfig
    let onTap: (MoodStationConfig) -> Void

    var body: some View {
        Button {
            onTap(config)
        } label: {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text(text)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(config.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unified Station Option Button (For Activity, Genre, Decade tabs)

struct UnifiedStationOptionButton<T: UnifiedStationConfigProtocol>: View {
    let config: T
    let onTap: (T) -> Void

    var body: some View {
        Button {
            onTap(config)
        } label: {
            HStack(spacing: 20) {
                Image(systemName: config.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text(config.name)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(config.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Station Sheet

struct AddStationSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack {
                Text("Add New Station")
                    .font(.title)

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

// MARK: - Contextual Station Suggestion Model

struct ContextualStationSuggestion {
    let name: String
    let subtitle: String
    let description: String
    let icon: String
    let gradient: [Color]
    let config: MoodStationConfig
}

// MARK: - Activity Pill Button

struct ActivityPillButton<T: UnifiedStationConfigProtocol>: View {
    let icon: String
    let title: String
    let config: T
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 32)

                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home Weather Manager

@MainActor
class HomeWeatherManager: NSObject, ObservableObject {
    @Published var weather: Weather?
    @Published var locationName: String?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let weatherService = WeatherService.shared
    private let locationManager = CLLocationManager()
    private var location: CLLocation?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fetchWeather() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        // Check authorization
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            // Wait briefly for authorization
            try? await Task.sleep(for: .seconds(1))
        }

        let currentStatus = locationManager.authorizationStatus
        guard currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways else {
            isLoading = false
            return
        }

        // Request location and wait for it
        let loc = await withCheckedContinuation { continuation in
            self.locationContinuation = continuation
            self.locationManager.requestLocation()

            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(for: .seconds(5))
                if self.locationContinuation != nil {
                    self.locationContinuation?.resume(returning: nil)
                    self.locationContinuation = nil
                }
            }
        }

        guard let location = loc else {
            isLoading = false
            errorMessage = "Unable to get location"
            return
        }

        self.location = location

        // Reverse geocode for location name
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                if let city = placemark.locality {
                    locationName = city
                } else if let name = placemark.name {
                    locationName = name
                }
            }
        } catch {
            print("Geocoding error: \(error)")
        }

        // Fetch weather
        do {
            weather = try await weatherService.weather(for: location)
        } catch {
            errorMessage = "Weather unavailable"
            print("Weather error: \(error)")
        }

        isLoading = false
    }
}

extension HomeWeatherManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let continuation = self.locationContinuation {
                continuation.resume(returning: locations.first)
                self.locationContinuation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
        Task { @MainActor in
            if let continuation = self.locationContinuation {
                continuation.resume(returning: nil)
                self.locationContinuation = nil
            }
        }
    }
}

#Preview {
    CurateView()
}
