import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldInnerTube

/// Состояние загрузки части экрана (REWRITE §4.11.3).
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(YouTubeError.Kind)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

/// Поиск (REWRITE §3.1): корень с недавними запросами, ввод с подсказками, выдача «Всё · Музыка · YouTube».
/// Живёт в модели окна: выбор области и фильтра переживает переход в детальный экран и обратно.
@MainActor
@Observable
final class SearchModel {
    enum Scope: String, CaseIterable, Identifiable {
        case all, music, youtube
        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .all: "search.scope.all"
            case .music: "search.scope.music"
            case .youtube: "search.scope.youtube"
            }
        }
    }

    /// Секция «Всё»: YouTube Music (лучший результат и до 4 строк) и YouTube (до 4 видео без повторов YTM).
    struct AllResults {
        var top: MusicItem?
        var music: Loadable<[MusicItem]> = .loading
        var videos: Loadable<[Track]> = .loading
    }

    /// Бесконечный список с продолжениями.
    struct Paged {
        var items: [MusicItem] = []
        var continuation: String?
        var state: Loadable<Void> = .idle
        var loadingMore = false
    }

    var scope: Scope = .all {
        didSet { if oldValue != scope { loadScope() } }
    }
    var musicFilter: MusicSearchFilter = .songs {
        didSet { if oldValue != musicFilter { music = Paged(); loadScope() } }
    }
    var webFilter: WebSearchFilter = .videos {
        didSet { if oldValue != webFilter { web = Paged(); loadScope() } }
    }

    private(set) var submitted: String?
    private(set) var suggestions: [String] = []
    private(set) var recent: [String] = []
    private(set) var all = AllResults()
    private(set) var music = Paged()
    private(set) var web = Paged()

    @ObservationIgnored private let catalog: YouTubeMusic
    @ObservationIgnored private let history: SearchHistory?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var loadTasks: [Task<Void, Never>] = []

    init(catalog: YouTubeMusic, history: SearchHistory?, settings: AppSettings) {
        self.catalog = catalog
        self.history = history
        self.settings = settings
        refreshRecent()
    }

    func refreshRecent() {
        recent = settings.historyPaused ? [] : history?.recent() ?? []
    }

    /// Ввод изменился: подсказки через 250 мс; пустое поле — снова корень.
    func queryChanged(_ text: String) {
        suggestTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            submitted = nil
            suggestions = []
            refreshRecent()
            return
        }
        if query == submitted { return }
        suggestTask = Task { [catalog] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = (try? await catalog.suggestions(query)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = found
        }
    }

    /// Enter или подсказка: выдача и запись в «Недавние запросы» (если история не выключена).
    func submit(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        suggestTask?.cancel()
        suggestions = []
        if !settings.historyPaused { history?.add(query) }
        submitted = query
        // Новый запрос всегда открывается на «Всё».
        scope = .all
        all = AllResults()
        music = Paged()
        web = Paged()
        loadScope()
    }

    func removeRecent(_ query: String) {
        history?.remove(query)
        refreshRecent()
    }

    func clearRecent() {
        history?.clear()
        refreshRecent()
    }

    func retry() {
        switch scope {
        case .all: all = AllResults()
        case .music: music = Paged()
        case .youtube: web = Paged()
        }
        loadScope()
    }

    // MARK: - Загрузка

    private func loadScope() {
        guard let query = submitted else { return }
        switch scope {
        case .all:
            if case .loaded = all.music, case .loaded = all.videos { return }
            loadAll(query)
        case .music:
            if music.state.isIdle { loadMusic(query) }
        case .youtube:
            if web.state.isIdle { loadWeb(query) }
        }
    }

    /// Два параллельных запроса, у каждого свои ошибки (REWRITE §4.8.5).
    private func loadAll(_ query: String) {
        all = AllResults()
        loadTasks.append(Task { [catalog] in
            do {
                let summary = try await catalog.searchSummary(query)
                guard submitted == query else { return }
                all.top = summary.topResult
                let rest = summary.items.filter { $0.id != summary.topResult?.id }
                all.music = .loaded(Array(rest.prefix(4)))
                dedupeVideos()
            } catch {
                guard submitted == query else { return }
                all.music = .failed(.of(error))
            }
        })
        loadTasks.append(Task { [catalog] in
            do {
                let page = try await catalog.searchWeb(query, filter: .videos)
                guard submitted == query else { return }
                all.videos = .loaded(page.items.compactMap(\.track))
                dedupeVideos()
            } catch {
                guard submitted == query else { return }
                all.videos = .failed(.of(error))
            }
        })
    }

    /// Видео, которые уже есть в секции YouTube Music, в секции YouTube не повторяются.
    private func dedupeVideos() {
        guard case .loaded(let videos) = all.videos else { return }
        var known = Set<String>()
        if let top = all.top?.track { known.insert(top.videoId) }
        for item in all.music.value ?? [] { if let track = item.track { known.insert(track.videoId) } }
        all.videos = .loaded(Array(videos.filter { !known.contains($0.videoId) }.prefix(4)))
    }

    private func loadMusic(_ query: String) {
        music.state = .loading
        let filter = musicFilter
        loadTasks.append(Task { [catalog] in
            do {
                let page = try await catalog.search(query, filter: filter)
                guard submitted == query, musicFilter == filter else { return }
                music = Paged(items: page.items, continuation: page.continuation, state: .loaded(()))
            } catch {
                guard submitted == query else { return }
                music.state = .failed(.of(error))
            }
        })
    }

    private func loadWeb(_ query: String) {
        web.state = .loading
        let filter = webFilter
        loadTasks.append(Task { [catalog] in
            do {
                let page = try await catalog.searchWeb(query, filter: filter)
                guard submitted == query, webFilter == filter else { return }
                web = Paged(items: page.items, continuation: page.continuation, state: .loaded(()))
            } catch {
                guard submitted == query else { return }
                web.state = .failed(.of(error))
            }
        })
    }

    /// Строка показалась у конца списка — догрузить продолжение.
    func loadMoreIfNeeded(after item: MusicItem) {
        switch scope {
        case .music:
            guard !music.loadingMore, let token = music.continuation, music.items.suffix(5).contains(item) else { return }
            music.loadingMore = true
            Task { [catalog] in
                let page = try? await catalog.searchContinuation(token)
                music.loadingMore = false
                guard let page else { return }
                let known = Set(music.items.map(\.id))
                music.items += page.items.filter { !known.contains($0.id) }
                music.continuation = page.continuation == token ? nil : page.continuation
            }
        case .youtube:
            guard !web.loadingMore, let token = web.continuation, web.items.suffix(5).contains(item) else { return }
            web.loadingMore = true
            Task { [catalog] in
                let page = try? await catalog.searchWebContinuation(token)
                web.loadingMore = false
                guard let page else { return }
                let known = Set(web.items.map(\.id))
                web.items += page.items.filter { !known.contains($0.id) }
                web.continuation = page.continuation == token ? nil : page.continuation
            }
        case .all:
            break
        }
    }
}

extension Loadable {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

extension MusicSearchFilter {
    /// Чипы «Музыки»: Песни · Альбомы · Исполнители · Клипы · Плейлисты.
    static let shown: [MusicSearchFilter] = [.songs, .albums, .artists, .videos, .featuredPlaylists]

    var title: LocalizedStringResource {
        switch self {
        case .songs: "search.filter.songs"
        case .albums: "search.filter.albums"
        case .artists: "search.filter.artists"
        case .videos: "search.filter.clips"
        case .featuredPlaylists, .communityPlaylists: "search.filter.playlists"
        }
    }
}

extension WebSearchFilter {
    /// Чипы «YouTube»: Видео · Каналы · Трансляции · Плейлисты.
    static let shown: [WebSearchFilter] = [.videos, .channels, .live, .playlists]

    var title: LocalizedStringResource {
        switch self {
        case .videos: "search.filter.videos"
        case .channels: "search.filter.channels"
        case .live: "search.filter.live"
        case .playlists: "search.filter.playlists"
        }
    }
}
