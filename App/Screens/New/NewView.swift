import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// «Новое» (REWRITE §3.4): новые альбомы и синглы — карусель, «Все ›» — «Все новые релизы»; «Для вас» собирается
/// из истории прослушиваний (срез 4), до неё — карточка «Послушайте пару треков».
struct NewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.services.explore
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.fromCache, let page = store.page {
                        CachedDataChip(date: page.loadedAt).padding(.horizontal)
                    }
                    if let releases = store.page?.newReleases {
                        VStack(alignment: .leading, spacing: 10) {
                            ShelfHeader(title: Text("new.releases"), more: .newReleases)
                                .padding(.horizontal)
                            CardCarousel(items: releases.items)
                        }
                    } else if case .failed(let kind) = store.state {
                        ErrorStateView(kind: kind) { Task { await store.load(force: true) } }
                            .frame(minHeight: 240)
                    } else {
                        LoadingView().frame(height: 220)
                    }
                    forYou
                }
                .padding(.vertical, 8)
                .id(ScrollTop.id)
            }
            .onChange(of: model.scrollToTopRequest(for: .new)) {
                withAnimation { proxy.scrollTo(ScrollTop.id, anchor: .top) }
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(AppSection.new.title))
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
        #if os(macOS)
        .toolbar { RefreshButton { await store.load(force: true) } }
        #endif
    }

    /// «Для вас»: пока истории нет — карточка и «Что слушают сейчас» (REWRITE §3.4, состояние «нет истории»).
    private var forYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: Text("new.forYou"))
            VStack(alignment: .leading, spacing: 12) {
                Text("new.forYou.empty")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button("new.forYou.trends") { model.select(.trends) }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal)
    }
}
