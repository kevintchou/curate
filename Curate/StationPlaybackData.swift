//
//  StationPlaybackData.swift
//  Curate
//
//  Data model for unified playback views
//

import SwiftUI
import MusicKit

/// Data structure for unified playback views (full player and mini player)
struct StationPlaybackData {
    // Track information
    let currentTrack: Track?
    let currentSong: Song?

    // Station information
    let stationName: String
    let stationIcon: String
    let gradientColors: [Color]

    // Stats
    let likeCount: Int
    let skipCount: Int
    let dislikeCount: Int
    let candidatePoolSize: Int

    // State
    let isStationActive: Bool
    let isLoadingNextTrack: Bool

    // Actions
    let onPlayNext: () async -> Void
    let onLike: () -> Void
    let onDislike: () -> Void
    let onSkip: () -> Void
}
