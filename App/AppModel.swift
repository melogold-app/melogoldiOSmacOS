import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldPlayback
import MelogoldServer

/// Состояние окна: раздел, стеки разделов, сообщения. Настройки — в `AppSettings`.
@MainActor
@Observable
final class AppModel {
    /// Модель окна для Dock, CarPlay и Siri (одно приложение — одна модель).
    @ObservationIgnored static weak var current: AppModel?

    let services: Services
    let search: SearchModel
    /// Аккаунт на сервере Melogold: вход, токены, устройства (срез 5).
    let account: Account
    /// Синк библиотеки, истории и своих текстов с аккаунтом (срез 5). «Убрать из истории» и «Очистить историю»
    /// библиотеки уходят его очередью на все устройства аккаунта.
    let sync: LibrarySync
    @ObservationIgnored private var lifecycle: [any NSObjectProtocol] = []
    @ObservationIgnored private var wasOnline = true
    var settings: AppSettings { services.settings }
    var paths: AppPaths? { services.paths }

    /// Треки, лежащие в кэше целиком: метка «Есть без сети» и доступность без сети (задание 0003).
    private(set) var cachedIds: Set<String> = []

    /// Текущий раздел. Запоминается в `shell.lastTab`.
    var section: AppSection {
        didSet {
            if oldValue != section { settings.lastTab = section }
        }
    }

    /// Стек каждого раздела: при переключении разделов стеки сохраняются.
    var routes: [AppSection: [Route]] = [:]

    /// Растёт при повторном нажатии на активный раздел в корне — экран прокручивается наверх.
    private(set) var scrollToTopRequests: [AppSection: Int] = [:]

    /// Растёт, когда нужно поставить курсор в поле Поиска (⌘F, повторное нажатие на «Поиск»).
    private(set) var searchFocusRequest = 0

    /// Текст в поле Поиска. На iPhone поле живёт в панели вкладок (`Tab(role: .search)`), на iPad с боковой
    /// панелью и на Mac — в разделе «Поиск»; запрос общий.
    var searchQuery = ""

    /// Сообщение поверх окна (разбор ссылки и т. п.).
    var notice: Notice?

    /// Плашка над мини-плеером: «Играет следующим: …», «Эта ссылка пока не поддерживается».
    var toast: Toast?

    /// Отложенное разрушающее действие (5 с, «Отменить», docs/PROMPT.md §5.10).
    var pending: PendingChange?
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    /// `UndoManager` окна: ⌘Z и встряхивание отменяют отложенное действие.
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Лист «Добавить в плейлист…» для этих треков.
    var playlistPicker: PlaylistPickerRequest?

    /// «Сохранить файлом» на iPhone и iPad: готовый файл для системного окна сохранения.
    var exportedFile: ExportedAudio?

    /// «Переименовать» свой плейлист.
    var renameRequest: LibraryPlaylist?

    /// Импорт копии и «Сохранить копию» (задание 0006): окно выбора файла, ход и итог импорта, готовая копия.
    var importPicker = false
    var importState: LibraryImportState?
    var backupDocument: BackupDocument?

    /// Открыт «Сейчас играет».
    var showNowPlaying = false

    /// В «Сейчас играет» показан текст (срез 6); лист «Найти текст» и редактор текста.
    var lyricsVisible = false
    var lyricsSearch = false
    var lyricsEditor = false

    /// Очередь: на iPhone — лист, на iPad и Mac — колонка справа (срез 7).
    var queueVisible = false

    /// Курсор в поле ввода: пробел вводит пробел, а не ставит паузу (Mac, docs/PROMPT.md §5.4).
    var textInputActive = false

