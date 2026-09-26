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
    /// Библиотека и загрузки (срез 4); без базы — нет.
    let library: LibraryStore?
    let downloads: DownloadManager?
    /// «Обзор» YouTube Music — общий для Трендов и Нового.
    let explore: ExploreStore
    /// «Для вас» в Новом.
    let forYou: ForYouStore
    /// Тексты: цепочка поиска (срез 6), кэш и свои тексты в базе, текст играющего трека.
    let lyricsFetcher: LyricsFetcher
    let lyricsStore: LyricsStore?
    let lyrics: LyricsModel

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
        let downloadStore = database.flatMap { database in paths.map { DownloadStore(database: database, directory: $0.downloads) } }
        let resolver = resolver
        let downloadManager = downloadStore.map { DownloadManager(store: $0, resolver: resolver) }
        downloads = downloadManager
        library = database.map { LibraryStore(library: Library(database: $0), downloads: downloadManager) }
        player = PlayerEngine(catalog: catalog, resolver: resolver, cache: cache, downloads: downloadStore)
        player.normalization = settings.normalization
        player.autoplayEnabled = settings.autoplay
        player.speed = Float(settings.speed)
        searchHistory = database.map { SearchHistory(database: $0) }
        explore = ExploreStore(catalog: catalog, file: paths?.caches.appendingPathComponent("explore.json"))
        forYou = ForYouStore(catalog: catalog, file: paths?.caches.appendingPathComponent("foryou.json"))
        let lrcLibAgent = "Melogold \(AppVersion.current) (https://github.com/melogold-app/melogoldiOSmacOS)"
        lyricsFetcher = LyricsFetcher(music: catalog, lrcLib: LrcLib(userAgent: lrcLibAgent))
        lyricsStore = database.map { LyricsStore(database: $0) }
        network.onPathChange = { [resolver, downloads] in
            Task { await resolver.invalidateAll() }
            downloads?.networkChanged()
        }
        lyrics = LyricsModel(fetcher: lyricsFetcher, store: lyricsStore, player: player)
        configureLibraryHooks()
        start()
    }

    /// История, скрытые треки и очередь между запусками (срез 4).
    private func configureLibraryHooks() {
        guard let library else { return }
        let settings = settings
        player.onPlayed = { track, playTimeMs in
            // «Не сохранять историю» — прослушивания не пишутся (REWRITE §3.2.4).
            guard !settings.historyPaused else { return }
            library.library.recordPlay(track, playTimeMs: playTimeMs)
        }
        player.isExcluded = { [weak library] track in
            guard let library else { return false }
            return library.hiddenIds.contains(track.videoId) || library.notInterestedIds.contains(track.videoId)
                || (settings.hideExplicit && track.explicit)
        }
        player.shouldSkip = { [weak library] track in
            (library?.hiddenIds.contains(track.videoId) ?? false) || (settings.hideExplicit && track.explicit)
        }
        downloads?.wifiOnly = settings.downloadsWifiOnly
        downloads?.network = { [network] in (network.isOnline, network.isCellular) }
        queueKeeper = QueueKeeper(player: player, library: library.library)
    }

    /// Сохраняет очередь и позицию; восстанавливает их при запуске без автостарта.
    private(set) var queueKeeper: QueueKeeper?

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
        downloads?.start()
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
    /// Сотовая или дорогая сеть: «Только по Wi‑Fi» у загрузок.
    private(set) var isCellular = false
    @ObservationIgnored var onPathChange: (() -> Void)?
    #if !os(watchOS)
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var lastInterfaces: [String] = []
    #endif

    init() {
        #if !os(watchOS)
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellular = path.usesInterfaceType(.cellular) || path.isExpensive
            let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }
            Task { @MainActor in self?.update(online: online, cellular: cellular, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "app.melogold.network"))
        #endif
    }

    #if !os(watchOS)
    private func update(online: Bool, cellular: Bool, interfaces: [String]) {
        if online != isOnline { isOnline = online }
        if cellular != isCellular { isCellular = cellular }
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

/// Очередь между запусками (docs/PROMPT.md §4 «Очередь»): после перезапуска очередь и позиция восстанавливаются,
/// без автостарта. Снимок пишется в `app_state` раз в 5 секунд, если очередь или позиция изменились, и при уходе в фон.
@MainActor
final class QueueKeeper {
    private let player: PlayerEngine
    private let library: Library
    private var saved: PlayerEngine.Snapshot?
    private var timer: Task<Void, Never>?
    static let key = "queue"

    init(player: PlayerEngine, library: Library) {
        self.player = player
        self.library = library
        restore()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.save()
            }
        }
    }

    private func restore() {
        guard let text = library.state(Self.key), let data = text.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(PlayerEngine.Snapshot.self, from: data) else { return }
        player.restore(snapshot, play: false)
        saved = snapshot
        Log.info("player", "Очередь восстановлена: \(snapshot.items.count) треков")
    }

    /// Записать снимок, если он изменился (позиция — с точностью до секунды).
    func save() {
        var snapshot = player.snapshot()
        if let position = snapshot?.position { snapshot?.position = position.rounded() }
        guard snapshot != saved else { return }
        saved = snapshot
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            library.setState(Self.key, String(data: data, encoding: .utf8))
        } else {
            library.setState(Self.key, nil)
        }
    }
}
