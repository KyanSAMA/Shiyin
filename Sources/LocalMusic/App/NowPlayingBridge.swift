import AppKit
import MediaPlayer
import LocalMusicCore

/// Media keys, Control Center and the lock-screen widget.
final class NowPlayingBridge {
    private let center = MPNowPlayingInfoCenter.default()
    private let artwork: ArtworkStore
    private var artworkTrack: Int64?
    private var cover: MPMediaItemArtwork?

    init(player: PlayerModel, artwork: ArtworkStore) {
        self.artwork = artwork
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget(handler: Self.handler(player) { $0.resume() })
        commands.pauseCommand.addTarget(handler: Self.handler(player) { $0.pause() })
        commands.togglePlayPauseCommand.addTarget(handler: Self.handler(player) { $0.togglePlayPause() })
        commands.nextTrackCommand.addTarget(handler: Self.handler(player) { $0.next() })
        commands.previousTrackCommand.addTarget(handler: Self.handler(player) { $0.previous() })
        commands.changePlaybackPositionCommand.addTarget(handler: Self.seekHandler(player))
    }

    /// Full refresh on track change, play/pause and seeks; the system extrapolates elapsed time in between.
    func update(_ player: PlayerModel) {
        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            artworkTrack = nil
            cover = nil
            return
        }
        if artworkTrack != track.id { cover = nil }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistText,
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        info[MPMediaItemPropertyArtwork] = cover
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
        guard artworkTrack != track.id else { return }
        artworkTrack = track.id
        Task {
            guard let image = await artwork.image(for: track, pixels: 480), artworkTrack == track.id else { return }
            cover = Self.artwork(image)
            center.nowPlayingInfo?[MPMediaItemPropertyArtwork] = cover
        }
    }

    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: CGSize(width: image.width, height: image.height)) { _ in
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    // Handlers are built outside the main actor: MediaPlayer calls them on its own queue; they hop back explicitly.

    nonisolated private static func handler(_ player: PlayerModel, _ action: @escaping @MainActor (PlayerModel) -> Void)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak player] _ in
            Task { @MainActor in player.map(action) }
            return .success
        }
    }

    nonisolated private static func seekHandler(_ player: PlayerModel) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak player] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in player?.seek(to: time) }
            return .success
        }
    }
}
