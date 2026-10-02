import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Исполнитель или канал (REWRITE §3.7): что показывать, решает `YouTubeMusic.artist` — страница исполнителя, если у
/// YouTube Music есть музыкальные секции, иначе канал YouTube. «Подписаться» и «В вашей библиотеке» — со срезом 4.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let browseId: String
    @State private var page = ArtistPageModel()
    @State private var showInfo = false
    /// Шапка ушла под панель: имя — в заголовок, у панели — системный фон (до того фото под прозрачной панелью и имя на нём).
    @State private var pastHero = false

    var body: some View {
        Group {
            if let details = page.details {
                if details.isChannel {
                    channel(details)
                } else {
                    artist(details)
                }
            } else {
                PageStateView(state: page.state) { Task { await page.load(browseId, catalog: model.services.catalog, force: true) } }
            }
        }
        .task { await page.load(browseId, catalog: model.services.catalog) }
    }

    // MARK: - Исполнитель: одна прокрутка, как в «Музыке» (REWRITE §3.7.1, задание 0024)

    /// Страница — обычная прокрутка (`ScrollView`), а не список: в списке Mac полки обложек внутри строк перехватывали жест
    /// трекпада и пересчитывали высоты строк на ходу — прокрутка останавливалась рывком и прыгала (2026-10-02). Шапка —
    /// фото во всю ширину до верхнего края, имя крупно, ⓘ ▶ ☆; дальше полки, как в «Трендах».
    private func artist(_ details: ArtistDetails) -> some View {
        let liked = model.library?.library.likedTracks(ofArtist: details.browseId, name: details.name) ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: Design.Layout.shelfGap) {
                ArtistHero(details: details, onInfo: { showInfo = true }, onPlay: { play(details) })
                if !liked.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
                        ShelfHeader(title: Text("artist.inLibrary"), more: liked.count > 8 ? .favorites : nil,
                                    moreTitle: "library.seeAllCount \(liked.count)")
                            .shelfInset()
                        TrackGrid(tracks: Array(liked.prefix(12)), numbered: false, rows: min(4, liked.count))
                    }
                }
                ForEach(Array(details.shelves.enumerated()), id: \.offset) { _, shelf in
                    VStack(alignment: .leading, spacing: Design.Layout.headerGap) {
                        if ArtistPageModel.isSongs(shelf) {
                            ShelfHeader(title: Text(verbatim: shelf.title ?? ""), more: songsRoute(details, shelf))
                                .shelfInset()
                            TrackGrid(tracks: shelf.tracks, rows: min(4, max(1, shelf.tracks.count)))
                        } else {
                            ShelfHeader(title: Text(verbatim: shelf.title ?? ""), more: Route.more(shelf))
                                .shelfInset()
                            CardCarousel(items: shelf.items)
                        }
                    }
                }
                if let description = details.description, !description.isEmpty {
                    Button { showInfo = true } label: {
                        VStack(alignment: .leading, spacing: Design.Space.xs) {
                            Text("artist.about").font(.title3.weight(.bold)).foregroundStyle(.primary)
                            Text(verbatim: description)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                            Text("common.more").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shelfInset()
                }
            }
            .padding(.bottom, Design.Space.xl)
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > ArtistHero.collapseOffset
        } action: { _, past in
            pastHero = past
        }
        #if os(macOS)
        // Фото — до самого верха окна, панель инструментов лежит на нём прозрачной (как в «Музыке»)
        .toolbarBackgroundVisibility(pastHero ? .automatic : .hidden, for: .windowToolbar)
        #endif
        .modifier(CardMetricsReader())
        .navigationTitle(pastHero ? Text(verbatim: details.name) : Text(verbatim: ""))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showInfo) {
            ArtistInfoSheet(details: details)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    if let seed = page.popular.first {
                        Button { radio(details, seed: seed) } label: {
                            Label("artist.radio", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    Button { page.shuffleSongs(model: model) } label: {
                        Label("collection.shuffle", systemImage: "shuffle")
                    }
                    ShareLink(item: ShareLinks.artist(details.browseId, isChannel: false), subject: Text(verbatim: details.name),
                              message: Text(verbatim: details.name)) {
                        Label("menu.share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
            }
        }
    }

    /// ▶ в шапке: популярные песни по порядку (как «Слушать» у альбома).
    private func play(_ details: ArtistDetails) {
        let songs = page.popular
        if songs.isEmpty, let seed = details.shelves.flatMap(\.tracks).first {
            radio(details, seed: seed)
        } else {
            model.playAll(songs, shuffled: false)
        }
    }

    /// «Все ›» у «Популярного» — плейлист песен исполнителя, если YouTube Music его дал.
    private func songsRoute(_ details: ArtistDetails, _ shelf: Shelf) -> Route? {
        if let playlistId = details.songsPlaylistId { return .playlist(playlistId) }
        return Route.more(shelf)
    }

    private func radio(_ details: ArtistDetails, seed: Track) {
        if let playlistId = details.radioPlaylistId {
            model.playRadio(playlistId: playlistId, seed: seed)
        } else {
            model.startRadio(seed)
        }
    }

    // MARK: - Канал YouTube (REWRITE §3.7.2)

    private func channel(_ details: ArtistDetails) -> some View {
        DetailPage(title: details.name, twoColumns: false) {
            CollectionHeader(artworkURL: details.thumbnailUrl, style: .avatar, title: details.name) {
                VStack(spacing: 8) {
                    if let subscribers = details.subscribersText {
                        Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                    }
                    SubscribeButton(artist: ArtistItem(browseId: details.browseId, name: details.name, thumbnailUrl: details.thumbnailUrl,
                                                       isChannel: true))
                }
            } actions: {
                if !page.videos.isEmpty {
                    ShuffleButton(title: "channel.shuffleVideos") { model.playAll(page.videos, shuffled: true) }
                }
            }
        } rows: {
            if page.videos.isEmpty {
                ContentUnavailableView { Label("channel.noVideos", systemImage: "play.rectangle") }
                    .listRowSeparator(.hidden)
            } else {
                ShelfHeader(title: Text("channel.videos"))
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(page.videos.enumerated()), id: \.element.id) { index, video in
                TrackListRow(track: video, wide: true, target: .list(page.videos, index))
                    .tag(RowID.make("v", video.videoId))
                    .onAppear { if index >= page.videos.count - 6 { page.loadMoreVideos(catalog: model.services.catalog) } }
            }
            if page.loadingMore {
                ProgressRow()
            }
        } target: { id in
            guard let (_, key) = RowID.split(id), let index = page.videos.firstIndex(where: { $0.videoId == key }) else { return nil }
            return .list(page.videos, index)
        }
        .toolbar {
            ToolbarItem {
                ShareLink(item: ShareLinks.artist(details.browseId, isChannel: true), subject: Text(verbatim: details.name),
                          message: Text(verbatim: details.name)) {
                    Label("menu.share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

/// Данные страницы исполнителя или канала; у канала — видео с продолжениями.
@MainActor
@Observable
final class ArtistPageModel {
    private(set) var details: ArtistDetails?
    private(set) var state: Loadable<Void> = .idle
    private(set) var videos: [Track] = []
    private(set) var loadingMore = false
    @ObservationIgnored private var continuation: String?

    /// Полка «Популярное»: треки, не клипы.
    static func isSongs(_ shelf: Shelf) -> Bool {
        !shelf.items.isEmpty && shelf.items.allSatisfy { $0.track.map { !$0.isVideo } ?? false }
    }

    var popular: [Track] {
        details?.shelves.first(where: Self.isSongs)?.tracks ?? []
    }

    func load(_ browseId: String, catalog: YouTubeMusic, force: Bool = false) async {
        if details != nil, !force { return }
        state = .loading
        do {
            let loaded = try await catalog.artist(browseId)
            details = loaded
            if loaded.isChannel {
                videos = loaded.shelves.first?.tracks ?? []
                continuation = loaded.continuation
            }
            state = .loaded(())
        } catch {
            Log.warning("catalog", "Исполнитель не загрузился: \(error)")
            state = .failed(.of(error))
        }
    }

    func loadMoreVideos(catalog: YouTubeMusic) {
        guard !loadingMore, let token = continuation else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let next = try? await catalog.channelContinuation(token) else { return }
            let name = details?.name ?? ""
            let known = Set(videos.map(\.videoId))
            videos += next.items.compactMap(\.track).filter { !known.contains($0.videoId) }.map { video in
                var copy = video
                copy.artists = [ArtistRef(id: details?.browseId, name: name)]
                copy.artistsText = name
                return copy
            }
            continuation = next.continuation == token ? nil : next.continuation
        }
    }

    /// «Перемешать»: песни исполнителя (плейлист «Все треки», первая страница), иначе «Популярное».
    func shuffleSongs(model: AppModel) {
        guard let details else { return }
        guard let playlistId = details.songsPlaylistId else {
            model.playAll(popular, shuffled: true)
            return
        }
        Task {
            let songs = (try? await model.services.catalog.playlist(playlistId).tracks) ?? []
            model.playAll(songs.isEmpty ? popular : songs, shuffled: true)
        }
    }
}

/// «⊕ Подписаться / ✓ Вы подписаны» — закладка исполнителя или канала (REWRITE §3.7).
struct SubscribeButton: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistItem

    var body: some View {
        let subscribed = model.isArtistSaved(artist.browseId)
        Button {
            model.setArtistSaved(artist, !subscribed)
        } label: {
            Label(subscribed ? "artist.subscribed" : "artist.subscribe", systemImage: subscribed ? "checkmark" : "plus")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
}

/// «+ / ✓» в панели навигации: подписаться на исполнителя или отписаться (у альбома так же — «Сохранить»).
struct SubscribeToolbarButton: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistItem

    var body: some View {
        let subscribed = model.isArtistSaved(artist.browseId)
        Button {
            model.setArtistSaved(artist, !subscribed)
        } label: {
            Label(subscribed ? "artist.subscribed" : "artist.subscribe", systemImage: subscribed ? "checkmark" : "plus")
        }
    }
}

/// Шапка исполнителя, как в «Музыке»: фото во всю ширину до верхнего края, снизу затемнение, на нём имя крупно и кнопки
/// ⓘ (лист «Об исполнителе»), ▶ (популярные песни) и ☆ (подписаться).
private struct ArtistHero: View {
    @Environment(AppModel.self) private var model
    let details: ArtistDetails
    let onInfo: () -> Void
    let onPlay: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let subscribed = model.isArtistSaved(details.browseId)
            ZStack(alignment: .bottom) {
                // Шапка YouTube Music — широкий баннер: растягивается по большей стороне и обрезается по центру, без полос
                let height = proxy.size.height
                ArtworkView(url: details.thumbnailUrl, size: max(width, height * 16 / 9), shape: .wide, cornerRadius: 0)
                    .frame(width: width, height: height)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(spacing: Design.Space.s) {
                    Text(verbatim: details.name)
                        .font(.system(size: width > 700 ? 56 : 38, weight: .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    if let subscribers = details.subscribersText {
                        Text(subscribers).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                    HStack(spacing: Design.Space.l) {
                        HeroCircleButton(symbol: "info", label: "artist.about", action: onInfo)
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 64, height: 64)
                                .background(.white, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("collection.play"))
                        .accessibilityLabel(Text("collection.play"))
                        HeroCircleButton(symbol: subscribed ? "star.fill" : "star", label: subscribed ? "artist.subscribed" : "artist.subscribe") {
                            model.setArtistSaved(ArtistItem(browseId: details.browseId, name: details.name, thumbnailUrl: details.thumbnailUrl), !subscribed)
                        }
                    }
                }
                .padding(.horizontal, Design.Space.l)
                .padding(.bottom, Design.Space.l)
            }
        }
        .frame(height: Self.heroHeight)
    }

    /// Высота шапки: на телефоне ~ 3/5 экрана, в окне — 480 pt (как у «Музыки»).
    static var heroHeight: CGFloat {
        #if os(iOS)
        return 460
        #else
        return 480
        #endif
    }

    /// Прокрутка, после которой крупное имя ушло под панель и имя встаёт в заголовок.
    static var collapseOffset: CGFloat { heroHeight - 160 }
}

/// Круглая кнопка на фото шапки: стекло, белый значок.
private struct HeroCircleButton: View {
    let symbol: String
    let label: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .glassCircle(48)
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// «Об исполнителе» — системный лист: фото, имя, подписчики, описание целиком. Полей, которых нет в данных YouTube Music
/// (откуда, дата рождения, жанр), не показываем.
struct ArtistInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let details: ArtistDetails

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    GeometryReader { proxy in
                        ArtworkView(url: details.thumbnailUrl, size: proxy.size.width, shape: .square, cornerRadius: 0)
                            .frame(width: proxy.size.width, height: 320, alignment: .top)
                            .clipped()
                    }
                    .frame(height: 320)
                    VStack(alignment: .leading, spacing: Design.Space.s) {
                        Text(verbatim: details.name).font(.largeTitle.weight(.bold))
                        if let subscribers = details.subscribersText {
                            Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let description = details.description, !description.isEmpty {
                            Text("artist.about").font(.title3.weight(.bold)).padding(.top, Design.Space.s)
                            Text(verbatim: description).font(.body).textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, Design.Space.l)
                    .padding(.bottom, Design.Space.l)
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 720)
        #endif
    }
}
