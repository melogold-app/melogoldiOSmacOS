import AVFoundation
import Foundation
import MediaPlayer
import MelogoldCore
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Системный «Сейчас играет» и пульт (docs/PROMPT.md §4 «Система»): экран блокировки, Пункт управления, медиаклавиши
/// Mac, часы, CarPlay и Siri зовут одни и те же команды. Название трека не меняется во время трека; обложка
/// квадратная (у видео — центр превью 16:9).
@MainActor
final class NowPlayingCenter {
    private weak var engine: PlayerEngine?
    private var artworkTask: Task<Void, Never>?
    private var shownVideoId: String?
    private var artwork: MPMediaItemArtwork?

    init() {}

    func install(_ engine: PlayerEngine) {
        self.engine = engine
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.run { $0.play() } ?? .commandFailed }
        commands.pauseCommand.addTarget { [weak self] _ in self?.run { $0.pause() } ?? .commandFailed }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.togglePlayPause() } ?? .commandFailed }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.run { $0.next() } ?? .commandFailed }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.previous() } ?? .commandFailed }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            return self?.run { $0.seek(to: time) } ?? .commandFailed
        }
        commands.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = switch event.repeatType {
            case .one: .one
            case .all: .all
            default: .off
            }
            return self?.run { $0.repeatMode = mode } ?? .commandFailed
        }
        // «Вперёд/назад на 15 с» системе не нужны: у музыки — «следующий» и «предыдущий».
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
    }

    private nonisolated func run(_ action: @escaping @MainActor (PlayerEngine) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let engine else { return .noActionableNowPlayingItem }
            action(engine)
            return .success
        }
    }

    /// Обновить карточку «Сейчас играет».
    func update(track: Track?, duration: Double, position: Double, playing: Bool, rate: Float) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            shownVideoId = nil
            return
        }
        if shownVideoId != track.videoId {
            shownVideoId = track.videoId
            artwork = nil
            loadArtwork(for: track)
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistsText ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = playing ? .playing : .paused
        #endif
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        let videoId = track.videoId
        guard let raw = track.thumbnailUrl ?? Optional(Thumbnails.forVideo(videoId)),
              let url = URL(string: Thumbnails.sized(raw, px: 544) ?? raw) else { return }
        let isFrame = Thumbnails.isWide(url.absoluteString)
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await ArtworkSession.shared.data(from: url), !Task.isCancelled,
                  let image = Self.squareImage(from: data, stripBars: isFrame) else { return }
            guard let self, self.shownVideoId == videoId else { return }
            self.artwork = Self.makeArtwork(image)
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = self.artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Обложку система просит со своей очереди: замыкание не должно быть привязано к главному актору.
    nonisolated static func makeArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Квадрат из центра картинки: система сама режет обложку квадратом, и не всегда по центру (задание 0008).
    /// У кадра видео сначала срезаются чёрные поля (`FrameBars`), потом берётся середина.
    static func squareImage(from data: Data, stripBars: Bool) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let square = FrameCrop.centerSquare(stripBars ? FrameCrop.withoutBars(decoded) : decoded)
        #if canImport(UIKit)
        return UIImage(cgImage: square)
        #else
        return NSImage(cgImage: square, size: NSSize(width: square.width, height: square.height))
        #endif
    }
}
