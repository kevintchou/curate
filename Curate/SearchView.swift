//
//  SearchView.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//

import SwiftUI
import MusicKit

struct SearchView: View {
    @Bindable var viewModel: CurateViewModel
    @Binding var isPresented: Bool
    @FocusState private var isSearchFocused: Bool

    // Optional callback for direct playback after selection
    var onPlaySong: ((Song) -> Void)?
    var onPlayArtist: ((Artist) -> Void)?
    var onPlayAISearch: ((String) -> Void)?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 12) {
                    // Song/Artist/AI Search dropdown menu
                    Menu {
                        Button {
                            viewModel.curateBy = .song
                        } label: {
                            Label(viewModel.curateBy == .song ? "Song ✓" : "Song", systemImage: "music.note")
                        }

                        Button {
                            viewModel.curateBy = .artist
                        } label: {
                            Label(viewModel.curateBy == .artist ? "Artist ✓" : "Artist", systemImage: "music.microphone")
                        }

                        Button {
                            viewModel.curateBy = .aiSearch
                        } label: {
                            Label(viewModel.curateBy == .aiSearch ? "AI Search ✓" : "AI Search", systemImage: "apple.haptics.and.music.note")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            ZStack {
                                Image(systemName: "music.note")
                                    .opacity(viewModel.curateBy == .song ? 1 : 0)
                                Image(systemName: "music.microphone")
                                    .opacity(viewModel.curateBy == .artist ? 1 : 0)
                                Image(systemName: "apple.haptics.and.music.note")
                                    .opacity(viewModel.curateBy == .aiSearch ? 1 : 0)
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 20, height: 20)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                        .animation(.default, value: viewModel.curateBy)
                    }
                    
                    // Search TextField
                    TextField("Curate", text: $viewModel.songQuery)
                        .submitLabel(.search)
                        .focused($isSearchFocused)
                        .font(.body)
                        .onSubmit {
                            if viewModel.curateBy == .aiSearch && !viewModel.songQuery.isEmpty {
                                // For AI search, submit triggers playback directly
                                if let onPlayAISearch = onPlayAISearch {
                                    onPlayAISearch(viewModel.songQuery)
                                    isPresented = false
                                }
                            } else {
                                viewModel.selectFirstResult()
                            }
                        }
                    
                    Spacer()
                    
                    // Clear button
                    if !viewModel.songQuery.isEmpty {
                        Button {
                            viewModel.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    
                    // Loading indicator
                    if viewModel.isSearching {
                        ProgressView()
                            .scaleEffect(0.9)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                // Search results
                if viewModel.curateBy == .aiSearch {
                    // AI Search mode - show prompts
                    aiSearchContent
                } else if viewModel.curateBy == .song && !viewModel.searchResults.isEmpty {
                    songResultsList
                } else if viewModel.curateBy == .artist && !viewModel.artistSearchResults.isEmpty {
                    artistResultsList
                } else if !viewModel.songQuery.isEmpty && !viewModel.isSearching {
                    // No results state
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)

                        Text("No Results")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Try searching for something else")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    // Empty state - show suggestions or recent searches
                    VStack(spacing: 12) {
                        Image(systemName: viewModel.curateBy == .artist ? "music.mic" : "music.note.list")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)

                        Text("Search for \(viewModel.curateBy == .artist ? "Artists" : "Music")")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(viewModel.curateBy == .artist ? "Find your favorite artists" : "Find songs and artists")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // Only clear if user cancels - preserve selection
                        isPresented = false
                    } label: {
                        Text("Cancel")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .task {
                // Immediate focus on appear
                isSearchFocused = true
                
                // If there's a selected song/artist but no search results, restore to results
                if viewModel.curateBy == .song {
                    if let selectedSong = viewModel.selectedSong, viewModel.searchResults.isEmpty {
                        viewModel.searchResults = [selectedSong]
                    }
                } else if viewModel.curateBy == .artist {
                    if let selectedArtist = viewModel.selectedArtist, viewModel.artistSearchResults.isEmpty {
                        viewModel.artistSearchResults = [selectedArtist]
                    }
                }
            }
        }
    }
    
    // MARK: - Song Results List
    @ViewBuilder
    private var songResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.searchResults, id: \.id) { song in
                    Button {
                        viewModel.selectSong(song)
                        if let onPlaySong = onPlaySong {
                            // Direct playback mode - start playing immediately
                            onPlaySong(song)
                        }
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            // Album artwork
                            if let artwork = song.artwork {
                                ArtworkImage(artwork, width: 50, height: 50)
                                    .cornerRadius(6)
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(song.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    
                                    if song.contentRating == .explicit {
                                        Text("E")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color(.systemGray5))
                                            .cornerRadius(3)
                                    }
                                }
                                
                                Text(song.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            // Show checkmark if this song is selected
                            if viewModel.selectedSong?.id == song.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if song.id != viewModel.searchResults.last?.id {
                        Divider()
                            .padding(.leading, 74)
                    }
                }
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Artist Results List
    @ViewBuilder
    private var artistResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.artistSearchResults, id: \.id) { artist in
                    Button {
                        viewModel.selectArtist(artist)
                        if let onPlayArtist = onPlayArtist {
                            // Direct playback mode - start playing immediately
                            onPlayArtist(artist)
                        }
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            // Artist artwork
                            if let artwork = artist.artwork {
                                ArtworkImage(artwork, width: 50, height: 50)
                                    .cornerRadius(25)
                            } else {
                                Circle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay(
                                        Image(systemName: "music.mic")
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(artist.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                
                                if let genreNames = artist.genreNames, let genre = genreNames.first {
                                    Text(genre)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            
                            Spacer()
                            
                            // Show checkmark if this artist is selected
                            if viewModel.selectedArtist?.id == artist.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if artist.id != viewModel.artistSearchResults.last?.id {
                        Divider()
                            .padding(.leading, 74)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - AI Search Content
    @ViewBuilder
    private var aiSearchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header section
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI-Powered Music Discovery")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("Describe what you want to listen to in natural language")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)

                // Suggested prompts
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try something like:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        ForEach(aiSearchPrompts, id: \.self) { prompt in
                            Button {
                                viewModel.songQuery = prompt
                                if let onPlayAISearch = onPlayAISearch {
                                    // Direct playback mode - start AI search immediately
                                    onPlayAISearch(prompt)
                                }
                                isPresented = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles")
                                        .font(.title3)
                                        .foregroundStyle(.purple)

                                    Text(prompt)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.purple.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    // AI Search example prompts
    private let aiSearchPrompts = [
        "Relaxing sunset drive along the coast",
        "Energetic workout at the gym",
        "Focus music for deep work",
        "90s hip hop party vibes",
        "Melancholic rainy day indie",
        "Upbeat Sunday morning cooking",
        "Chill late night study session",
        "Road trip with friends"
    ]
}

#Preview {
    @Previewable @State var isPresented = true
    SearchView(
        viewModel: CurateViewModel(),
        isPresented: $isPresented
    )
}
