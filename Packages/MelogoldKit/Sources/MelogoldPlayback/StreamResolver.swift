import Foundation
import MelogoldCore
import MelogoldInnerTube

/// Получает адрес потока трека на чистом Swift, без yt-dlp (docs/PROMPT.md §4): запрос InnerTube `player`
/// клиентами из `StreamClients`, которые отдают прямые ссылки без расшифровки подписи (сейчас VISIONOS).
///
/// - формат — itag 140 (AAC в m4a), запасной 139; Opus AVFoundation не играет;
/// - адреса кэшируются (LRU на 64) до `expire − 5 мин`; сброс — на 403 и при смене сети;
/// - одновременно не больше двух извлечений, у каждого сторож 20 с; один трек не резолвится дважды параллельно;
/// - к YouTube на трек уходит один запрос, пока он отвечает по делу: следующий клиент из списка пробуется, только если
///   причина в клиенте (сеть, таймаут, пустой ответ). Проверка на бота (`StreamError.stopsQueue`, в том числе 429) —
///   это адрес, а не клиент и не трек: ошибка уходит сразу, без следующего клиента и без диагноза, потому что каждый
///   лишний запрос углубляет блок;
/// - после проверки на бота адрес 10 минут считается закрытым: фоновые запросы (заготовка следующих треков, загрузки)
///   не доходят до YouTube и сразу получают ту же ошибку. Один запрос пробует только действие пользователя
///   (`userInitiated`: нажатие, «Далее», «Повторить»); успех снимает метку, смена сети (`invalidateAll`) — тоже. Фоновые
///   извлечения идут по одному, чтобы в момент блока не ушло сразу несколько запросов.
public actor StreamResolver {
    public static let cacheSize = 64
    public static let watchdogSeconds: Double = 20
    public static let maxConcurrent = 2
    /// Сколько адрес считается закрытым после проверки на бота.
    public static let blockMemory: TimeInterval = 10 * 60

    private let catalog: YouTubeMusic
    private var clients: [ClientProfile] = StreamClients.builtIn
    private var cache: [StreamInfo] = []
    private var inFlight: [String: InFlight] = [:]
    private var active = 0
    private var backgroundBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let preferredItags: [Int]
    private let now: @Sendable () -> Date
    /// Последняя проверка на бота: когда и какой ошибкой.
    private var blocked: (error: StreamError, at: Date)?

    private struct InFlight {
        var task: Task<StreamInfo, any Error>
        var userInitiated: Bool
        var token: UUID
    }

    public init(catalog: YouTubeMusic, preferredItags: [Int] = [140, 139], now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.preferredItags = preferredItags
        self.now = now
    }

    public func setClients(_ profiles: [ClientProfile]) {
        guard !profiles.isEmpty else { return }
        clients = profiles
    }

    public var clientNames: [String] { clients.map(\.name) }

    /// Адрес из кэша, если он ещё жив.
    public func cached(_ videoId: String) -> StreamInfo? {
        guard let index = cache.firstIndex(where: { $0.videoId == videoId }) else { return nil }
        let info = cache.remove(at: index)
        guard info.expiresAt > Date() else { return nil }
        cache.insert(info, at: 0)
        return info
    }

    /// Закрыт ли адрес: проверка на бота была меньше `blockMemory` назад и с тех пор не было удачи или смены сети.
    /// Возвращает ту ошибку, которой YouTube ответил; `nil` — адрес свободен.
    public var blockedError: StreamError? {
        guard let blocked, now().timeIntervalSince(blocked.at) < Self.blockMemory else { return nil }
        return blocked.error
    }

    /// Адрес потока трека. `userInitiated` — решение пользователя (нажатие, «Далее», «Повторить»): пока адрес закрыт,
    /// такой вызов пробует один запрос. Фоновый (по умолчанию) закрытый адрес не беспокоит: ошибка приходит сразу, без
    /// запроса. Адрес из кэша отдаётся всегда — запроса он не требует.
    public func resolve(_ videoId: String, userInitiated: Bool = false) async throws -> StreamInfo {
        if let hit = cached(videoId) { return hit }
        if !userInitiated, let error = blockedError {
            Log.info("stream", "\(videoId): запрос не отправлен — YouTube не пускает адрес (\(error.kind.rawValue))")
            throw error
        }
        // К уже идущему фоновому извлечению пользователь не присоединяется, если адрес закрыт: оно вернёт ошибку без запроса.
        if let running = inFlight[videoId], running.userInitiated || !userInitiated || blockedError == nil {
            return try await running.task.value
        }
        let task = Task { try await self.extract(videoId, userInitiated: userInitiated) }
        let token = UUID()
        inFlight[videoId] = InFlight(task: task, userInitiated: userInitiated, token: token)
        defer { if inFlight[videoId]?.token == token { inFlight[videoId] = nil } }
        return try await task.value
    }

    /// Забыть метку «адрес закрыт» (пользователь нажал «Повторить» у загрузок): следующий запрос уйдёт в YouTube.
    public func forgetBlock() {
        blocked = nil
    }

    /// Забыть адрес трека (403 при чтении): следующий резолв спросит заново.
    public func invalidate(_ videoId: String) {
        cache.removeAll { $0.videoId == videoId }
    }

    /// Сеть сменилась: адреса googlevideo привязаны к адресу клиента, сбрасываются все.
    /// Новая сеть — и новый адрес: метка «закрыт» тоже снимается.
    public func invalidateAll() {
        cache.removeAll()
        blocked = nil
    }

    /// Место под извлечение: не больше `maxConcurrent` сразу, из них фоновое — одно.
    private func acquire(background: Bool) async {
        while active >= Self.maxConcurrent || (background && backgroundBusy) {
            await withCheckedContinuation { waiters.append($0) }
        }
        active += 1
        if background { backgroundBusy = true }
    }

    private func release(background: Bool) {
        active -= 1
        if background { backgroundBusy = false }
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func extract(_ videoId: String, userInitiated: Bool) async throws -> StreamInfo {
        await acquire(background: !userInitiated)
        defer { release(background: !userInitiated) }
        if let hit = cached(videoId) { return hit }
        // Пока ждали место, соседний запрос мог получить проверку на бота.
        if !userInitiated, let error = blockedError {
            Log.info("stream", "\(videoId): запрос не отправлен — YouTube не пускает адрес (\(error.kind.rawValue))")
            throw error
        }
        var last: StreamError?
        // Проверка на бота бывает у одного клиента, а у другого нет (30.09.2026, выход VPN в Германии: VISIONOS и
        // ANDROID_VR — «вы не бот», IOS — поток): каждый клиент спрашивается один раз, а адрес закрыт, только когда
        // отказали все
        var botCheck: StreamError?
        for profile in clients {
            try Task.checkCancellation()
            let started = Date()
            do {
                let info = try await withWatchdog { try await self.fromClient(profile, videoId) }
                remember(info)
                blocked = nil
                Log.info("stream", "\(videoId): поток \(profile.name), itag \(info.itag), \(Int(Date().timeIntervalSince(started) * 1000)) мс")
                return info
            } catch let error as StreamError where error.isFinal {
                Log.warning("stream", "\(videoId): \(error)")
                throw await diagnose(videoId, error)
            } catch let error as StreamError where error.stopsQueue {
                Log.warning("stream", "\(videoId): \(profile.name) — \(error)")
                botCheck = error
            } catch let error as StreamError {
                Log.warning("stream", "\(videoId): \(profile.name) — \(error)")
                last = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = StreamError(.network, error.localizedDescription)
            }
        }
        if let botCheck {
            // Ни один клиент не дал потока, и YouTube просит подтвердить, что это не бот: без диагноза и повторов
            blocked = (botCheck, now())
            Log.warning("stream", "\(videoId): YouTube не пускает адрес — без диагноза и повторов, фон молчит 10 минут")
            throw botCheck
        }
        throw await diagnose(videoId, last ?? StreamError(.extractor, "no stream clients"))
    }

    /// Поток не получен: один вопрос YouTube, почему (задание 0010). Без сети и по таймауту не спрашивается. Одна
    /// строка в журнале (и в отчёте «Диагностики»): трек, итог, ответ YouTube, страна, число стран, сообщение клиента.
    private func diagnose(_ videoId: String, _ error: StreamError) async -> StreamError {
        guard error.kind != .network, error.kind != .timeout, !Task.isCancelled,
              let playability = await catalog.playability(videoId: videoId) else { return error }
        let result = StreamError.diagnosed(playability, streamMessage: error.message) ?? error
        Log.warning("stream", "\(videoId): итог \(result.kind.rawValue); YouTube \(playability.status ?? "—") «\(playability.reason ?? "")»; "
            + "страна \(playability.country ?? "—"), открыт в \(playability.availableCountries.count) странах; клиент потока: \(error.message)")
        return result
    }

    private func withWatchdog(_ work: @escaping @Sendable () async throws -> StreamInfo) async throws -> StreamInfo {
        try await withThrowingTaskGroup(of: StreamInfo.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.watchdogSeconds))
                throw StreamError(.timeout, "YouTube не ответил за \(Int(Self.watchdogSeconds)) с")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StreamError(.timeout, "no result") }
            return first
        }
    }

    private func remember(_ info: StreamInfo) {
        cache.removeAll { $0.videoId == info.videoId }
        cache.insert(info, at: 0)
        if cache.count > Self.cacheSize { cache.removeLast(cache.count - Self.cacheSize) }
    }

    private func fromClient(_ profile: ClientProfile, _ videoId: String) async throws -> StreamInfo {
        let response: PlayerResponse
        do {
            try await catalog.client.ensureVisitorData()
            response = try await catalog.player(videoId: videoId, profile: profile)
        } catch let error as YouTubeError {
            throw StreamError(error.kind == .blocked ? .botCheck : .network, error.message)
        }
        guard response.status == "OK" else {
            let text = "\(response.status) \(response.reason ?? "")"
            throw StreamError(StreamError.classify(text), "\(profile.name): \(text)".trimmingCharacters(in: .whitespaces))
        }
        let formats = response.audioFormats
        let chosen = preferredItags.lazy.compactMap { itag in formats.first { $0.itag == itag } }.first
            ?? formats.filter { $0.mimeType.hasPrefix("audio/mp4") }.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard let chosen else { throw StreamError(.extractor, "\(profile.name): нет AAC с прямой ссылкой") }
        return StreamInfo(
            videoId: videoId, url: chosen.url, itag: chosen.itag, mimeType: chosen.mimeType, contentLength: chosen.contentLength,
            bitrate: chosen.bitrate, expiresAt: StreamInfo.expiry(of: chosen.url), source: profile.name,
            userAgent: profile.mediaUserAgent, loudnessDb: chosen.loudnessDb ?? response.loudnessDb,
            durationMs: chosen.approxDurationMs ?? response.durationMs
        )
    }
}
