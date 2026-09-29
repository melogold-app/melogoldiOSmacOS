import Foundation
import MelogoldCore

/// Что `RemoteControl` нужно от сервера: `Account` в приложении, заглушка в тестах.
@MainActor
public protocol RemotePort: AnyObject {
    func playbackDevices() async throws -> RemoteDeviceList
    func sendPlaybackCommand(_ command: RemoteCommand) async throws -> RemoteCommandResult
    func playbackState() async throws -> PlaybackStateResponse
}

extension Account: RemotePort {}

/// Почему пульт отключился сам — словами экрана (задание 0020 §2).
public enum RemoteNotice: Equatable, Sendable {
    /// «„MacBook Air“ не в сети».
    case offline(name: String)
    /// «На „MacBook Air“ управление выключено».
    case disabled(name: String)
    /// Устройство отвязали от аккаунта.
    case gone(name: String)
}

/// Пульт (API §4.9 «Пульт», задание 0020): список других устройств аккаунта, выбранное устройство и то, что оно
/// играет, команды ему. Пока `target` задан, плеер приложения показывает и шлёт команды туда, а не своему плееру.
///
/// Состояние цели приходит из `GET /playback/devices` при выборе и дальше из SSE `playback.updated`
/// (`apply(rev:cleared:state:)`); позиция между событиями считается от `at` (`livePositionMs`). Громкость ползунка
/// уходит через 150 мс после последнего движения. `device_offline` и `remote_control_disabled` отключают пульт и
/// оставляют `notice`.
@MainActor
@Observable
public final class RemoteControl {
    public private(set) var devices: [RemoteDevice] = []
    public private(set) var loading = false
    public private(set) var loadError: APIError?
    /// Устройство, которым сейчас управляет пульт; `nil` — плеер управляет этим устройством.
    public private(set) var target: RemoteDevice?
    /// Что играет на цели.
    public private(set) var state: PlaybackSummary?
    /// Громкость цели, 0..100: сразу после движения ползунка — выбранная, потом — что сообщила цель.
    public private(set) var volume: Int?
    public var notice: RemoteNotice?

    @ObservationIgnored private let port: any RemotePort
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let volumeDelay: Duration
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    /// Сдвиг часов сервера: `serverTime − now()` последнего ответа.
    @ObservationIgnored private var serverOffset: TimeInterval = 0
    @ObservationIgnored private var lastRev: Int64 = 0

    public init(port: any RemotePort, now: @escaping @MainActor () -> Date = { Date() }, volumeDelay: Duration = .milliseconds(150)) {
        self.port = port
        self.now = now
        self.volumeDelay = volumeDelay
    }

    public var isActive: Bool { target != nil }

