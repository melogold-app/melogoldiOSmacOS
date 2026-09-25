import Foundation
import Observation
import MelogoldCore
import MelogoldData

/// Что делает синхронизация — для экранов аккаунта.
public enum SyncStatus: Equatable, Sendable {
    /// Нет аккаунта или нет базы.
    case off
    case idle(lastSyncAt: Date?)
    case syncing
    /// `offline` — сервер не ответил (сети нет или он недоступен); повтор — сам, с растущей паузой.
    case failed(offline: Bool, lastSyncAt: Date?)
    /// Сервер не говорит на протоколе синка этого клиента (`409 protocol_unsupported`): нужно обновить приложение.
    case incompatible
}

/// Действие безопасности на другом устройстве (`account.updated`, API §4.3, §6): карточка в «Аккаунте».
public struct AccountWarning: Equatable, Sendable, Identifiable {
    public let id: String
    /// `password_changed`, `password_changed_without_old` или `recovery_code_rotated`.
    public let reason: String
    public let byDeviceId: String?
    public let byDeviceName: String?
}

/// Устройство, чьи прослушивания лежат в Истории (задание 0002 §3.5).
public struct HistoryDevice: Equatable, Sendable, Identifiable {
    public let id: String
    /// Имя из списка устройств аккаунта; `nil` — устройства в аккаунте уже нет («Другое устройство»).
    public let name: String?
    public let platform: String?
}

/// Паузы синка. Тесты сжимают их.
public struct SyncTiming: Sendable {
    /// Правка библиотеки уходит через столько после последней правки.
    public var localChangeDelay: Duration
    /// Повтор неудавшейся синхронизации: 2 с·2^n до 5 мин (DESIGN §3.13.4).
    public var retrySteps: [Duration]
    /// После закрытия потока событий сервером — случайная пауза до стольких, затем `liveSteps` (API §6).
    public var liveFirstDelayMax: Duration
    public var liveSteps: [Duration]
    /// Поток событий открывается заново за столько до истечения access-токена (API §6).
    public var reopenBeforeExpiry: Duration
    /// `/server/info` перечитывается не чаще: модуль текстов может появиться, пока приложение открыто.
    public var featuresMaxAge: Duration
    /// Выход на передний план при живом потоке событий синхронизирует не чаще.
    public var foregroundInterval: Duration

    public init(
        localChangeDelay: Duration = .seconds(2),
        retrySteps: [Duration] = [2, 4, 8, 16, 32, 64, 128, 256, 300].map { .seconds($0) },
        liveFirstDelayMax: Duration = .seconds(15),
        liveSteps: [Duration] = [1, 2, 5, 10, 30, 60, 120, 300].map { .seconds($0) },
        reopenBeforeExpiry: Duration = .seconds(60),
        featuresMaxAge: Duration = .seconds(30 * 60),
        foregroundInterval: Duration = .seconds(60)
    ) {
        self.localChangeDelay = localChangeDelay
        self.retrySteps = retrySteps
        self.liveFirstDelayMax = liveFirstDelayMax
        self.liveSteps = liveSteps
        self.reopenBeforeExpiry = reopenBeforeExpiry
        self.featuresMaxAge = featuresMaxAge
        self.foregroundInterval = foregroundInterval
    }
}

/// Держит библиотеку этого устройства и аккаунта на сервере одинаковыми (API §4.8): Избранное, плейлисты с порядком,
/// сохранённые альбомы, исполнители и каналы, общая история (задание 0002) и свои тексты (задание 0001).
///
/// **Вариант со снимком** (REWRITE §4.12a Android, `sync/SyncEngine.kt`; Windows `LibrarySync.cs`): вместо журнала
/// правок библиотека сравнивается с тем, что было на сервере после прошлой синхронизации (таблицы `synced_*`),
/// разница уходит ops, ответ сервера обновляет и библиотеку, и снимок. Каждая op несёт `base` — курсор снимка: она
/// выигрывает у того, что устройство видело, и сравнивается по времени с тем, чего не видело. Сервер отвечает текущими
/// строками всех ключей, которых коснулись ops, поэтому проигравшая правка сразу приходит победителем.
///
/// Синхронизации идут по одной: при входе и запуске, через 2 с после правки библиотеки, по SSE (`system.connected`,
/// `sync.changed`, `lyrics.changed`), при выходе на передний план и по «Синхронизировать сейчас». Сети заранее не
/// проверяются (на часах Network framework нет, TN3135): неответ сервера — статус «Нет связи» и повтор с паузой.
@MainActor
@Observable
public final class LibrarySync {
    public private(set) var status: SyncStatus = .off
    /// Растёт на `devices.updated`: экраны со списком устройств перечитывают его.
    public private(set) var devicesRevision = 0
    /// Последнее предупреждение `account.updated`; экран его показывает, пока его не закроют.
    public private(set) var accountWarning: AccountWarning?
    /// Поток живых событий открыт (`system.connected` пришёл).
    public private(set) var liveConnected = false
    /// Свой текст, который сервер не принял как слишком большой (413): он остаётся только на этом устройстве.
    public private(set) var rejectedLyrics: String?