    struct Notice: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        let message: LocalizedStringResource?
    }

    init(services: Services) {
        self.services = services
        self.search = SearchModel(catalog: services.catalog, history: services.searchHistory, settings: services.settings)
        self.account = Account(settings: services.settings)
        self.sync = LibrarySync(account: account, library: services.library?.library)
        self.section = services.settings.lastTab
        refreshCached()
        sync.start()
        // Цепочка поиска текста спрашивает сервер, если провайдеры не нашли синхронный (задание 0001 §3.5).
        let lyricsSync = sync
        services.lyricsFetcher.community = { videoId in try await lyricsSync.serverLyrics(videoId) }
        lifecycle = SyncLifecycle.observe(sync)
        wasOnline = services.network.isOnline
        observeNetwork()
    }

    /// Сеть вернулась — синк и живой поток сразу, а не после паузы повтора (DESIGN §3.13.6 «появление сети»).
    /// Смотрит `isOnline`, а не смену интерфейсов: та молчит, когда до этого сети не было вовсе.
    private func observeNetwork() {
        withObservationTracking {
            _ = services.network.isOnline
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let online = self.services.network.isOnline
                if online && !self.wasOnline { self.sync.networkReturned() }
                self.wasOnline = online
                self.observeNetwork()
            }
        }
    }

    func refreshCached() {
        guard let cache = services.cache else { return }
        Task.detached(priority: .utility) {
            let ids = Set(cache.completeVideoIds())
            await MainActor.run { self.cachedIds = ids }
        }
    }

    /// Одиночный трек из выдачи: трек и радио (REWRITE §2.3). Без сети трек не из кэша не играет — «Нет сети».
    func play(single track: Track) {
        guard canPlay(track) else { return }
        replaceQueue { services.player.playSingle(track) }
    }

    /// Трек из списка: очередь — весь список с этого трека.
    func play(_ tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index), canPlay(tracks[index]) else { return }
        replaceQueue { services.player.play(tracks: tracks, startAt: index) }
    }

    func canPlay(_ track: Track) -> Bool {
        if services.network.isOnline || cachedIds.contains(track.videoId) || services.library?.isDownloaded(track.videoId) == true {
            return true
        }
        notice = Notice(title: "notice.offline", message: nil)
        return false
    }

    func path(for section: AppSection) -> Binding<[Route]> {
        Binding(
            get: { self.routes[section] ?? [] },
            set: { self.routes[section] = $0 }
        )
    }

    /// Нажатие на раздел. Повторное нажатие на активный: во вложенном экране — к корню, в корне — наверх;
    /// в корне Поиска — ещё и курсор в поле (REWRITE §2.3).
    func select(_ section: AppSection) {
        guard section == self.section else {
            self.section = section
            return
        }
        if let stack = routes[section], !stack.isEmpty {
            Log.info("nav", "Повторное нажатие на раздел — к корню")
            routes[section] = []
        } else {
            scrollToTopRequests[section, default: 0] += 1
            if section == .search { searchFocusRequest += 1 }
        }
    }

    func scrollToTopRequest(for section: AppSection) -> Int {
        scrollToTopRequests[section, default: 0]
    }

    /// ⌘F: раздел «Поиск» и курсор в поле.
    func focusSearch() {
        section = .search
        routes[.search] = []
        searchFocusRequest += 1
    }

    /// Шаг «Назад» в стеке текущего раздела (Esc и ⌘[ на Mac). `false` — стек уже пуст.
    @discardableResult
    func goBack() -> Bool {
        guard var stack = routes[section], !stack.isEmpty else { return false }
        stack.removeLast()
        routes[section] = stack
        return true
    }

    func open(_ route: Route, in section: AppSection) {
        self.section = section
        routes[section, default: []].append(route)
    }

    /// Ссылка, которую отдала система (`onOpenURL`): `melogold://` (API §7.2). Ссылки YouTube система отдаёт
    /// редко (перетаскивание, «Открыть с помощью» на Mac) — они идут в `openLink`, как вставка в Поиске.
    func handle(url: URL) {
        Log.info("links", "Открыта ссылка \(url.scheme ?? "?")://\(url.host() ?? "")")
        if url.scheme?.lowercased() != "melogold" {
            openLink(url.absoluteString)
            return
        }
        switch MelogoldLink.parse(url) {
        case .success(.server(let address, _, let serverId)):
            section = .settings
            routes[.settings] = [.server(prefill: address, serverId: serverId)]
        case .success(.link(.request, _, _, _)):
            notice = Notice(title: "link.request.title", message: "link.request.message")
        case .success(.link(.invite, _, _, _)):
            notice = Notice(title: "link.invite.title", message: "link.invite.message")
        case .failure(.badServer(let error)):
            notice = Notice(title: "link.invalid", message: ServerAddressText.message(for: error))
        case .failure:
            notice = Notice(title: "link.invalid", message: nil)
        }
    }
}

/// Тексты отказов `ServerAddressPolicy` (GLOSSARY §4.5 «Сервер»).
enum ServerAddressText {
    static func message(for error: ServerAddressError) -> LocalizedStringResource {
        switch error {
        case .empty: "server.error.empty"
        case .malformed: "server.error.malformed"
        case .unsupportedScheme: "server.error.scheme"
        case .credentialsOrParams: "server.error.credentials"
        case .httpsRequired: "server.error.https"
        }
    }
}

/// Выход на передний план — синхронизация и живой поток, уход в фон — неотправленные правки сразу (REWRITE §4.12a).
@MainActor
enum SyncLifecycle {
    static func observe(_ sync: LibrarySync) -> [any NSObjectProtocol] {
        #if os(macOS)
        let active = NSApplication.didBecomeActiveNotification
        let background = NSApplication.didResignActiveNotification
        #else
        let active = UIApplication.didBecomeActiveNotification
        let background = UIApplication.didEnterBackgroundNotification
        #endif
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: active, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sync.appDidBecomeActive() }
            },
            center.addObserver(forName: background, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sync.flush() }
            },
        ]
    }
}
