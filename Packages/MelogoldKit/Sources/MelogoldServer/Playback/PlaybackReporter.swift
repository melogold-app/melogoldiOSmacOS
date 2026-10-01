import Foundation
import MelogoldCore

/// Что играет здесь — снимок, который приложение строит из своего плеера и отдаёт `PlaybackReporter`.
public struct PlaybackSnapshot: Equatable, Sendable {
    /// Вся очередь плеера; окно до 200 треков вокруг текущего выбирает отчёт.
    public var queue: [TrackInput]
    /// Меняется при каждой смене состава или порядка очереди (у плеера — ревизия очереди).
    public var queueIdentity: Int
    public var index: Int
    public var positionMs: Int64
    public var durationMs: Int64?
    public var playing: Bool
    /// 0..100 — громкость плеера приложения.
    public var volume: Int

    public init(queue: [TrackInput], queueIdentity: Int, index: Int, positionMs: Int64, durationMs: Int64?, playing: Bool, volume: Int) {
        self.queue = queue
        self.queueIdentity = queueIdentity
        self.index = index
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.playing = playing
        self.volume = volume
    }
}

/// Сообщает серверу, что играет на этом устройстве (`PUT /playback/state`, API §4.9, DESIGN §3.12.2, задание 0020):
/// другие устройства видят это в «Слушать здесь» и в пульте.
///
/// - Приложение зовёт `update(_:)` при любом изменении плеера и раз в секунду, пока играет; отчёт сам решает, значимо
///   ли изменение: другой трек или очередь, пауза, перемотка (позиция разошлась с ожидаемой больше чем на 3 с),
///   громкость на 5 и больше. Значимое уходит не чаще раза в секунду (последнее за это время), пока играет — ещё и раз
///   в 60 с.
/// - Не публикует, пока в этом сеансе звук ни разу не играл, и пока `enabled == false` (нет входа, сервер без функции).
/// - `queueVersion` растёт при смене очереди; очередь (до 200 треков вокруг текущего) уходит, только если пара
///   `(sessionId, queueVersion)` сменилась с последнего принятого PUT; `409 playback_queue_required` — ещё раз с ней.
/// - `handed_off` (или SSE с передачей этого сеанса) — воспроизведение забрало другое устройство: `onHandedOff`,
///   новый сеанс (DESIGN §3.12.6).
@MainActor
public final class PlaybackReporter {
    public var enabled = false {
        didSet {
            if !enabled {
                timer?.cancel()
                timer = nil
                heartbeatTimer?.cancel()
                heartbeatTimer = nil
                pending = nil
            }
        }
    }
    /// Воспроизведение забрали на другом устройстве: приложение ставит паузу и говорит об этом.
    public var onHandedOff: ((PlaybackState?) -> Void)?

    public private(set) var sessionId = UUID().uuidString.lowercased()
    public private(set) var queueVersion = 0

    /// Сервер держит до 200 треков очереди (DESIGN §3.12.1): 50 до текущего и 149 после.
    public static let windowBefore = 50
    public static let windowSize = 200
    static let seekThresholdMs: Int64 = 3000
    static let volumeStep = 5

    private let send: @MainActor (PlaybackPut) async throws -> PlaybackPutResult
    private let now: @MainActor () -> Date
    private let coalesce: Duration
    private let heartbeat: TimeInterval
    private var hasPlayed = false
    private var lastQueueIdentity: Int?
    private var acceptedQueueKey: String?
    private var handoff: PlaybackHandoff?
    private var latest: PlaybackSnapshot?
    private var pending: PlaybackSnapshot?
    private var lastSent: (snapshot: PlaybackSnapshot, at: Date, queueVersion: Int)?
    /// Отложенная отправка значимого изменения.
    private var timer: Task<Void, Never>?
    /// Отправка раз в 60 с, пока играет; значимое изменение её обгоняет.
    private var heartbeatTimer: Task<Void, Never>?
    private var sending = false
    /// Сбои подряд и когда пробовать снова: без сети или с упавшим сервером отправка не долбит сервер в цикле (было
    /// ~1900 попыток за 6 с), а ждёт 2, 4, 8… до 60 с; удача сбрасывает.
    private var failures = 0
    private var retryAt: Date?
    static let maxRetryDelay: TimeInterval = 60

    public init(
        send: @escaping @MainActor (PlaybackPut) async throws -> PlaybackPutResult,
        now: @escaping @MainActor () -> Date = { Date() },
        coalesce: Duration = .seconds(1),
        heartbeat: TimeInterval = 60
    ) {
        self.send = send
        self.now = now
        self.coalesce = coalesce
        self.heartbeat = heartbeat
    }

    /// Новое состояние плеера. Дёшево: сеть — только при значимом изменении.
    public func update(_ snapshot: PlaybackSnapshot) {
        if snapshot.playing { hasPlayed = true }
        if lastQueueIdentity != snapshot.queueIdentity {
            if lastQueueIdentity != nil { queueVersion += 1 }
            lastQueueIdentity = snapshot.queueIdentity
        }
        latest = snapshot
        guard enabled, hasPlayed, !snapshot.queue.isEmpty else { return }
        if isSignificant(snapshot) {
            pending = snapshot
            schedule()
        }
    }

    /// «Слушать здесь»: новый сеанс, который забирает воспроизведение у `from` (следующий PUT несёт `handoffFrom`).
    public func takeOver(from state: PlaybackState) {
        startNewSession()
        handoff = PlaybackHandoff(deviceId: state.deviceId, sessionId: state.sessionId)
        hasPlayed = true
    }