    @ObservationIgnored public let account: Account
    @ObservationIgnored let store: SyncStore?
    @ObservationIgnored let timing: SyncTiming
    @ObservationIgnored private let followsLiveEvents: Bool

    @ObservationIgnored private var started = false
    /// Аккаунт, для которого идут синхронизации (`serverId:userId`).
    @ObservationIgnored private var binding: String?
    @ObservationIgnored private var lastSyncAt: Date?
    @ObservationIgnored private var lastCursor: String?
    @ObservationIgnored private var lastFullSync: ContinuousClock.Instant?
    @ObservationIgnored private var featuresCheckedAt: ContinuousClock.Instant?
    @ObservationIgnored private var networkStarted = false

    @ObservationIgnored private var active: Task<Void, Never>?
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var queuedRequest: Request?
    @ObservationIgnored private var queuedId: UUID?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var playRetry: Task<Void, Never>?
    @ObservationIgnored private var live: Task<Void, Never>?
    /// Поток событий ждёт паузы перед переподключением.
    @ObservationIgnored private var liveWaiting = false
    @ObservationIgnored private var observation: SyncObservation?

    nonisolated static let streams = ["library", "history"]
    nonisolated static let maxOps = 500
    /// Бюджет работы одного запроса (API §1.9): Σ(`videoIds` + `entries` + `tracks`).
    nonisolated static let maxWork = 20_000

    /// Что просит повод синхронизации.
    struct Request: Sendable, Equatable {
        /// Спросить сервер, даже если здесь ничего не менялось.
        var force: Bool
        /// Только тексты (`lyrics.changed`): библиотека — лишь если здесь есть неотправленные правки.
        var lyricsOnly: Bool

        static let full = Request(force: true, lyricsOnly: false)
        static let local = Request(force: false, lyricsOnly: false)
        static let lyrics = Request(force: true, lyricsOnly: true)

        mutating func merge(_ other: Request) {
            force = force || other.force
            lyricsOnly = lyricsOnly && other.lyricsOnly
        }
    }

    public init(account: Account, database: AppDatabase?, timing: SyncTiming = SyncTiming(), liveEvents: Bool = true) {
        self.account = account
        self.store = database.map { SyncStore(database: $0) }
        self.timing = timing
        self.followsLiveEvents = liveEvents
    }

    // MARK: - Поводы

    /// Следить за аккаунтом, правками библиотеки и событиями сервера. Вошедший аккаунт синхронизируется сразу.
    public func start() {
        guard !started else { return }
        started = true
        observation = store?.observeLocalChanges { [weak self] in
            Task { @MainActor in self?.localChanged() }
        }
        observeAccount()
        accountChanged()
    }

    public func stop() {
        started = false
        observation?.cancel()
        observation = nil
        binding = nil
        cancelSession()
        status = .off
    }

    /// «Синхронизировать сейчас»: возвращается, когда синхронизация закончилась.
    public func sync() async {
        await enqueue(.full).value
    }

    /// Выход на передний план (iPhone, iPad, Mac, Vision) и открытие часов: синхронизация и живой поток, если он упал.
    public func appDidBecomeActive() {
        guard binding != nil else { return }
        if followsLiveEvents && (live == nil || liveWaiting) { startLive() }
        if liveConnected, let lastFullSync, ContinuousClock.now - lastFullSync < timing.foregroundInterval { return }
        enqueue(.full)
    }

