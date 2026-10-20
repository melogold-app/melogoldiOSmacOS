import Foundation
import MelogoldCore
import MelogoldPlayback
import MelogoldServer

/// Что показывает и чем управляет плеер приложения: этим устройством или, пока в «Устройстве» выбрано другое устройство
/// аккаунта, им (задание 0020). Панель воспроизведения, мини-плеер, «Сейчас играет», текст, сочетания клавиш, меню Dock
/// и «Управление» читают и шлют команды только отсюда — второго плеера в листе «Устройство» больше нет.
/// Пользователь (2026-10-02): «окно выбора устройства только делает выбор, органы управления — на основном».
extension AppModel {
    /// Пульт, который сейчас управляет другим устройством; `nil` — плеер управляет этим.
    var remoteTarget: RemoteControl? {
        guard let remote = remoteBridge?.remote, remote.isActive else { return nil }
        return remote
    }

    /// Трек, который играет там, где сейчас плеер: на выбранном устройстве или здесь.
    var playingTrack: Track? {
        if let remote = remoteTarget { return remote.state?.track?.track }
        return services.player.currentTrack
    }

    /// Показывать ли панель воспроизведения: играет трек здесь или выбрано другое устройство (даже если там тишина —
    /// иначе не видно, куда пойдёт музыка).
    var hasPlayer: Bool { playingTrack != nil || remoteTarget != nil }

    var playingIsPlaying: Bool {
        if let remote = remoteTarget { return remote.state?.playing ?? false }
        return services.player.isPlaying
    }

    /// Длительность, секунды; 0 — неизвестна.
    var playingDuration: Double {
        if let remote = remoteTarget {
            let ms = remote.state?.durationMs ?? remote.state?.track?.durationMs ?? 0
            return Double(ms) / 1000
        }
        return services.player.duration
    }

    /// Позиция сейчас, секунды: у другого устройства — от времени его последнего отчёта.
    func playingPosition() -> Double {
        if let remote = remoteTarget { return Double(remote.livePositionMs() ?? 0) / 1000 }
        return services.player.position
    }

    /// Позиция для текста песни — точнее обычной: у этого устройства — по часам звука.
    func playingLivePosition() -> Double {
        if remoteTarget != nil { return playingPosition() }
        return services.player.livePosition()
    }

    var playingHasNext: Bool {
        if let state = remoteTarget?.state { return state.index < state.queueLength - 1 }
        if remoteTarget != nil { return false }
        return services.player.hasNext
    }

    /// Громкость 0…1.
    var playingVolume: Float {
        if let remote = remoteTarget { return Float(remote.volume ?? 0) / 100 }
        return services.player.volume
    }

    // MARK: - Команды

    /// ⏯. Другому устройству — явные «играть» и «пауза» по тому, что видно: переключатель при устаревшем состоянии сделал
    /// бы обратное.
    func togglePlayback() {
        if let remote = remoteTarget {
            let playing = remote.state?.playing ?? false
            Task { if playing { await remote.pause() } else { await remote.play() } }
            return
        }
        services.player.togglePlayPause()
    }

    func playbackPlay() {
        if let remote = remoteTarget { Task { await remote.play() }; return }
        services.player.play()
    }

    func playbackPause() {
        if let remote = remoteTarget { Task { await remote.pause() }; return }
        services.player.pause()
    }

    func playbackNext() {
        if let remote = remoteTarget { Task { await remote.next() }; return }
        services.player.next()
    }

    func playbackPrevious() {
        if let remote = remoteTarget { Task { await remote.previous() }; return }
        services.player.previous()
    }

    func playbackSeek(to seconds: Double) {
        if let remote = remoteTarget { Task { await remote.seek(toMs: Int64(max(0, seconds) * 1000)) }; return }
        services.player.seek(to: seconds)
    }

    func setPlaybackVolume(_ volume: Float) {
        let clamped = min(1, max(0, volume))
        if let remote = remoteTarget { remote.setVolume(Int((clamped * 100).rounded())); return }
        services.player.volume = clamped
    }
}

// MARK: - Выбор устройства

extension AppModel {
    /// Выбор в «Устройстве» — где играть; управление остаётся в плеере окна. Играющая здесь очередь переезжает на
    /// выбранное устройство с того же места, здесь — пауза (играть должно одно устройство). «Это устройство» (`nil`)
    /// забирает то, что играет на прежнем, с его места («Слушать здесь»); если там тишина — просто отключает пульт.
    func selectPlaybackDevice(_ device: RemoteDevice?) {
        guard let bridge = remoteBridge else { return }
        let remote = bridge.remote
        guard let device else {
            guard remote.isActive else { return }
            if remote.state?.playing == true {
                Task { await bridge.listenHere() }
            } else {
                remote.disconnect()
            }
            return
        }
        guard remote.target?.deviceId != device.deviceId else { return }
        let player = services.player
        let handOver = !remote.isActive && player.isPlaying
        remote.connect(device)
        guard handOver, let index = player.index, player.items.indices.contains(index),
              let track = player.currentTrack, PlaybackReporter.isYouTube(track.videoId) else { return }
        let queue = player.items.map { TrackInput($0.track.raw) }
        let positionMs = Int64(max(0, player.livePosition()) * 1000)
        player.pause()
        Task {
            await remote.playQueue(queue, index: index, positionMs: positionMs)
            await Self.seekWhenStarted(remote, videoId: track.videoId, positionMs: positionMs)
        }
    }

    /// Запасной путь: позицию с очередью передаёт сервер с заданием 0005, а цель старой версии её не знает и начинает
    /// трек с начала (перемотку до загрузки трека она пропускает). Ждём (до 15 с), пока цель сообщит, что этот трек
    /// играет, и, если он далеко от места, перематываем.
    private static func seekWhenStarted(_ remote: RemoteControl, videoId: String, positionMs: Int64) async {
        guard positionMs > 3000 else { return }
        for _ in 0 ..< 60 {
            try? await Task.sleep(for: .milliseconds(250))
            guard remote.isActive else { return }
            if let state = remote.state, state.track?.videoId == videoId, state.playing {
                if abs((remote.livePositionMs() ?? 0) - positionMs) > 2000 { await remote.seek(toMs: positionMs) }
                return
            }
        }
    }
}
