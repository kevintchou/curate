//
//  CurateViewModel.swift
//  Curate
//
//  Created by Kevin Chou on 11/21/25.
//

import Foundation
import MusicKit

@MainActor
@Observable
class CurateViewModel {
    // MARK: - Published State
    var songQuery: String = "" {
        didSet {
            searchAsYouType(query: songQuery)
        }
    }
    var statusMessage: String = ""
    var searchResults: [Song] = []
    var selectedSong: Song?
    var isSearching: Bool = false
    var curateBy: CurateCategory = .song
    
    // MARK: - Dependencies
    private let searchService = SearchService()
    
    // MARK: - Types
    enum CurateCategory: String, CaseIterable {
        case song = "Song"
        case artist = "Artist"
        case genre = "Genre"
        case decade = "Decade"
        case activity = "Activity"
        case mood = "Mood"
    }
    
    // MARK: - Public Methods
    
    func clearSearch() {
        songQuery = ""
        selectedSong = nil
        searchResults = []
    }
    
    func selectSong(_ song: Song) {
        songQuery = "\(song.title) - \(song.artistName)"
        selectedSong = song
        searchResults = []
    }
    
    func selectFirstResult() {
        if let firstSong = searchResults.first {
            selectSong(firstSong)
        }
    }
    
    func playSong(_ song: Song) {
        Task {
            do {
                print("✅ Playing: \(song.title) by \(song.artistName)")
                print("🎵 Song ID: \(song.id)")
                
                let player = SystemMusicPlayer.shared
                player.queue = [song]
                try await player.play()
                
                statusMessage = "▶️ Now playing: \(song.title) by \(song.artistName)"
                print("▶️ Playing: \(song.title)")
                
            } catch {
                statusMessage = "❌ Error: \(error.localizedDescription)"
                print("❌ Error playing song: \(error)")
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func searchAsYouType(query: String) {
        isSearching = !query.isEmpty
        
        searchService.searchAsYouType(query: query) { [weak self] results, isSearching in
            guard let self else { return }
            self.searchResults = results
            self.isSearching = isSearching
        }
    }
}
