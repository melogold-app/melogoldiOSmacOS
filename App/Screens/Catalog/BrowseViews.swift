import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Настроение или жанр (REWRITE §3.9): карусели плейлистов и альбомов в порядке ответа, без вкладок.
struct MoodView: View {
    @Environment(AppModel.self) private var model
    let mood: MoodItem
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        let catalog = model.services.catalog
        let mood = mood
        ShelvesPage(title: mood.title, loader: loader) {
            try await catalog.browseShelves(mood.browseId, params: mood.params)
        }
    }
}

/// Полный список полки («Все ›» у альбомов и синглов исполнителя): сетка карточек.
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    let title: String?
    let browseId: String
    let params: String?
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        let catalog = model.services.catalog
        let (browseId, params) = (browseId, params)
        GridPage(title: title ?? "", loader: loader) {
            try await catalog.browseShelves(browseId, params: params)
        }
    }
}

/// «Все новые релизы»: сетка альбомов с меткой «Альбом», «Сингл» или «EP» и годом.
struct NewReleasesView: View {
    @Environment(AppModel.self) private var model
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        let catalog = model.services.catalog
        GridPage(title: String(localized: "new.allReleases"), loader: loader) {
            try await catalog.newReleases()
        }
    }
}

/// «Все настроения»: группы по заголовкам API («Настроения и события», «Жанры»), плитки с полоской цвета.
struct MoodsView: View {
    @Environment(AppModel.self) private var model
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        Group {
            if let shelves = loader.value {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(shelves) { shelf in
                            VStack(alignment: .leading, spacing: 10) {
                                ShelfHeader(title: Text(verbatim: shelf.title ?? ""))
                                MoodGrid(moods: shelf.items.compactMap(\.mood))
                            }
                        }
                    }
                    .padding()
                }
            } else {
                PageStateView(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text("trends.allMoods"))
        .inlineTitle()
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        await loader.load(force: force) { try await catalog.moods() }
    }
}

/// Страница из полок-каруселей.
private struct ShelvesPage: View {
    let title: String
    let loader: PageLoader<[Shelf]>
    let fetch: () async throws -> [Shelf]

    var body: some View {
        Group {
            if let shelves = loader.value {
                if shelves.isEmpty {
                    ContentUnavailableView { Label("catalog.empty", systemImage: "music.note.list") }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(shelves) { shelf in
                                VStack(alignment: .leading, spacing: 10) {
                                    ShelfHeader(title: Text(verbatim: shelf.title ?? ""), more: Route.more(shelf))
                                        .padding(.horizontal)
                                    CardCarousel(items: shelf.items)
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                }
            } else {
                PageStateView(state: loader.state) { Task { await loader.load(force: true, fetch) } }
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(verbatim: title))
        .inlineTitle()
        .task { await loader.load(fetch) }
    }
}

/// Страница-сетка карточек: все элементы всех полок подряд, без повторов.
private struct GridPage: View {
    let title: String
    let loader: PageLoader<[Shelf]>
    let fetch: () async throws -> [Shelf]

    var body: some View {
        Group {
            if let shelves = loader.value {
                let items = distinctItems(shelves.flatMap(\.items))
                if items.isEmpty {
                    ContentUnavailableView { Label("catalog.empty", systemImage: "square.grid.2x2") }
                } else {
                    CardGrid(items: items)
                }
            } else {
                PageStateView(state: loader.state) { Task { await loader.load(force: true, fetch) } }
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(verbatim: title))
        .inlineTitle()
        .task { await loader.load(fetch) }
    }
}

/// Сетка карточек по ширине окна.
struct CardGrid: View {
    @Environment(\.cardMetrics) private var metrics
    let items: [MusicItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.square, maximum: metrics.square + 40), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    ItemCard(item: item)
                }
            }
            .padding(metrics.margin)
        }
    }
}

extension View {
    /// Вложенные экраны — с обычным заголовком, корни разделов — с большим (docs/PROMPT.md §5.2).
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
