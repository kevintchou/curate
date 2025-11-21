//
//  CurateView.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//

import SwiftUI
import MusicKit

struct CurateView: View {
    @State private var viewModel = CurateViewModel()
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search results / suggestions
                if !viewModel.searchResults.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.searchResults, id: \.id) { song in
                                Button {
                                    viewModel.selectSong(song)
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
                                            Text(song.title)
                                                .font(.body)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            
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
                                                .foregroundStyle(.tint)
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
                    }
                    .background(Color(.systemBackground))
                }
                
                // Status message - Centered in the middle
                if !viewModel.statusMessage.isEmpty && viewModel.searchResults.isEmpty {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                        
                        Text(viewModel.statusMessage)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    
                    Spacer()
                } else {
                    Spacer()
                }
                
                // Song search input - At the bottom of the screen
                VStack(spacing: 0) {
                    // "Curate by" text with dropdown
                    HStack {
                        Text("Curate by")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Menu {
                            ForEach(CurateViewModel.CurateCategory.allCases.reversed(), id: \.self) { category in
                                Button {
                                    viewModel.curateBy = category
                                } label: {
                                    HStack {
                                        Text(category.rawValue)
                                        if viewModel.curateBy == category {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(viewModel.curateBy.rawValue)
                                    .font(.headline)
                                    .foregroundStyle(.blue)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    
                    // Row 1: Text input field
                    HStack(spacing: 12) {
                        TextField("Enter song name or artist", text: $viewModel.songQuery)
                            .submitLabel(.search)
                            .focused($isTextFieldFocused)
                            .font(.body)
                            .onSubmit {
                                viewModel.selectFirstResult()
                            }
                        
                        if !viewModel.songQuery.isEmpty {
                            Button {
                                viewModel.clearSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.body)
                            }
                        }
                        
                        if viewModel.isSearching {
                            ProgressView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    
                    Divider()
                        .padding(.horizontal, 16)
                    
                    // Row 2: Control buttons
                    HStack {
                        // Plus button (placeholder)
                        Button {
                            // TODO: Implement add functionality
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        
                        // Clock button
                        Button {
                            // TODO: Implement history/recents functionality
                        } label: {
                            Image(systemName: "clock")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        
                        // Slider button (placeholder)
                        Button {
                            // TODO: Implement slider/controls functionality
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        
                        Spacer()
                        
                        // Play button on the right (iMessage send button size)
                        Button {
                            if let song = viewModel.selectedSong {
                                viewModel.playSong(song)
                            }
                        } label: {
                            Image(systemName: viewModel.selectedSong != nil ? "play.circle.fill" : "play.circle")
                                .font(.system(size: 32))
                                .foregroundStyle(viewModel.selectedSong != nil ? Color.accentColor : .secondary)
                        }
                        .disabled(viewModel.selectedSong == nil)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color(.systemGray4), lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color(.systemBackground))
                        )
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Dismiss keyboard when tapping outside
                isTextFieldFocused = false
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Curate")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    CurateView()
}
