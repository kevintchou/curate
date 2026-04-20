//
//  RemoteCommandManager.swift
//  Curate
//
//  Manages lock screen and Control Center playback controls via MPRemoteCommandCenter.
//

import Foundation
import MediaPlayer
import MusicKit

/// Singleton manager for handling remote playback commands (lock screen, Control Center, AirPods, etc.)
@MainActor
final class RemoteCommandManager {

    static let shared = RemoteCommandManager()

    // Callbacks for custom station logic
    var onNextTrack: (() async -> Void)?
    var onPreviousTrack: (() async -> Void)?
    var onLike: (() -> Void)?
    var onDislike: (() -> Void)?

    // Store targets so we can remove them later
    private var nextTrackTarget: Any?
    private var previousTrackTarget: Any?
    private var playTarget: Any?
    private var pauseTarget: Any?
    private var togglePlayPauseTarget: Any?
    private var likeTarget: Any?
    private var dislikeTarget: Any?

    private init() {}

    /// Configure remote command handlers. Call this when a station becomes active.
    /// This removes any existing handlers and registers fresh ones.
    func configure() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any existing targets first to avoid duplicates and override SystemMusicPlayer
        removeAllTargets()

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        nextTrackTarget = commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            print("🎛️ RemoteCommand: nextTrackCommand triggered")
            guard let self = self, let handler = self.onNextTrack else {
                print("🎛️ RemoteCommand: No handler set, returning .commandFailed")
                return .commandFailed
            }
            print("🎛️ RemoteCommand: Calling onNextTrack handler")
            Task { @MainActor in
                await handler()
                print("🎛️ RemoteCommand: onNextTrack handler completed")
            }
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        previousTrackTarget = commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, let handler = self.onPreviousTrack else {
                // No previous track handler - return noActionableNowPlayingItem
                return .noActionableNowPlayingItem
            }
            Task { @MainActor in
                await handler()
            }
            return .success
        }

        // Play command
        commandCenter.playCommand.isEnabled = true
        playTarget = commandCenter.playCommand.addTarget { _ in
            Task {
                try? await SystemMusicPlayer.shared.play()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        pauseTarget = commandCenter.pauseCommand.addTarget { _ in
            SystemMusicPlayer.shared.pause()
            return .success
        }

        // Toggle play/pause command (for headphone button presses)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        togglePlayPauseTarget = commandCenter.togglePlayPauseCommand.addTarget { _ in
            let player = SystemMusicPlayer.shared
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                Task {
                    try? await player.play()
                }
            }
            return .success
        }

        // Like command (if supported by the device)
        commandCenter.likeCommand.isEnabled = true
        likeTarget = commandCenter.likeCommand.addTarget { [weak self] _ in
            guard let self = self, let handler = self.onLike else {
                return .commandFailed
            }
            Task { @MainActor in
                handler()
            }
            return .success
        }

        // Dislike command (if supported by the device)
        commandCenter.dislikeCommand.isEnabled = true
        dislikeTarget = commandCenter.dislikeCommand.addTarget { [weak self] _ in
            guard let self = self, let handler = self.onDislike else {
                return .commandFailed
            }
            Task { @MainActor in
                handler()
            }
            return .success
        }

        print("🎛️ Remote command center configured")
    }

    /// Remove all registered targets (including any from SystemMusicPlayer)
    private func removeAllTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove ALL targets (passing nil removes all handlers, not just ours)
        // This is necessary because SystemMusicPlayer registers its own handlers
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.likeCommand.removeTarget(nil)
        commandCenter.dislikeCommand.removeTarget(nil)

        // Clear our stored references
        nextTrackTarget = nil
        previousTrackTarget = nil
        playTarget = nil
        pauseTarget = nil
        togglePlayPauseTarget = nil
        likeTarget = nil
        dislikeTarget = nil
    }

    /// Update the handlers when switching between stations/view models
    func updateHandlers(
        onNext: (() async -> Void)?,
        onPrevious: (() async -> Void)? = nil,
        onLike: (() -> Void)? = nil,
        onDislike: (() -> Void)? = nil
    ) {
        self.onNextTrack = onNext
        self.onPreviousTrack = onPrevious
        self.onLike = onLike
        self.onDislike = onDislike

        // Always reconfigure to ensure our handlers take precedence
        configure()

        print("🎛️ Remote command handlers updated")
    }

    /// Clear handlers when station stops
    func clearHandlers() {
        onNextTrack = nil
        onPreviousTrack = nil
        onLike = nil
        onDislike = nil

        // Remove our targets so SystemMusicPlayer's defaults can work again
        removeAllTargets()

        print("🎛️ Remote command handlers cleared")
    }
}