    /// Уход в фон: правки, которые ждут паузы 2 с, уходят сразу.
    public func flush() {
        guard binding != nil, let pending = debounce else { return }
        pending.cancel()
        debounce = nil
        enqueue(.local)
    }

    public func dismissAccountWarning() {
        accountWarning = nil
    }

    private func observeAccount() {
        withObservationTracking {
            _ = account.session?.binding
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.accountChanged()
                self.observeAccount()
            }
        }
    }

    /// Вход, выход, конец сеанса или другой аккаунт. Обновление токенов binding не меняет — ничего не происходит.
    private func accountChanged() {
        let current = account.session?.binding
        guard current != binding else { return }
        binding = current
        cancelSession()
        guard current != nil, store != nil else {
            status = .off
            return
        }
        status = .idle(lastSyncAt: nil)
        enqueue(.full)
        if followsLiveEvents { startLive() }
    }

    private func cancelSession() {
        active?.cancel()
        queued?.cancel()
        active = nil
        queued = nil
        queuedRequest = nil
        queuedId = nil
        for task in [debounce, retry, playRetry, live] { task?.cancel() }
        debounce = nil
        retry = nil
        playRetry = nil
        live = nil
        retryCount = 0
        liveConnected = false
        liveWaiting = false
        accountWarning = nil
        lastSyncAt = nil
        lastCursor = nil
        lastFullSync = nil
    }

    /// Правка Избранного, плейлистов, закладок, своих текстов или истории уходит через 2 с. Свои записи синка тоже
    /// сюда попадают: следующий проход находит ноль ops и в сеть не идёт.
    private func localChanged() {
        guard binding != nil else { return }
        debounce?.cancel()
        let delay = timing.localChangeDelay
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.enqueue(.local)
        }
    }

    /// Синхронизации идут по одной; поводы, пришедшие во время синхронизации, сливаются в следующую.
    @discardableResult
    private func enqueue(_ request: Request) -> Task<Void, Never> {
        if let queued {
            queuedRequest?.merge(request)
            return queued
        }
        let id = UUID()
        queuedId = id
        queuedRequest = request
        let previous = active
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.queuedId == id else { return }
            self.active = self.queued
            self.queued = nil
            self.queuedId = nil
            guard let request = self.queuedRequest else { return }
            self.queuedRequest = nil
            await self.run(request)
        }
        queued = task
        return task
    }

    // MARK: - Синхронизация

    private func run(_ request: Request) async {
        guard let store, let session = account.session, binding == nil || binding == session.binding else { return }
        let runBinding = session.binding
        networkStarted = false
        do {
            if lastSyncAt == nil {
                lastSyncAt = try await store.state(SyncStateKey.lastSyncAt).flatMap { Int64($0) }.map { Self.date($0) }
            }
            try await syncOnce(request, store: store, binding: runBinding)
            retry?.cancel()
            retry = nil
            retryCount = 0
            if networkStarted {
                status = .idle(lastSyncAt: lastSyncAt)
                if request.force && !request.lyricsOnly { lastFullSync = .now }
            }
        } catch is CancellationError {
            if status == .syncing { status = .idle(lastSyncAt: lastSyncAt) }
        } catch let error as APIError where error.code == "protocol_unsupported" {
            Log.warning("sync", "Сервер не поддерживает протокол синка \(ServerAPI.syncProtocol)")
            status = .incompatible
        } catch {
            // Сеанс закончился или сменился аккаунт: статус уже выставил accountChanged
            guard account.session?.binding == runBinding else { return }
            let apiError = error as? APIError
            Log.warning("sync", "Синхронизация не прошла: \(error)")
            let offline = apiError.map { $0.isNetwork || [502, 503, 504].contains($0.status) } ?? false
            status = .failed(offline: offline, lastSyncAt: lastSyncAt)
            if let apiError, apiError.status == 0 || apiError.status == 429 || apiError.status >= 500 {
                scheduleRetry(serverDelay: apiError.retryAfterSeconds)
            }
        }
    }

    /// Сеть или сервер недоступны: повтор через 2 с·2^n до 5 мин с разбросом, не раньше `Retry-After`.
    private func scheduleRetry(serverDelay: Int?) {
        guard !timing.retrySteps.isEmpty else { return }
        let step = timing.retrySteps[min(retryCount, timing.retrySteps.count - 1)]
        retryCount += 1
        var delay = step * Double.random(in: 0.8 ... 1.2)
        if let serverDelay { delay = max(delay, .seconds(serverDelay)) }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.enqueue(.full)
        }
    }

    private func beginNetwork() {
        guard !networkStarted else { return }
        networkStarted = true
        status = .syncing
    }

    /// Пока шла сеть, аккаунт мог смениться: ответ прошлого аккаунта в базу не пишется.
    private func ensureBinding(_ binding: String) throws {
        guard account.session?.binding == binding else { throw CancellationError() }
    }

    private func syncOnce(_ request: Request, store: SyncStore, binding: String) async throws {
        try await store.write { tx in
            guard try tx.state(SyncStateKey.binding) != binding else { return }
            // Другой аккаунт или сервер: здесь с ним ничего не синхронизировано, уходит (и сливается) всё
            try tx.forgetBinding()
            try tx.setState(SyncStateKey.binding, binding)
            try tx.setState(SyncStateKey.needsMerge, "1")
            try tx.setState(SyncStateKey.historyMerge, "1")
        }
        if try await store.state(SyncStateKey.needsMerge) == "1" {
            beginNetwork()
            try await planMerge(store: store, binding: binding)
        }

        let ops = try await store.write { [builder = makeBuilder()] tx in try builder.build(tx) }
        if !ops.isEmpty || (request.force && !request.lyricsOnly) {
            beginNetwork()
            try await syncLibrary(ops, store: store, binding: binding)
            // После всех прослушиваний первой синхронизации — накопленное время (`play.baseline`): раньше нельзя,
            // иначе отложенные лимитом play.add прибавились бы к нему ещё раз
            if !ops.isEmpty, try await store.state(SyncStateKey.historyMerge) == "1" {
                let more = try await store.write { [builder = makeBuilder()] tx in try builder.build(tx) }
                if !more.isEmpty { try await syncLibrary(more, store: store, binding: binding) }
            }
        }
        // Тексты — после библиотеки, в том же цикле (задание 0001 §3.3)
        try await syncLyrics(force: request.force, store: store, binding: binding)
    }

    private func makeBuilder() -> SyncOpBuilder {
        SyncOpBuilder(mergeUploadMax: account.serverInfo?.limits?.history?.mergeUploadMax)
    }

    /// Пакет: не больше `maxOps` ops и бюджета работы запроса, но хотя бы одна op.
    nonisolated static func batch(_ ops: [PendingOp], maxOps: Int, maxWork: Int = LibrarySync.maxWork) -> [PendingOp] {
        var count = 0
        var work = 0
        for op in ops {
            if count >= maxOps || (count > 0 && work + op.work > maxWork) { break }
            count += 1
            work += op.work
        }
        return Array(ops.prefix(count))
    }

    private func syncLibrary(_ ops: [PendingOp], store: SyncStore, binding: String) async throws {
        var cursor = try await store.state(SyncStateKey.cursor) ?? ""
        var pending = ops
        var restarted = false
        var maxOps = min(max(account.serverInfo?.limits?.sync?.maxOpsPerRequest ?? Self.maxOps, 1), Self.maxOps)
        while true {
            let batch = Self.batch(pending, maxOps: maxOps)
            let body = SyncRequest(cursor: cursor, limit: nil, streams: Self.streams, ops: batch.map(\.op))
            let response: SyncResponse
            do {
                response = try await account.authorized { api, token in try await api.sync(token: token, body) }
            } catch let error as APIError where error.status == 410 && !restarted {
                // Сервер восстановлен из копии или забыл курсор: прочитать всё заново (API §4.8, 410)
                Log.info("sync", "Курсор отвергнут (\(error.code)) — синхронизация с начала")
                restarted = true
                cursor = ""
                continue
            } catch let error as APIError where error.status == 413 && batch.count > 1 {
                maxOps = max(1, batch.count / 2)
                continue
            }
            try ensureBinding(binding)
            pending.removeFirst(batch.count)
            let now = EpochMs.now()
            let retryAfter = try await store.write { tx in
                let retry = try SyncApply.results(tx, batch: batch, results: response.results, now: now)
                try SyncApply.rows(tx, response, now: now)
                try tx.setState(SyncStateKey.cursor, response.cursor)
                return retry
            }
            lastCursor = response.cursor
            if let retryAfter {
                // Больше 2000 прослушиваний в час (op_rate_limited): остальные — после паузы, которую назвал сервер
                pending.removeAll { $0.kind == "play.add" }
                schedulePlays(after: retryAfter)
            }
            cursor = response.cursor
            if !response.hasMore && pending.isEmpty { break }
        }
        let now = EpochMs.now()
        try await store.write { tx in
            try tx.setState(SyncStateKey.lastSyncAt, String(now))
            try tx.setState(SyncStateKey.needsMerge, "0")
        }
        lastSyncAt = Self.date(now)
    }

    private func schedulePlays(after seconds: Int) {
        playRetry?.cancel()
        playRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.playRetry = nil
            self.enqueue(.local)
        }
    }

    /// Первая синхронизация с аккаунтом: свои плейлисты занимают серверных двойников, а не задваивают их (API §4.7).
    private func planMerge(store: SyncStore, binding: String) async throws {
        let locals = try await store.read { try $0.playlists() }
        guard !locals.isEmpty else { return }
        let body = MergePlanRequest(playlists: locals.map {
            MergePlanInput(localKey: String($0.id), syncId: $0.syncId, name: SyncOpBuilder.playlistName($0.name), browseId: $0.browseId)
        })
        let plan = try await account.authorized { api, token in try await api.mergePlan(token: token, body) }
        try ensureBinding(binding)
        try await store.write { tx in
            for entry in plan.plan where entry.action == "merge" || entry.action == "create" {
                guard let id = Int64(entry.localKey) else { continue }
                try tx.setPlaylistSyncId(id, entry.playlistId)
            }
        }
    }

    // MARK: - Тексты (API §4.10, задание 0001)

    /// Модуль текстов есть на сервере (`features.lyrics`): без него маршруты текстов не трогаются.
    private func lyricsAvailable() async -> Bool {
        let now = ContinuousClock.now
        if account.serverInfo != nil, featuresCheckedAt == nil { featuresCheckedAt = now }
        if account.serverInfo == nil || featuresCheckedAt.map({ now - $0 > timing.featuresMaxAge }) == true {
            do {
                try await account.check()
                featuresCheckedAt = now
            } catch {
                Log.info("sync", "Сведения о сервере не пришли: \(error)")
            }
        }
        return account.serverInfo?.features.lyrics != nil
    }

    /// Цикл текстов (§3.3): свои тексты, изменившиеся со снимка, — `PUT` и `DELETE`; затем свои версии с сервера после
    /// `lyricsRev`. Без своих правок и без `force` сеть не трогается.
    private func syncLyrics(force: Bool, store: SyncStore, binding: String) async throws {
        let sends = try await store.read { tx in LyricsSyncRules.planSends(own: try tx.ownLyrics(), snapshot: try tx.syncedLyrics()) }
        if sends.isEmpty && !force { return }
        guard await lyricsAvailable() else { return }
        beginNetwork()
        for send in sends {
            switch send {
            case .put(let videoId, let payload, let hash):
                if LyricsSyncRules.tooLarge(payload) {
                    try await store.write { try $0.setSyncedLyrics(videoId, rev: LyricsSnapshot.rejected, hash: hash) }
                    rejectedLyrics = videoId
                    continue
                }
                do {
                    let body = LyricsText(payload)
                    let mine = try await account.authorized { api, token in try await api.putLyrics(token: token, videoId: videoId, body) }
                    try ensureBinding(binding)
                    try await store.write { try $0.setSyncedLyrics(videoId, rev: mine.rev, hash: hash) }
                } catch let error as APIError where error.status == 413 || error.status == 400 {
                    // Не отправлять снова, пока текст не изменится; 413 — сказать человеку
                    Log.warning("sync", "Текст \(videoId) не принят: \(error.code)")
                    try ensureBinding(binding)
                    try await store.write { try $0.setSyncedLyrics(videoId, rev: LyricsSnapshot.rejected, hash: hash) }
                    if error.status == 413 { rejectedLyrics = videoId }
                }
            case .delete(let videoId):
                do {
                    try await account.authorized { api, token in try await api.deleteLyrics(token: token, videoId: videoId) }
                } catch let error as APIError where error.status == 404 {
                    // На сервере уже нет — снимок всё равно забыть
                }
                try ensureBinding(binding)
                try await store.write { try $0.forgetSyncedLyrics(videoId) }
            case .forget(let videoId):
                try await store.write { try $0.forgetSyncedLyrics(videoId) }
            }
        }

        var after = try await store.state(SyncStateKey.lyricsRev).flatMap { Int64($0) } ?? 0
        while true {
            let from = after
            let page = try await account.authorized { api, token in try await api.lyricsChanges(token: token, after: from) }
            try ensureBinding(binding)
            try await store.write { tx in
                for item in page.items { try Self.applyLyrics(tx, item) }
                try tx.setState(SyncStateKey.lyricsRev, String(page.rev))
            }
            if !page.more || page.rev <= after { break }
            after = page.rev
        }
    }

    /// Своя версия с сервера: записать с источниками как есть и обновить снимок. Надгробие удаляет свой текст, только
    /// если он не менялся с прошлого синка; изменённый уйдёт на сервер следующей отправкой.
    nonisolated static func applyLyrics(_ tx: SyncTx, _ item: MyLyrics) throws {
        guard !item.deleted, let text = item.text else {
            if LyricsSyncRules.deleteOnTombstone(try tx.lyrics(item.videoId), try tx.syncedLyrics(item.videoId)) {
                try tx.deleteLyrics(item.videoId)
            }
            try tx.forgetSyncedLyrics(item.videoId)
            return
        }
        let stored = LyricsSyncRules.stored(text.payload)
        if !LyricsSyncRules.sameContent(try tx.lyrics(item.videoId), stored) { try tx.saveLyrics(item.videoId, stored) }
        try tx.setSyncedLyrics(item.videoId, rev: item.rev, hash: LyricsSyncRules.hash(LyricsSyncRules.payload(stored)))
    }

    /// Текст с сервера для цепочки поиска (задание 0001 §3.5), когда провайдеры не нашли синхронный: своя версия (ещё
    /// не пришла синком) или общая версия другого пользователя. `nil` — аккаунта или модуля нет, текста нет. Нет связи —
    /// ошибка: цепочка поиска не запоминает «текста нет».
    public func serverLyrics(_ videoId: String) async throws -> (payload: LyricsPayload, mine: Bool)? {
        guard account.isSignedIn, await lyricsAvailable() else { return nil }
        do {
            let response = try await account.authorized { api, token in try await api.lyrics(token: token, videoId: videoId) }
            if let mine = response.mine, !mine.deleted, let text = mine.text { return (text.payload, true) }
            if let shared = response.shared { return (shared.text.payload, false) }
            return nil
        } catch let error as APIError where !error.isNetwork {
            Log.info("sync", "Текст \(videoId) с сервера не пришёл: \(error.code)")
            return nil
        }
    }

    public func dismissRejectedLyrics() {
        rejectedLyrics = nil
    }

    // MARK: - История (задание 0002)

    /// Текущее устройство в аккаунте: его события — «Это устройство» вместе с событиями без `deviceId`.
    public var currentDeviceId: String? { account.session?.deviceId }

    /// Другие устройства, чьи прослушивания лежат в Истории, с именами из списка устройств аккаунта. Пусто — фильтр
    /// Истории не показывается (задание 0002 §3.5).
    public func historyDevices() async -> [HistoryDevice] {
        guard account.isSignedIn, let store, let ids = try? await store.historyDeviceIds() else { return [] }
        let others = ids.subtracting([currentDeviceId].compactMap { $0 })
        guard !others.isEmpty else { return [] }
        let known = (try? await account.devices().devices) ?? []
        let byId = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return others.map { HistoryDevice(id: $0, name: byId[$0]?.name, platform: byId[$0]?.platform) }
            .sorted { ($0.name ?? "\u{10FFFF}", $0.id) < ($1.name ?? "\u{10FFFF}", $1.id) }
    }

    // MARK: - Живые события (API §6)

    private func startLive() {
        live?.cancel()
        liveConnected = false
        liveWaiting = false
        live = Task { [weak self] in await self?.followLive() }
    }

    /// Поток событий, пока аккаунт вошёл. Перед истечением access-токена поток открывается заново с новым токеном;
    /// после прочих закрытий — случайная пауза 0–15 с, затем 1, 2, 5, 10, 30 с и дальше до 5 мин с разбросом.
    private func followLive() async {
        var failures = 0
        while !Task.isCancelled, account.isSignedIn {
            let started = ContinuousClock.now
            var reopen = false
            do {
                reopen = try await account.authorized { api, token in try await self.listen(api: api, token: token) }
            } catch {
                if Task.isCancelled { break }
                Log.info("sync", "Поток событий закрыт: \(error)")
            }
            liveConnected = false
            guard !Task.isCancelled, account.isSignedIn else { break }
            if reopen {
                failures = 0
                continue
            }
            // Долгий поток — не сбой: сервер закрывает его, когда истекает токен
            if ContinuousClock.now - started > .seconds(60) { failures = 0 }
            let delay: Duration = if failures == 0 {
                timing.liveFirstDelayMax * Double.random(in: 0 ... 1)
            } else {
                timing.liveSteps[min(failures - 1, timing.liveSteps.count - 1)] * Double.random(in: 0.8 ... 1.2)
            }
            failures += 1
            liveWaiting = true
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Отменён: новый поток уже запущен или сеанс кончился — флаг сбросили они
                break
            }
            liveWaiting = false
        }
    }

    /// Один поток событий. `true` — закрыт этим клиентом перед истечением токена, открыть новый сразу.
    private func listen(api: ServerAPI, token: String) async throws -> Bool {
        let stream = api.events(token: token)
        let consumer = Task { @MainActor in
            for try await event in stream { self.handle(event) }
        }
        let reopen = ReopenMark()
        var timer: Task<Void, Never>?
        if let expires = account.session?.accessTokenExpiresAt {
            let seconds = expires.timeIntervalSinceNow - Double(timing.reopenBeforeExpiry.components.seconds)
            let delay = Duration.seconds(max(seconds, 10))
            timer = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                reopen.due = true
                consumer.cancel()
            }
        }
        defer { timer?.cancel() }
        try await withTaskCancellationHandler {
            try await consumer.value
        } onCancel: {
            consumer.cancel()
        }
        return reopen.due
    }

    func handle(_ event: LiveEvent) {
        switch event.kind {
        case .connected:
            // Реплея нет: после (пере)подключения — синхронизация и тексты (API §6)
            liveConnected = true
            enqueue(.full)
        case .syncChanged(let cursor):
            if cursor == nil || cursor != lastCursor { enqueue(.full) }
        case .devicesUpdated:
            devicesRevision += 1
        case .sessionInvalidated(let reason):
            account.end(reason: reason)
        case .accountUpdated(let reason, let byDeviceId, let byDeviceName):
            accountWarning = AccountWarning(id: event.id, reason: reason, byDeviceId: byDeviceId, byDeviceName: byDeviceName)
        case .lyricsChanged:
            enqueue(.lyrics)
        case .linkUpdated, .playbackUpdated, .other:
            break
        }
    }

    nonisolated private static func date(_ epochMs: Int64) -> Date {
        Date(timeIntervalSince1970: Double(epochMs) / 1000)
    }
}

/// Поток событий закрыт этим клиентом, чтобы открыть новый с новым токеном.
@MainActor
private final class ReopenMark {
    var due = false
}

extension LyricsText {
    init(_ payload: LyricsPayload) {
        self.init(
            plain: payload.plain, plainSource: payload.plainSource, synced: payload.synced, syncedFormat: payload.syncedFormat,
            syncedSource: payload.syncedSource, startTimeMs: payload.startTimeMs, language: payload.language
        )
    }

    var payload: LyricsPayload {
        LyricsPayload(plain: plain, plainSource: plainSource, synced: synced, syncedFormat: syncedFormat, syncedSource: syncedSource,
                      startTimeMs: startTimeMs, language: language)
    }
}
