import Foundation
import MelogoldCore
import MelogoldInnerTube

/// «Обзор» YouTube Music для Трендов и Нового: один запрос на оба раздела (REWRITE §3.3). Копия лежит в `Caches`:
/// без сети показывается она с датой — «Данные от 14:02» (REWRITE §4.11.2). Свежей считается полчаса.
@MainActor
@Observable
final class ExploreStore {
    private(set) var page: ExplorePage?
    private(set) var state: Loadable<Void> = .idle
    /// На экране сохранённая копия: YouTube не ответил.
    private(set) var fromCache = false

    @ObservationIgnored private let catalog: YouTubeMusic
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var running: Task<Void, Never>?
    private static let freshFor: TimeInterval = 30 * 60

    init(catalog: YouTubeMusic, file: URL?) {
        self.catalog = catalog
        self.file = file
    }

    /// Загрузить, если данных нет или они устарели; `force` — «Обновить».
    func load(force: Bool = false) async {
        if let running {
            await running.value
            return
        }
        if !force, !fromCache, let page, Date().timeIntervalSince(page.loadedAt) < Self.freshFor { return }
        let task = Task { await fetch() }
        running = task
        await task.value
        running = nil
    }

    private func fetch() async {
        if page == nil, let cached = readCache() {
            page = cached
            fromCache = true
            state = .loaded(())
        }
        if page == nil { state = .loading }
        do {
            let fresh = try await catalog.explore()
            page = fresh
            fromCache = false
            state = .loaded(())
            writeCache(fresh)
        } catch {
            Log.warning("catalog", "Обзор не загрузился: \(error)")
            if page != nil {
                fromCache = true
                state = .loaded(())
            } else {
                state = .failed(.of(error))
            }
        }
    }

    private func readCache() -> ExplorePage? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ExplorePage.self, from: data)
    }

    private func writeCache(_ page: ExplorePage) {
        guard let file else { return }
        let data = try? JSONEncoder().encode(page)
        Task.detached(priority: .utility) {
            try? data?.write(to: file, options: .atomic)
        }
    }
}