    /// SSE `playback.updated`: если другое устройство забрало этот сеанс меньше 5 минут назад — `onHandedOff`.
    public func noticeUpdate(_ summary: PlaybackSummary, myDeviceId: String) {
        guard let from = summary.handoffFrom, from.deviceId == myDeviceId, from.sessionId == sessionId else { return }
        if let at = IsoTime.date(from.at), now().timeIntervalSince(at) > 300 { return }
        handedOff(state: nil)
    }

    // MARK: - Внутри

    private func isSignificant(_ snapshot: PlaybackSnapshot) -> Bool {
        guard let last = lastSent else { return true }
        let previous = last.snapshot
        if last.queueVersion != queueVersion || previous.index != snapshot.index || previous.playing != snapshot.playing {
            return true
        }
        if abs(previous.volume - snapshot.volume) >= Self.volumeStep { return true }
        let elapsed = previous.playing ? Int64(now().timeIntervalSince(last.at) * 1000) : 0
        if abs(snapshot.positionMs - (previous.positionMs + elapsed)) > Self.seekThresholdMs { return true }
        return snapshot.playing && now().timeIntervalSince(last.at) >= heartbeat
    }

    private func schedule() {
        guard timer == nil else { return }
        // Первое значимое после паузы — сразу, следующее — не раньше чем через секунду после предыдущего; после сбоя —
        // не раньше срока повтора
        let recentlySent = lastSent.map { now().timeIntervalSince($0.at) < 1 } ?? false
        var delay = recentlySent ? coalesce : .zero
        if let retryAt {
            let wait = retryAt.timeIntervalSince(now())
            if wait > 0 { delay = max(delay, .milliseconds(Int(wait * 1000))) }
        }
        timer = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        timer = nil
        guard enabled, !sending, let snapshot = pending else { return }
        pending = nil
        sending = true
        defer {
            sending = false
            // Пока шёл запрос, пришло ещё: следующий через секунду
            if pending != nil { schedule() }
            scheduleHeartbeat()
        }
        let (window, index) = Self.window(snapshot.queue, index: snapshot.index)
        guard !window.isEmpty else { return }
        let key = "\(sessionId):\(queueVersion)"
        var body = PlaybackPut(
            sessionId: sessionId, queueVersion: queueVersion, at: IsoTime.string(now()), index: index,
            positionMs: max(0, snapshot.positionMs), durationMs: snapshot.durationMs, playing: snapshot.playing,
            queue: acceptedQueueKey == key ? nil : window, handoffFrom: handoff,
            volume: min(100, max(0, snapshot.volume))
        )
        let sentVersion = queueVersion
        do {
            var result: PlaybackPutResult
            do {
                result = try await send(body)
            } catch let error as APIError where error.code == "playback_queue_required" && body.queue == nil {
                body.queue = window
                result = try await send(body)
            }
            failures = 0
            retryAt = nil
            if result.applied {
                acceptedQueueKey = "\(body.sessionId):\(sentVersion)"
                handoff = nil
                lastSent = (snapshot, now(), sentVersion)
            } else if result.reason == "handed_off" {
                handedOff(state: result.state)
            } else {
                // newer_state: у другого устройства состояние новее — ждём следующего изменения здесь
                lastSent = (snapshot, now(), sentVersion)
            }
        } catch is CancellationError {
            pending = pending ?? snapshot
        } catch {
            // Без сети хранится только последний снимок (DESIGN §3.12.2): уйдёт после паузы повтора или со следующим
            // изменением, но не раньше срока повтора
            pending = pending ?? snapshot
            failures += 1
            let wait = min(Self.maxRetryDelay, pow(2, Double(min(failures, 6))))
            retryAt = now().addingTimeInterval(wait)
            Log.warning("playback", "Состояние воспроизведения не отправлено (повтор через \(Int(wait)) с): \(error)")
        }
    }

    private func scheduleHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        guard let latest, latest.playing, enabled else { return }
        let interval = heartbeat
        heartbeatTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            self.heartbeatTimer = nil
            if let current = self.latest { self.update(current) }
        }
    }

    private func handedOff(state: PlaybackState?) {
        startNewSession()
        hasPlayed = false
        onHandedOff?(state)
    }

    private func startNewSession() {
        sessionId = UUID().uuidString.lowercased()
        acceptedQueueKey = nil
        lastSent = nil
        pending = nil
        timer?.cancel()
        timer = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Окно очереди для сервера (DESIGN §3.12.1): только треки YouTube, `[index−50, index+149]`, без карты
    /// исполнителей — тело укладывается в предел сервера. Текущий не с YouTube — публиковать нечего.
    static func window(_ queue: [TrackInput], index: Int) -> (tracks: [TrackInput], index: Int) {
        guard queue.indices.contains(index), isYouTube(queue[index].videoId) else { return ([], 0) }
        var tracks: [TrackInput] = []
        var newIndex = 0
        for (offset, item) in queue.enumerated() where isYouTube(item.videoId) {
            if offset == index { newIndex = tracks.count }
            var slim = item
            slim.artists = nil
            tracks.append(slim)
        }
        let start = max(0, newIndex - windowBefore)
        let end = min(tracks.count, newIndex - windowBefore + windowSize)
        return (Array(tracks[start ..< end]), newIndex - start)
    }

    public static func isYouTube(_ videoId: String) -> Bool {
        videoId.count == 11 && videoId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