    /// Перечитать список устройств (лист «Устройство»).
    public func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await port.playbackDevices()
            devices = list.devices
            loadError = nil
            learnServerTime(list.serverTime)
            if let target, let fresh = list.devices.first(where: { $0.deviceId == target.deviceId }) {
                self.target = fresh
                if let playing = fresh.playing { take(playing) }
            }
        } catch let error as APIError {
            loadError = error
        } catch {
            loadError = APIError(status: 0, code: "network", message: String(describing: error))
        }
    }

    /// Выбрать устройство: плеер становится пультом.
    public func connect(_ device: RemoteDevice) {
        cancelVolume()
        target = device
        state = device.playing
        volume = device.playing?.volume ?? device.volume
        lastRev = device.playing?.rev ?? 0
        notice = nil
    }

    /// «Отключиться»: плеер снова управляет этим устройством, цель играет дальше.
    public func disconnect() {
        cancelVolume()
        target = nil
        state = nil
        volume = nil
        lastRev = 0
    }

    /// SSE `playback.updated`. Событие старее уже виденного пропускается, кроме очистки (DESIGN §3.12.4).
    public func apply(rev: Int64, cleared: Bool, state summary: PlaybackSummary?) {
        guard let target else { return }
        if cleared {
            if state?.deviceId == target.deviceId { state = nil }
            lastRev = max(lastRev, rev)
            return
        }
        guard let summary, summary.deviceId == target.deviceId, rev > lastRev || summary.rev > lastRev else { return }
        take(summary)
    }

    /// Позиция на цели сейчас — от `at` с поправкой на часы сервера.
    public func livePositionMs() -> Int64? {
        state?.livePositionMs(serverNow: now().addingTimeInterval(serverOffset))
    }

    public func play() async { await send(.play) }
    public func pause() async { await send(.pause) }
    public func toggle() async { await send(.toggle) }
    public func next() async { await send(.next) }
    public func previous() async { await send(.previous) }
    public func stop() async { await send(.stop) }

    public func seek(toMs positionMs: Int64) async {
        await send(.seek, positionMs: max(0, positionMs))
    }

    /// Нажатие по треку в списке, пока пульт включён: эта очередь с этого трека на цели.
    public func playQueue(_ tracks: [TrackInput], index: Int) async {
        let (window, start) = PlaybackReporter.window(tracks, index: index)
        guard !window.isEmpty else { return }
        await send(.playQueue, queue: window, index: start)
    }

    /// Ползунок громкости: команда уходит через 150 мс после последнего движения.
    public func setVolume(_ value: Int) {
        let clamped = min(100, max(0, value))
        volume = clamped
        volumeTask?.cancel()
        let delay = volumeDelay
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.volumeTask = nil
            await self.send(.volume, volume: clamped)
        }
    }

    /// «Слушать здесь»: полное состояние цели с очередью; пульт отключается. `nil` — там ничего не играет.
    public func takeOver() async throws -> PlaybackState? {
        let response = try await port.playbackState()
        learnServerTime(response.serverTime)
        disconnect()
        return response.state
    }

    // MARK: - Внутри

    private func send(_ action: RemoteAction, positionMs: Int64? = nil, volume: Int? = nil, queue: [TrackInput]? = nil, index: Int? = nil) async {
        guard let target else { return }
        let command = RemoteCommand(targetDeviceId: target.deviceId, action: action, positionMs: positionMs, volume: volume, queue: queue, index: index)
        do {
            _ = try await port.sendPlaybackCommand(command)
        } catch let error as APIError {
            switch error.code {
            case "device_offline":
                disconnect(with: .offline(name: target.name))
            case "remote_control_disabled":
                disconnect(with: .disabled(name: target.name))
            case "device_not_found":
                disconnect(with: .gone(name: target.name))
            default:
                Log.warning("remote", "Команда \(action.rawValue) не ушла: \(error.code)")
            }
        } catch {
            Log.warning("remote", "Команда \(action.rawValue) не ушла: \(error)")
        }
    }

    private func disconnect(with notice: RemoteNotice) {
        disconnect()
        self.notice = notice
    }

    private func take(_ summary: PlaybackSummary) {
        state = summary
        lastRev = max(lastRev, summary.rev)
        if volumeTask == nil, let reported = summary.volume { volume = reported }
    }

    private func cancelVolume() {
        volumeTask?.cancel()
        volumeTask = nil
    }

    private func learnServerTime(_ iso: String) {
        if let server = IsoTime.date(iso) { serverOffset = server.timeIntervalSince(now()) }
    }
}

/// То, чем пульт управляет на этом устройстве: плеер приложения (`PlayerEngine` в приложении).
@MainActor
public protocol RemotePlayable: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteToggle()
    func remoteNext()
    func remotePrevious()
    func remoteSeek(toMs positionMs: Int64)
    /// 0..100 — громкость плеера приложения.
    func remoteSetVolume(_ volume: Int)
    func remotePlayQueue(_ tracks: [TrackDto], index: Int)
    func remoteStop()
}

/// Выполняет SSE `playback.command` своим плеером (задание 0020 §2 «Выполнять команды»). Итог уходит обычным
/// `PUT /playback/state` из `PlaybackReporter` — отдельного ответа нет. Повтор той же команды не выполняется.
/// `execute` возвращает имя управляющего устройства, когда пора показать «Управляет „Pixel 7 Pro“» (не чаще раза в 30 с).
@MainActor
public final class RemoteCommandExecutor {
    public weak var player: (any RemotePlayable)?

    private let now: @MainActor () -> Date
    private let noticeInterval: TimeInterval
    private var lastNotice: Date?
    private var recent: [String] = []

    public init(now: @escaping @MainActor () -> Date = { Date() }, noticeInterval: TimeInterval = 30) {
        self.now = now
        self.noticeInterval = noticeInterval
    }

    @discardableResult
    public func execute(_ command: PlaybackCommand) -> String? {
        guard let player, let action = command.action, !recent.contains(command.commandId) else { return nil }
        recent.append(command.commandId)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
        switch action {
        case .play: player.remotePlay()
        case .pause: player.remotePause()
        case .toggle: player.remoteToggle()
        case .next: player.remoteNext()
        case .previous: player.remotePrevious()
        case .stop: player.remoteStop()
        case .seek:
            guard let position = command.positionMs else { return nil }
            player.remoteSeek(toMs: max(0, position))
        case .volume:
            guard let volume = command.volume else { return nil }
            player.remoteSetVolume(min(100, max(0, volume)))
        case .playQueue:
            guard let queue = command.queue, !queue.isEmpty else { return nil }
            player.remotePlayQueue(queue, index: min(max(0, command.index ?? 0), queue.count - 1))
        }
        let current = now()
        if let lastNotice, current.timeIntervalSince(lastNotice) < noticeInterval { return nil }
        lastNotice = current
        return command.fromDeviceName ?? ""
    }
}
