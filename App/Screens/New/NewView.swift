import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// «Новое» (REWRITE §3.4): новые альбомы и синглы — карусель, «Все ›» — «Все новые релизы»; «Для вас» — подборка
/// по истории, лайкам и похожим.
struct NewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.services.explore
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Layout.shelfGap) {
                    if store.fromCache, let page = store.page {
                        CachedDataChip(date: page.loadedAt).shelfInset()
                    }
                    if let releases = store.page?.newReleases {
                        VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
                            ShelfHeader(title: Text("new.releases"), more: .newReleases)
                                .shelfInset()
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
                .padding(.top, Design.Space.xs)
                .padding(.bottom, Design.Space.l)
                .id(ScrollTop.id)
            }
            .onChange(of: model.scrollToTopRequest(for: .new)) {
                withAnimation { proxy.scrollTo(ScrollTop.id, anchor: .top) }
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(AppSection.new.title))
        .refreshable {
            await store.load(force: true)
            await model.services.forYou.load(library: model.library, hideExplicit: model.settings.hideExplicit, force: true)
        }
        .task { await store.load() }
        .task(id: model.library?.revision) {
            await model.services.forYou.load(library: model.library, hideExplicit: model.settings.hideExplicit)
        }
        #if os(macOS)
        .toolbar { RefreshButton { await store.load(force: true) } }
        #endif
    }

    /// «Для вас» (REWRITE §3.4): подборка по затравкам, «Слушать всё», «По мотивам: …»; похожие исполнители, альбомы,
    /// плейлисты. Пока истории нет — карточка «Послушайте пару треков» и «Что слушают сейчас».
    @ViewBuilder
    private var forYou: some View {
        let store = model.services.forYou
        if let picks = store.picks, !picks.tracks.isEmpty {
            VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("new.forYou").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text("new.forYou.basedOn \(picks.seeds.map(\.title).joined(separator: ", "))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if store.fromCache {
                            Text("new.forYou.updated \(picks.loadedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button { model.playAll(picks.tracks, shuffled: false) } label: {
                        Label("new.forYou.playAll", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .fixedSize()
                }
                .shelfInset()
                TrackGrid(tracks: picks.tracks, numbered: false) { track in
                    model.library?.library.setNotInterested(track, true)
                    store.remove(track.videoId)
                    model.toast = Toast(text: String(localized: "new.notInterested.done"), actionTitle: "common.undo") {
                        model.library?.library.setNotInterested(track, false)
                    }
                }
            }
            if !picks.artists.isEmpty {
                shelf("new.similarArtists", picks.artists.map(MusicItem.artist))
            }
            if !picks.albums.isEmpty {
                shelf("new.similarAlbums", picks.albums.map(MusicItem.album))
            }
            if !picks.playlists.isEmpty {
                shelf("new.playlistsForYou", picks.playlists.map(MusicItem.playlist))
            }
        } else if store.loading {
            VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
                ShelfHeader(title: Text("new.forYou")).shelfInset()
                LoadingView().frame(height: 160)
            }
        } else {
            VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
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
            .shelfInset()
        }
    }

    private func shelf(_ title: LocalizedStringResource, _ items: [MusicItem]) -> some View {
        VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
            ShelfHeader(title: Text(title)).shelfInset()
            CardCarousel(items: items)
        }
    }
}
