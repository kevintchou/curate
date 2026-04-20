//
//  CreateStationSheet.swift
//  Curate
//
//  AI Search sheet for creating a new station via natural language
//  NOTE: Song/Artist search modes are commented out for potential future reuse
//

import SwiftUI
import MusicKit

struct CreateStationSheet: View {
    @Binding var isPresented: Bool
    @Bindable var viewModel: CurateViewModel
    @Bindable var llmViewModel: LLMStationViewModel

    // Callback for playing AI search station
    let onPlayAISearch: (String) -> Void

    // MARK: - Commented out for future reuse
    // let onShowSearch: () -> Void
    // let onPlayStation: (StationType) -> Void
    //
    // enum StationType {
    //     case song
    //     case artist
    //     case aiSearch
    // }

    // Focus state for text field
    @FocusState private var isTextFieldFocused: Bool

    // Local query state (so we don't pollute viewModel until submission)
    @State private var searchQuery: String = ""

    // Theme colors
    private let accentColor = Color(red: 0.6, green: 0.2, blue: 0.8)

    // AI Search example prompts
    private let aiSearchPrompts = [
        "Relaxing sunset drive along the coast",
        "Energetic workout at the gym",
        "Focus music for deep work",
        "90s hip hop party vibes",
        "Melancholic rainy day indie",
        "Chill late night study session"
    ]

    var body: some View {
        VStack(spacing: 16) {
            // Drag indicator
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            // Header with close button
            HStack {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("AI Music Search")
                        .font(.headline)
                        .fontWeight(.bold)

                    Text("Describe what you want to listen to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Invisible spacer to balance the close button
                Color.clear
                    .frame(width: 30, height: 30)
            }
            .padding(.horizontal, 20)

            // Search text field
            searchTextField
                .padding(.horizontal, 20)

            // Suggested prompts
            suggestedPromptsSection
                .padding(.horizontal, 20)

            Spacer(minLength: 8)

            // Play button
            playButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .onAppear {
            // Auto-focus the text field when sheet appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Search Text Field

    private var searchTextField: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(accentColor)

            TextField("e.g. Chill vibes for a rainy day...", text: $searchQuery)
                .font(.body)
                .focused($isTextFieldFocused)
                .submitLabel(.search)
                .onSubmit {
                    if !searchQuery.isEmpty {
                        startAISearch(with: searchQuery)
                    }
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTextFieldFocused ? accentColor : Color(.systemGray4), lineWidth: isTextFieldFocused ? 1.5 : 0.5)
        }
    }

    // MARK: - Suggested Prompts Section

    private var suggestedPromptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try something like:")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(aiSearchPrompts, id: \.self) { prompt in
                    Button {
                        startAISearch(with: prompt)
                    } label: {
                        Text(prompt)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(accentColor.opacity(0.1))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(accentColor.opacity(0.2), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Play Button

    private var playButton: some View {
        Button {
            if !searchQuery.isEmpty {
                startAISearch(with: searchQuery)
            }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Start Station")
                    .font(.body)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(!searchQuery.isEmpty ? accentColor : Color.gray.opacity(0.3))
            }
        }
        .disabled(searchQuery.isEmpty)
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func startAISearch(with query: String) {
        // Stop any active stations
        if viewModel.isStationActive {
            viewModel.stopStation()
        }
        if llmViewModel.isStationActive {
            llmViewModel.stopStation()
        }

        // Trigger callback and dismiss
        onPlayAISearch(query)
        isPresented = false
    }

    // MARK: - Commented out for future reuse
    /*
    private var modeSelector: some View {
        HStack(spacing: 12) {
            ModeButton(
                icon: "music.note",
                label: "Song",
                isSelected: viewModel.curateBy == .song
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.curateBy = .song
                }
            }

            ModeButton(
                icon: "music.microphone",
                label: "Artist",
                isSelected: viewModel.curateBy == .artist
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.curateBy = .artist
                }
            }

            ModeButton(
                icon: "sparkles",
                label: "AI Search",
                isSelected: viewModel.curateBy == .aiSearch
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.curateBy = .aiSearch
                }
            }
        }
    }

    private var searchSelectionArea: some View {
        Button {
            onShowSearch()
        } label: {
            HStack {
                // Icon based on mode
                Image(systemName: modeIcon)
                    .font(.system(size: 20))
                    .foregroundStyle(accentColor)
                    .frame(width: 32)

                // Content based on selection state
                VStack(alignment: .leading, spacing: 4) {
                    if let song = viewModel.selectedSong {
                        Text(song.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(song.artistName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let artist = viewModel.selectedArtist {
                        Text(artist.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let genreNames = artist.genreNames, let genre = genreNames.first {
                            Text(genre)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if viewModel.curateBy == .aiSearch && !viewModel.songQuery.isEmpty {
                        Text(viewModel.songQuery)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(placeholderText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var modeIcon: String {
        switch viewModel.curateBy {
        case .song: return "music.note"
        case .artist: return "music.microphone"
        case .aiSearch: return "sparkles"
        case .genre: return "guitars.fill"
        case .decade: return "calendar"
        case .activity: return "figure.run"
        case .mood: return "face.smiling"
        }
    }

    private var placeholderText: String {
        switch viewModel.curateBy {
        case .song: return "Search for a song..."
        case .artist: return "Search for an artist..."
        case .aiSearch: return "Describe what you want to hear..."
        case .genre: return "Select a genre..."
        case .decade: return "Select a decade..."
        case .activity: return "Select an activity..."
        case .mood: return "Select a mood..."
        }
    }

    private var isPlayEnabled: Bool {
        viewModel.selectedSong != nil ||
        viewModel.selectedArtist != nil ||
        (viewModel.curateBy == .aiSearch && !viewModel.songQuery.isEmpty)
    }

    private func handlePlay() {
        if viewModel.selectedSong != nil {
            // Stop other stations
            if llmViewModel.isStationActive {
                llmViewModel.stopStation()
            }
            onPlayStation(.song)
        } else if viewModel.selectedArtist != nil {
            // Stop other stations
            if llmViewModel.isStationActive {
                llmViewModel.stopStation()
            }
            onPlayStation(.artist)
        } else if viewModel.curateBy == .aiSearch && !viewModel.songQuery.isEmpty {
            // Stop other stations
            if viewModel.isStationActive {
                viewModel.stopStation()
            }
            if llmViewModel.isStationActive {
                llmViewModel.stopStation()
            }
            onPlayStation(.aiSearch)
        }
        isPresented = false
    }
    */
}

// MARK: - Mode Button Component (Commented out for future reuse)
/*
private struct ModeButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    private let selectedColor = Color(red: 0.6, green: 0.2, blue: 0.8)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? selectedColor : .secondary)

                Text(label)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? selectedColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? selectedColor.opacity(0.1) : Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? selectedColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }
}
*/

// MARK: - Preview

#Preview {
    CreateStationSheet(
        isPresented: .constant(true),
        viewModel: CurateViewModel(),
        llmViewModel: LLMStationViewModel(),
        onPlayAISearch: { query in print("AI Search: \(query)") }
    )
}
