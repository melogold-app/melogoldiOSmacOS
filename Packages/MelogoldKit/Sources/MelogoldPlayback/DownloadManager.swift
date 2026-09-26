import Foundation
import Observation
import MelogoldCore
import MelogoldData

/// Загрузчик (REWRITE §4.7): берёт из плана `DownloadStore` треки в очереди и качает их кусками по 1 МБ — тем же путём,
/// что плеер (`StreamSource`: свежий адрес на 403, повторы сети). Две загрузки одновременно, три попытки; гео-блок,
/// «недоступно» и возрастное ограничение — сразу ошибка. Без сети, без Wi‑Fi при «Только по Wi‑Fi» и без места —
/// ожидание с причиной.
///
/// iPhone, iPad, Mac, Vision: загрузка идёт, пока приложение открыто или играет музыка (docs/PROMPT.md §4). Часы: все
/// куски трека ставятся сразу в фоновую сессию URLSession — система докачивает без приложения (§5.6).
@MainActor
@Observable
public final class DownloadManager {
    /// Растёт при любой смене состояний — экраны перечитывают строки.
    public private(set) var revision = 0
    /// Доля скачанного у треков в работе.
    public private(set) var progress: [String: Double] = [:]
    /// «Только по Wi‑Fi».
    public var wifiOnly = false {
        didSet { if oldValue != wifiOnly { pump() } }
    }

    public let store: DownloadStore
    private let resolver: StreamResolver
    private let session: URLSession
    private var workers: [String: Task<Void, Never>] = [:]
    /// Есть ли сеть и сотовая ли она — от приложения (`NWPathMonitor`).
    @ObservationIgnored public var network: () -> (online: Bool, cellular: Bool) = { (true, false) }
    public static let maxParallel = 2
    static let chunk = 1 << 20
    /// Сколько места оставить свободным после загрузки: часы — 1 ГБ (§5.6), остальные — 500 МБ (REWRITE §4.7.5).
    static let reserve: Int64 = {
        #if os(watchOS)
        1_000_000_000
        #else
        500_000_000
        #endif
    }()

    #if os(watchOS)
    @ObservationIgnored private var background: BackgroundDownloads?
    #endif

    public init(store: DownloadStore, resolver: StreamResolver) {
        self.store = store
        self.resolver = resolver
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        HTTPConfiguration.apply(to: configuration)
        session = URLSession(configuration: configuration)
    }

    /// Старт приложения: сверка с папкой и планом, затем очередь.
    public func start() {
        let store = store
        Task.detached(priority: .utility) {
            store.reconcileFiles()
            await MainActor.run { [weak self] in
                #if os(watchOS)
                self?.background = BackgroundDownloads(manager: self)
                #endif
                self?.changed()
                self?.pump()
            }
        }
    }

