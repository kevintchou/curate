//
//  PlaylistsViewModel.swift
//  Curate
//
//  Created by Kevin Chou on 12/23/24.
//

import Foundation
import MusicKit
import SwiftUI

@MainActor
@Observable
class PlaylistsViewModel {
    var playlists: [Playlist] = []
    var isLoading: Bool = false
    var errorMessage: String?

    func fetchPlaylists() async {
        isLoading = true
        errorMessage = nil

        do {
            let request = MusicLibraryRequest<Playlist>()
            let response = try await request.response()

            playlists = Array(response.items)
            print("✅ Fetched \(playlists.count) playlists from library")
        } catch {
            errorMessage = "Failed to load playlists: \(error.localizedDescription)"
            print("❌ Error fetching playlists: \(error)")
        }

        isLoading = false
    }

    func playPlaylist(_ playlist: Playlist) {
        Task {
            do {
                let player = SystemMusicPlayer.shared
                player.queue = .init(for: [playlist], startingAt: playlist)
                try await player.play()
                print("▶️ Now playing playlist: \(playlist.name)")
            } catch {
                print("❌ Error playing playlist: \(error)")
            }
        }
    }
}
