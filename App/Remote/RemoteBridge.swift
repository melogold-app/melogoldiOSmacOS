import Foundation
import Observation
import MelogoldCore
import MelogoldData
import MelogoldPlayback
import MelogoldServer

/// Пульт в приложении (задание 0020): плеер этого устройства для других устройств аккаунта.
///
/// - `PlaybackReporter` сообщает серверу, что играет (`PUT /playback/state`): «Слушать здесь» и пульт на других
///   устройствах видят это; снимок плеера — при каждом его изменении и раз в секунду, пока играет, значимость решает
///   отчёт.
/// - SSE `playback.command` выполняет `RemoteCommandExecutor` на `PlayerEngine`; «Управляет „Pixel 7 Pro“» — плашкой не
///   чаще раза в 30 с. Поток открывается с `remote=1`, пока включено «Управление с других устройств».
/// - SSE `playback.updated` уходит пульту (`remote`) и отчёту: другое устройство забрало этот сеанс — пауза и плашка
///   «Воспроизведение продолжено на „…“» (DESIGN §3.12.6).
/// - Пока это устройство — пульт другого (`remote.isActive`), своё состояние не отправляется: оно перезаписало бы
///   состояние цели.
@MainActor
final class RemoteBridge {
    let remote: RemoteControl

    private let account: Account
    private let sync: LibrarySync
    private let player: PlayerEngine
    private let settings: AppSettings
    private let reporter: PlaybackReporter
    private let executor = RemoteCommandExecutor()
    private let showToast: (String) -> Void
    private var ticker: Task<Void, Never>?

    init(account: Account, sync: LibrarySync, player: PlayerEngine, settings: AppSettings, showToast: @escaping (String) -> Void) {
        self.account = account
        self.sync = sync
        self.player = player
        self.settings = settings
        self.showToast = showToast
        remote = RemoteControl(port: account)
        reporter = PlaybackReporter(send: { [account] body in try await account.putPlaybackState(body) })
        executor.player = player
        reporter.onHandedOff = { [weak self] state in self?.handedOff(to: state?.deviceName) }
        sync.onPlaybackCommand = { [weak self] command in self?.execute(command) }
        sync.onPlaybackUpdated = { [weak self] rev, cleared, state in self?.updated(rev: rev, cleared: cleared, state: state) }
        observeSettings()
        observePlayer()
        observeNotices()
    }

    /// «Слушать здесь» (DESIGN §3.12.5): полное состояние цели, очередь здесь с позицией от `at` (не больше 3 мин и не
    /// дальше конца трека без секунды), новый сеанс, который забирает воспроизведение (`handoffFrom`); цель ставит паузу.
    func listenHere() async {
        let state: PlaybackState?
        do {
            state = try await remote.takeOver()
        } catch {
            showToast(String(localized: "remote.error"))
            return
        }
        guard let state, !state.queue.isEmpty, state.queue.indices.contains(state.index) else {
            showToast(String(localized: "remote.nothingPlaying"))
            return
        }
        var positionMs = state.positionMs
        if state.playing, let at = IsoTime.date(state.at) {
            positionMs += min(max(0, Int64(Date().timeIntervalSince(at) * 1000)), 180_000)
        }
        if let duration = state.durationMs, duration > 1000 { positionMs = min(positionMs, duration - 1000) }
        reporter.takeOver(from: state)
        player.play(tracks: state.queue.map(\.track), startAt: state.index)
        player.seek(to: Double(positionMs) / 1000)
        if let volume = state.volume { player.volume = Float(volume) / 100 }
    }

    /// Пульт отключился сам: «„MacBook Air“ не в сети», «На „MacBook Air“ управление выключено».
    private func observeNotices() {
        withObservationTracking {
            _ = remote.notice
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let notice = self.remote.notice {
                    self.remote.notice = nil
                    switch notice {
                    case .offline(let name): self.showToast(String(localized: "remote.offline \(name)"))
                    case .disabled(let name): self.showToast(String(localized: "remote.disabled \(name)"))
                    case .gone(let name): self.showToast(String(localized: "remote.gone \(name)"))
                    }
                }
                self.observeNotices()
            }
        }
    }

    // MARK: - Что играет здесь

    private func observePlayer() {
        withObservationTracking {
            _ = player.items
            _ = player.index
            _ = player.phase
            _ = player.volume
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.report()
                self?.observePlayer()
            }
        }
        report()
        // Раз в секунду, пока играет: перемотка и конец трека видны отчёту без отдельных событий
        if player.isPlaying, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    self.report()
                    if !self.player.isPlaying {
                        self.ticker = nil
                        return
                    }
                }
            }
        }
    }

    private func report() {
        reporter.enabled = account.isSignedIn && account.serverInfo?.features.playback != nil && !remote.isActive
        guard let index = player.index, !player.items.isEmpty else { return }
        let snapshot = PlaybackSnapshot(
            queue: player.items.map { TrackInput($0.track.raw) },
            queueIdentity: player.items.map(\.id).hashValue,
            index: index,
            positionMs: Int64(max(0, player.livePosition()) * 1000),
            durationMs: player.duration > 0 ? Int64(player.duration * 1000) : nil,
            playing: player.isPlaying,
            volume: Int((player.volume * 100).rounded())
        )
        reporter.update(snapshot)
    }

    // MARK: - Команды и события

    private func observeSettings() {
        withObservationTracking {
            sync.remoteControlEnabled = settings.remoteControl && account.isSignedIn
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
    }

    private func execute(_ command: PlaybackCommand) {
        guard settings.remoteControl, let from = executor.execute(command) else { return }
        showToast(from.isEmpty ? String(localized: "remote.controlledBy.unknown") : String(localized: "remote.controlledBy \(from)"))
    }

    private func updated(rev: Int64, cleared: Bool, state: PlaybackSummary?) {
        remote.apply(rev: rev, cleared: cleared, state: state)
        if let state, let deviceId = account.session?.deviceId { reporter.noticeUpdate(state, myDeviceId: deviceId) }
    }

    private func handedOff(to deviceName: String?) {
        guard player.isPlaying else { return }
        player.pause()
        showToast(deviceName.map { String(localized: "remote.handedOff \($0)") } ?? String(localized: "remote.handedOff.unknown"))
    }
}

/// Плеер приложения для команд пульта (задание 0020). Громкость — плеера приложения, 0..100.
extension PlayerEngine: @retroactive RemotePlayable {
    public func remotePlay() { play() }
    public func remotePause() { pause() }
    public func remoteToggle() { togglePlayPause() }
    public func remoteNext() { next() }
    public func remotePrevious() { previous() }
    public func remoteSeek(toMs positionMs: Int64) { seek(to: Double(positionMs) / 1000) }
    public func remoteSetVolume(_ volume: Int) { self.volume = Float(min(100, max(0, volume))) / 100 }
    public func remotePlayQueue(_ tracks: [TrackDto], index: Int) { play(tracks: tracks.map(\.track), startAt: index) }
    public func remoteStop() { stop() }
}