    /// План поменялся (лайк, плейлист, «Скачать»): сверить и продолжить.
    public func planChanged() {
        let store = store
        Task.detached(priority: .utility) {
            let changed = store.reconcile()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Треки, которые больше не нужны, останавливаются.
                for (videoId, task) in self.workers where store.entry(videoId) == nil {
                    task.cancel()
                    self.workers[videoId] = nil
                    self.progress[videoId] = nil
                }
                if changed { self.changed() }
                self.pump()
            }
        }
    }

    public func download(_ track: Track) {
        store.requestTrack(track)
        changed()
        pump()
    }

    public func remove(_ videoId: String) {
        workers[videoId]?.cancel()
        workers[videoId] = nil
        progress[videoId] = nil
        store.removeTrack(videoId)
        changed()
    }

    public func setCollection(_ kind: DownloadCollection.Kind, key: String, title: String?, downloading: Bool) {
        store.setCollection(kind, key: key, title: title, downloading: downloading)
        planChanged()
    }

    public func retryFailed() {
        store.retryFailed()
        changed()
        pump()
    }

    public func retry(_ videoId: String) {
        store.retry(videoId)
        changed()
        pump()
    }

    /// «Пауза» и «Продолжить» у всех активных загрузок.
    public func setPaused(_ paused: Bool) {
        if paused {
            for task in workers.values { task.cancel() }
            workers.removeAll()
            progress.removeAll()
        }
        store.setPaused(paused)
        changed()
        if !paused { pump() }
    }

    public var isPaused: Bool {
        store.entries().contains { $0.state == .paused }
    }

    public func removeAll() {
        for task in workers.values { task.cancel() }
        workers.removeAll()
        progress.removeAll()
        store.removeAll()
        changed()
    }

    /// Сеть или настройки поменялись — ожидающие пробуют снова.
    public func networkChanged() {
        pump()
    }

    // MARK: - Очередь

    /// Занять свободные места загрузками из очереди.
    public func pump() {
        let free = Self.maxParallel - workers.count
        guard free > 0 else { return }
        let candidates = store.pending(limit: free + workers.count).filter { workers[$0] == nil }.prefix(free)
        for videoId in candidates {
            if let reason = waitReason() {
                store.setState(videoId, .waiting, wait: reason)
                changed()
                continue
            }
            workers[videoId] = Task { [weak self] in
                await self?.run(videoId)
            }
        }
    }

    private func waitReason() -> DownloadWait? {
        let state = network()
        if !state.online { return .network }
        if wifiOnly, state.cellular { return .wifi }
        return nil
    }

    private func changed() {
        revision &+= 1
    }

    private func finish(_ videoId: String) {
        workers[videoId] = nil
        progress[videoId] = nil
        changed()
        pump()
    }

    /// Один трек: формат и длина, место, затем куски по порядку с того места, где остановились.
    private func run(_ videoId: String) async {
        defer { finish(videoId) }
        store.setState(videoId, .downloading)
        changed()
        let source = StreamSource(videoId: videoId, resolver: resolver, cache: nil, session: session)
        do {
            let content = try await source.contentInfo()
            let info = await source.streamInfo
            if let free = Self.freeSpace(at: store.directory), free - content.length < Self.reserve {
                Log.warning("downloads", "\(videoId): мало места — ждём")
                store.setState(videoId, .waiting, wait: .storage)
                return
            }
            store.prepare(videoId, itag: info?.itag ?? 140, mimeType: content.mimeType, contentLength: content.length,
                          durationMs: content.durationMs, loudnessDb: content.loudnessDb)
            #if os(watchOS)
            if let background, let info {
                background.enqueue(videoId: videoId, info: info, length: content.length, missing: store.missing(videoId))
                return
            }
            #endif
            while let missing = store.missing(videoId) {
                try Task.checkCancellation()
                let length = Int(min(Int64(Self.chunk), missing.upperBound - missing.lowerBound))
                let data = try await source.read(offset: missing.lowerBound, length: length)
                guard !data.isEmpty else { throw StreamError(.network, "пустой ответ googlevideo") }
                try Task.checkCancellation()
                if store.write(videoId, offset: missing.lowerBound, data: data) { break }
                progress[videoId] = Double(missing.lowerBound + Int64(data.count)) / Double(max(1, content.length))
            }
            Log.info("downloads", "\(videoId): скачан, \(content.length / 1024) КБ")
        } catch is CancellationError {
            return
        } catch {
            let streamError = error as? StreamError ?? StreamError(.network, error.localizedDescription)
            failed(videoId, streamError)
        }
    }

    /// Ошибка: окончательные классы — сразу `failed`, прочие — до трёх попыток.
    func failed(_ videoId: String, _ error: StreamError) {
        let attempts = store.incrementAttempts(videoId)
        Log.warning("downloads", "\(videoId): \(error) (попытка \(attempts))")
        if error.isFinal || attempts >= 3 {
            store.setState(videoId, .failed, failure: error.kind.rawValue)
        } else {
            store.setState(videoId, .queued)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(attempts * 5))
                self?.pump()
            }
        }
    }

    /// Свободное место для важных данных.
    static func freeSpace(at url: URL) -> Int64? {
        #if os(watchOS)
        // На watchOS «для важных данных» нет — только общая свободная ёмкость тома.
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    #if os(watchOS)
    /// Куски от фоновой сессии.
    func backgroundChunk(videoId: String, offset: Int64, data: Data) {
        if store.write(videoId, offset: offset, data: data) {
            progress[videoId] = nil
            Log.info("downloads", "\(videoId): скачан в фоне")
        } else if let entry = store.entry(videoId), let length = entry.contentLength {
            progress[videoId] = Double(entry.downloadedBytes) / Double(max(1, length))
        }
        changed()
    }

    /// Кусок не пришёл (истёк адрес, сеть): трек — снова в очередь, при следующем открытии возьмётся свежий адрес.
    func backgroundFailed(videoId: String, status: Int?) {
        if let status, [401, 403, 410].contains(status) {
            Task { await resolver.invalidate(videoId) }
        }
        store.setState(videoId, .queued)
        changed()
    }
    #endif
}

#if os(watchOS)
/// Фоновая сессия часов (docs/PROMPT.md §5.6): одна на приложение, все куски трека ставятся сразу диапазонами по 1 МБ.
/// Система докачивает их без приложения и будит его; «Только по Wi‑Fi» — `allowsCellularAccess = false`.
public final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let identifier = "app.melogold.Melogold.watchkitapp.downloads"
    private weak var manager: DownloadManager?
    private var session: URLSession!
    /// Система будит приложение ради сессии — вызвать, когда все события получены.
    nonisolated(unsafe) static var completion: (() -> Void)?

    /// Фоновая задача сессии: дождаться, пока сессия отдаст все события (не дольше 25 с — бюджет watchOS мал).
    public static func waitForEvents() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { completion = { continuation.resume() } }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(25)) }
            await group.next()
            group.cancelAll()
        }
    }

    @MainActor
    init(manager: DownloadManager?) {
        self.manager = manager
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = !(manager?.wifiOnly ?? false)
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    @MainActor
    func enqueue(videoId: String, info: StreamInfo, length: Int64, missing: Range<Int64>?) {
        guard let url = URL(string: info.url), var start = missing?.lowerBound else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let running = Set(tasks.compactMap(\.taskDescription))
            while start < length {
                let end = min(start + Int64(DownloadManager.chunk), length)
                let description = "\(videoId)|\(start)|\(end)"
                if !running.contains(description) {
                    var request = URLRequest(url: url)
                    request.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
                    if let userAgent = info.userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
                    let task = self.session.downloadTask(with: request)
                    task.taskDescription = description
                    task.resume()
                }
                start = end
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parts = downloadTask.taskDescription?.split(separator: "|"), parts.count == 3,
              let offset = Int64(parts[1]) else { return }
        let videoId = String(parts[0])
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let data = try? Data(contentsOf: location) else {
            Task { @MainActor [weak self] in self?.manager?.backgroundFailed(videoId: videoId, status: status) }
            return
        }
        Task { @MainActor [weak self] in self?.manager?.backgroundChunk(videoId: videoId, offset: offset, data: data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let videoId = task.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        Log.warning("downloads", "\(videoId): фоновый кусок — \(error.localizedDescription)")
        Task { @MainActor [weak self] in self?.manager?.backgroundFailed(videoId: videoId, status: nil) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let completion = Self.completion
            Self.completion = nil
            completion?()
        }
    }
}
#endif
