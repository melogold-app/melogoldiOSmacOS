import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// «Тренды» (REWRITE §3.3): «В тренде» — сетка из 4 рядов вбок, «Весь список ›» — плейлист чарта; «Настроения и
/// жанры» — плитки в порядке API, «Все ›» — «Все настроения». Данные — один запрос «Обзора» на Тренды и Новое.
struct TrendsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.services.explore
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.fromCache, let page = store.page {
                        CachedDataChip(date: page.loadedAt).padding(.horizontal)
                    }
                    if let page = store.page {
                        content(page)
                    }
                }
                .padding(.vertical, 8)
                .id(ScrollTop.id)
            }
            .overlay { stateOverlay(store) }
            .onChange(of: model.scrollToTopRequest(for: .trends)) {
                withAnimation { proxy.scrollTo(ScrollTop.id, anchor: .top) }
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(AppSection.trends.title))
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
        #if os(macOS)
        .toolbar { RefreshButton { await store.load(force: true) } }
        #endif
    }

    @ViewBuilder
    private func content(_ page: ExplorePage) -> some View {
        if let trending = page.trending {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: Text("trends.trending"), more: page.trendingPlaylistId.map(Route.playlist),
                            moreTitle: "trends.fullList")
                    .padding(.horizontal)
                TrackGrid(tracks: trending.tracks)
            }
        }
        if let moods = page.moods {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: Text("trends.moods"), more: .moods)
                MoodGrid(moods: moods.items.compactMap(\.mood))
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func stateOverlay(_ store: ExploreStore) -> some View {
        if store.page == nil {
            switch store.state {
            case .failed(let kind):
                ErrorStateView(kind: kind) { Task { await store.load(force: true) } }
            default:
                LoadingView()
            }
        }
    }
}

/// Якорь «наверх» для повторного нажатия на раздел.
enum ScrollTop {
    static let id = "scroll-top"
}

/// Mac: «Обновить» в панели инструментов (жеста «потянуть» там нет), ⌘R.
struct RefreshButton: ToolbarContent {
    let action: () async -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await action() }
            } label: {
                Label("common.refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
