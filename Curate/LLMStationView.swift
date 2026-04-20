//
//  LLMStationView.swift
//  Curate
//
//  UI for creating and playing LLM-generated music stations.
//

import SwiftUI
import SwiftData
import MusicKit

// MARK: - LLM Station View
struct LLMStationView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var viewModel = LLMStationViewModel()
    @State private var promptText: String = ""
    @State private var showingDebugLog: Bool = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                backgroundGradient
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if viewModel.isStationActive {
                        // Now Playing View
                        nowPlayingView
                    } else {
                        // Station Creation View
                        stationCreationView
                    }
                }
            }
            .navigationTitle(viewModel.isStationActive ? "" : "Create Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isStationActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Stop") {
                            viewModel.stopStation()
                        }
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDebugLog.toggle()
                    } label: {
                        Image(systemName: "terminal")
                    }
                }
            }
            .sheet(isPresented: $showingDebugLog) {
                debugLogView
            }
            .alert("Error", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onAppear {
                viewModel.setAuthManager(authManager)
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: viewModel.isStationActive
                ? [Color.purple.opacity(0.3), Color.blue.opacity(0.2), Color.black]
                : [Color(.systemBackground), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Station Creation View
    
    private var stationCreationView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "wand.and.stars")
                .font(.system(size: 60))
                .foregroundStyle(.purple)

            // Title
            Text("Describe your perfect station")
                .font(.title2)
                .fontWeight(.semibold)

            // Prompt input
            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g., relaxing sunset drive along the coast", text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .lineLimit(3...6)
                    .focused($isPromptFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        createStation()
                    }

                Text("Be descriptive! Include mood, activity, time of day, genre preferences...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            // Example prompts
            examplePromptsView

            Spacer()

            // Create button
            Button {
                createStation()
            } label: {
                HStack {
                    if viewModel.isCreatingStation {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(viewModel.isCreatingStation ? "Creating..." : "Create Station")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(promptText.isEmpty ? Color.gray : Color.purple)
                .cornerRadius(12)
            }
            .disabled(promptText.isEmpty || viewModel.isCreatingStation)
            .padding(.horizontal, 24)
            .padding(.bottom, 140) // Add space for CurateView's bottom input area
        }
    }
    
    private var examplePromptsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try something like:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(examplePrompts, id: \.self) { prompt in
                        Button {
                            promptText = prompt
                        } label: {
                            Text(prompt)
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color(.systemGray5))
                                .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
    
    private let examplePrompts = [
        "relaxing sunset drive along the coast",
        "energetic workout at the gym",
        "focus music for deep work",
        "90s hip hop party vibes",
        "melancholic rainy day indie",
        "upbeat Sunday morning cooking"
    ]
    
    // MARK: - Now Playing View
    
    private var nowPlayingView: some View {
        VStack(spacing: 0) {
            // Station info
            stationHeaderView
            
            Spacer()
            
            // Album artwork
            artworkView
            
            Spacer()
            
            // Song info
            songInfoView
            
            // Playback controls
            playbackControlsView
            
            // Queue preview
            queuePreviewView
        }
        .padding(.bottom, 24)
    }
    
    private var stationHeaderView: some View {
        VStack(spacing: 4) {
            Text(viewModel.stationConfig?.name ?? "Station")
                .font(.headline)
            
            Text(viewModel.stationConfig?.description ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 16)
    }
    
    private var artworkView: some View {
        Group {
            if let artwork = viewModel.currentSong?.artwork {
                ArtworkImage(artwork, width: 280, height: 280)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray4))
                    .frame(width: 280, height: 280)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
    
    private var songInfoView: some View {
        VStack(spacing: 8) {
            Text(viewModel.currentQueueItem?.suggestion.title ?? "Loading...")
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(1)
            
            Text(viewModel.currentQueueItem?.suggestion.artist ?? "")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            if let reason = viewModel.currentQueueItem?.suggestion.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.horizontal, 24)
    }
    
    private var playbackControlsView: some View {
        VStack(spacing: 24) {
            // Main controls
            HStack(spacing: 48) {
                // Dislike
                Button {
                    viewModel.dislike()
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.title2)
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 50, height: 50)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                
                // Skip
                Button {
                    viewModel.skip()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .foregroundStyle(.primary)
                        .frame(width: 70, height: 70)
                        .background(Color(.systemGray4))
                        .clipShape(Circle())
                }
                
                // Like
                Button {
                    viewModel.like()
                } label: {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.title2)
                        .foregroundStyle(.green.opacity(0.8))
                        .frame(width: 50, height: 50)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
            }
            
            // Stats
            HStack(spacing: 24) {
                Label("\(viewModel.likeCount)", systemImage: "hand.thumbsup")
                    .foregroundStyle(.green)
                
                Label("\(viewModel.skipCount)", systemImage: "forward")
                    .foregroundStyle(.secondary)
                
                Label("\(viewModel.dislikeCount)", systemImage: "hand.thumbsdown")
                    .foregroundStyle(.red)
            }
            .font(.caption)
        }
        .padding(.vertical, 24)
    }
    
    private var queuePreviewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up Next")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if viewModel.isLoadingSongs {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                
                Button("More") {
                    Task {
                        await viewModel.requestMoreSongs()
                    }
                }
                .font(.caption)
                .foregroundStyle(.purple)
            }
            
            let upcomingSongs = viewModel.queue.filter { $0.status == .queued }.prefix(3)
            
            if upcomingSongs.isEmpty {
                Text("Loading more songs...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(upcomingSongs)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.suggestion.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(item.suggestion.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(.systemGray6).opacity(0.5))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }
    
    // MARK: - Debug Log View
    
    private var debugLogView: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.debugLog, id: \.self) { entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showingDebugLog = false
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func createStation() {
        isPromptFocused = false
        Task {
            await viewModel.createStation(from: promptText)
        }
    }
}

// MARK: - Saved Stations List View
struct SavedLLMStationsView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allStations: [Station]

    @State private var selectedStation: Station?
    @State private var viewModel = LLMStationViewModel()
    
    /// Filter to only LLM-generated stations
    private var stations: [Station] {
        allStations
            .filter { $0.stationType == StationType.llmGenerated.rawValue }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if stations.isEmpty {
                    emptyStateView
                } else {
                    stationListView
                }
            }
            .navigationTitle("My Stations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        LLMStationView()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                viewModel.setAuthManager(authManager)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "radio")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("No Stations Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Create your first AI-powered music station")
                .foregroundStyle(.secondary)
            
            NavigationLink {
                LLMStationView()
            } label: {
                Text("Create Station")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.purple)
                    .cornerRadius(12)
            }
        }
    }
    
    private var stationListView: some View {
        List {
            ForEach(stations) { station in
                Button {
                    selectedStation = station
                    Task {
                        await viewModel.resumeStation(station)
                    }
                } label: {
                    StationRowView(station: station)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteStations)
        }
        .fullScreenCover(item: $selectedStation) { _ in
            LLMStationPlayerView(viewModel: viewModel)
        }
    }
    
    private func deleteStations(at offsets: IndexSet) {
        let stationsToDelete = offsets.map { stations[$0] }
        for station in stationsToDelete {
            modelContext.delete(station)
        }
        try? modelContext.save()
    }
}

// MARK: - Station Row View
struct StationRowView: View {
    let station: Station
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [.purple.opacity(0.6), .blue.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.headline)
                
                Text(station.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                // Stats
                HStack(spacing: 12) {
                    if let params = station.thompsonParametersData,
                       let decoded = try? JSONDecoder().decode(ThompsonParameters.self, from: params) {
                        let feedbackCount = Int(decoded.totalFeedbackCount)
                        if feedbackCount > 0 {
                            Text("\(feedbackCount) interactions")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    Text(station.lastPlayedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Full Screen Player View
struct LLMStationPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: LLMStationViewModel
    
    var body: some View {
        NavigationStack {
            LLMStationView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            viewModel.stopStation()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
        }
    }
}

// MARK: - Preview
#Preview("Create Station") {
    LLMStationView()
}

#Preview("Saved Stations") {
    SavedLLMStationsView()
        .modelContainer(for: Station.self, inMemory: true)
}
