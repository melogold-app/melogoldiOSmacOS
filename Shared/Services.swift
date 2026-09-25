import Foundation
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
import MelogoldPlayback
#if !os(watchOS)
import Network
#endif

/// Сервисы приложения: база, кэш музыки, InnerTube, адреса потока, плеер. Одни на процесс — и в приложении,
/// и на часах (docs/PROMPT.md §3: код правил, сети и данных — общий).
@MainActor
final class Services {
    let settings: AppSettings
    let paths: AppPaths?
    let database: AppDatabase?
    let innerTube: InnerTubeClient
    let catalog: YouTubeMusic
    let resolver: StreamResolver
    let cache: AudioCache?
    let player: PlayerEngine
    let searchHistory: SearchHistory?
    let network = NetworkStatus()

    init(settings: AppSettings, paths: AppPaths?) {
        self.settings = settings
        self.paths = paths
        var database: AppDatabase?
        if let paths {
            do {
                database = try AppDatabase.open(at: paths.database)
            } catch {
                Log.error("db", "База не открылась: \(error.localizedDescription)")
            }
        }
        self.database = database
        innerTube = InnerTubeClient()
        catalog = YouTubeMusic(client: innerTube)
        resolver = StreamResolver(catalog: catalog)
        #if os(watchOS)
        // Часы: кэша потока нет (на watchOS нет AVAssetResourceLoader) — без сети играет только скачанное.
        cache = nil
        #else
        if let database, let paths {
            let limitBox = CacheLimitBox(settings.cacheLimit)
            cache = AudioCache(database: database, directory: paths.audioCache, limit: { limitBox.value })
            self.cacheLimitBox = limitBox
        } else {
            cache = nil
        }
        #endif
        player = PlayerEngine(catalog: catalog, resolver: resolver, cache: cache)
        player.normalization = settings.normalization
        player.autoplayEnabled = settings.autoplay
        player.speed = Float(settings.speed)
        searchHistory = database.map { SearchHistory(database: $0) }
        network.onPathChange = { [resolver] in
            Task { await resolver.invalidateAll() }
        }
        start()
    }

    /// Лимит кэша читается из очереди загрузчика — отдельная потокобезопасная копия настройки.
    private var cacheLimitBox: CacheLimitBox?

    func cacheLimitChanged(_ bytes: Int64) {
        cacheLimitBox?.value = bytes
        cache?.trim()
    }

    private func start() {
        // visitorData нужен клиенту потока: получить заранее, чтобы первый трек стартовал быстрее.
        Task.detached(priority: .userInitiated) { [innerTube] in try? await innerTube.ensureVisitorData() }
        if let cache {
            Task.detached(priority: .utility) { cache.reconcile() }
        }
        guard let paths else { return }
        let file = paths.root.appendingPathComponent("stream-clients.json")
        if let saved = StreamClients.saved(at: file) {
            Task { await resolver.setClients(saved) }
        }
        let userAgent = "Melogold/\(AppVersion.current) (+https://github.com/melogold-app/melogoldiOSmacOS)"
        Task.detached(priority: .utility) { [resolver] in
            if let fresh = await StreamClients.refresh(saveTo: file, userAgent: userAgent) {
                await resolver.setClients(fresh)
            }
        }
    }
}

/// Потокобезопасная копия лимита кэша для загрузчика ресурсов.
nonisolated final class CacheLimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64

    init(_ value: Int64) { stored = value }

    var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Есть ли сеть и какая (задание 0003: без сети строки не из кэша приглушены). Смена сети сбрасывает адреса потока:
/// googlevideo привязывает их к адресу клиента (REWRITE §4.10.3). На часах доступность сети заранее не проверяется —
/// Apple прямо советует на неё не полагаться (docs/PROMPT.md §5.6).
@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOnline = true
    @ObservationIgnored var onPathChange: (() -> Void)?
    #if !os(watchOS)
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var lastInterfaces: [String] = []
    #endif

    init() {
        #if !os(watchOS)
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }
            Task { @MainActor in self?.update(online: online, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "app.melogold.network"))
        #endif
    }

    #if !os(watchOS)
    private func update(online: Bool, interfaces: [String]) {
        if online != isOnline { isOnline = online }
        if interfaces != lastInterfaces {
            if !lastInterfaces.isEmpty {
                Log.info("network", "Сеть сменилась — адреса потока сброшены")
                onPathChange?()
            }
            lastInterfaces = interfaces
        }
    }
    #endif
}
