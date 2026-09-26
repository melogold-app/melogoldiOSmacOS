import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Каталог на часах (docs/PROMPT.md §5.6): Тренды и Новое — простые списки, без каруселей; детальный экран —
/// обложка и название, «Слушать», «Перемешать», список треков. Нажатие по треку играет по правилу очереди и
/// открывает «Сейчас играет».

// MARK: - Разделы

struct WatchTrendsView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let store = model.services.explore
        List {
            if let page = store.page {
                if store.fromCache {
                    Text("catalog.dataFrom \(page.loadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let trending = page.trending {
                    Section("trends.trending") {
                        let tracks = trending.tracks
                        ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                            WatchTrackRow(track: track, number: index + 1) { model.play(tracks, startAt: index) }
                        }
                        if let playlistId = page.trendingPlaylistId {
                            NavigationLink(value: WatchRoute.playlist(playlistId)) {
                                Text("trends.fullList")
                            }
                        }
                    }
                }
                if let moods = page.moods {
                    Section("trends.moods") {
                        ForEach(moods.items.compactMap(\.mood).prefix(8)) { mood in
                            NavigationLink(value: WatchRoute.mood(mood)) { Text(mood.title) }
                        }
                        NavigationLink(value: WatchRoute.moods) { Text("trends.allMoods") }
                    }
                }
            } else {
                WatchStateRow(state: store.state) { Task { await store.load(force: true) } }
            }
        }
        .navigationTitle(Text(AppSection.trends.title))
        .task { await store.load() }
    }
}

struct WatchNewView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let store = model.services.explore
        List {
            if let releases = store.page?.newReleases {
                Section("new.releases") {
                    ForEach(releases.items.compactMap(\.album).prefix(12)) { album in
                        WatchCollectionRow(title: album.title, subtitle: album.subtitle, artworkURL: album.thumbnailUrl,
                                           route: .album(album.browseId))
                    }
                    NavigationLink(value: WatchRoute.newReleases) { Text("new.allReleases") }
                }
            } else {
                WatchStateRow(state: store.state) { Task { await store.load(force: true) } }
            }
            Section("new.forYou") {
                Text("new.forYou.empty").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(AppSection.new.title))
        .task { await store.load() }
    }
}

// MARK: - Детальные экраны

struct WatchAlbumView: View {
    @Environment(WatchModel.self) private var model
    let browseId: String
    @State private var loader = PageLoader<AlbumDetails>()

    var body: some View {
        List {
            if let details = loader.value {
                WatchCollectionHeader(title: details.album.title, subtitle: details.album.artistsText,
                                      artworkURL: details.album.thumbnailUrl, tracks: details.tracks)
                ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                    WatchTrackRow(track: track, number: index + 1, showsArtwork: false) { model.play(details.tracks, startAt: index) }
                }
            } else {
                WatchStateRow(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text(verbatim: loader.value?.album.title ?? ""))
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        let browseId = browseId
        await loader.load(force: force) { try await catalog.album(browseId) }
    }
}

struct WatchPlaylistView: View {
    @Environment(WatchModel.self) private var model
    let playlistId: String
    @State private var loader = PageLoader<PlaylistDetails>()

    var body: some View {
        List {
            if let details = loader.value {
                WatchCollectionHeader(title: details.playlist.title, subtitle: details.authorText,
                                      artworkURL: details.playlist.thumbnailUrl, tracks: details.tracks)
                ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                    WatchTrackRow(track: track) { model.play(details.tracks, startAt: index) }
                }
            } else {
                WatchStateRow(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text(verbatim: loader.value?.playlist.title ?? ""))
        .task { await load() }
    }

    /// Часы: первая страница плейлиста (до 100 треков) — длинные списки листать на часах неудобно.
    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        let playlistId = playlistId
        await loader.load(force: force) { try await catalog.playlist(playlistId) }
    }
}

struct WatchArtistView: View {
    @Environment(WatchModel.self) private var model
    let browseId: String
    @State private var loader = PageLoader<ArtistDetails>()

    var body: some View {
        List {
            if let details = loader.value {
                VStack(spacing: 4) {
                    ArtworkView(url: details.thumbnailUrl, size: 64, shape: .circle)
                    Text(details.name).font(.headline).multilineTextAlignment(.center)
                    if let subscribers = details.subscribersText {
                        Text(subscribers).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                ForEach(Array(details.shelves.enumerated()), id: \.offset) { _, shelf in
                    section(shelf)
                }
            } else {
                WatchStateRow(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text(verbatim: loader.value?.name ?? ""))
        .task { await load() }
    }

    @ViewBuilder
    private func section(_ shelf: Shelf) -> some View {
        let tracks = shelf.tracks
        let collections = shelf.items.filter { $0.track == nil }
        if !tracks.isEmpty || !collections.isEmpty {
            Section {
                ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                    WatchTrackRow(track: track) { model.play(tracks, startAt: index) }
                }
                ForEach(collections.prefix(10)) { item in
                    WatchItemRow(item: item)
                }
            } header: {
                Text(verbatim: shelf.title ?? "")
            }
        }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        let browseId = browseId
        await loader.load(force: force) { try await catalog.artist(browseId) }
    }
}

struct WatchMoodView: View {
    @Environment(WatchModel.self) private var model
    let mood: MoodItem
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        List {
            if let shelves = loader.value {
                ForEach(shelves) { shelf in
                    Section {
                        ForEach(shelf.items.prefix(8)) { WatchItemRow(item: $0) }
                    } header: {
                        Text(verbatim: shelf.title ?? "")
                    }
                }
            } else {
                WatchStateRow(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text(verbatim: mood.title))
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        let mood = mood
        await loader.load(force: force) { try await catalog.browseShelves(mood.browseId, params: mood.params) }
    }
}

struct WatchMoodsView: View {
    @Environment(WatchModel.self) private var model
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        List {
            if let shelves = loader.value {
                ForEach(shelves) { shelf in
                    Section {
                        ForEach(shelf.items.compactMap(\.mood)) { mood in
                            NavigationLink(value: WatchRoute.mood(mood)) { Text(mood.title) }
                        }
                    } header: {
                        Text(verbatim: shelf.title ?? "")
                    }
                }
            } else {
                WatchStateRow(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text("trends.allMoods"))
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        await loader.load(force: force) { try await catalog.moods() }
    }
}

struct WatchNewReleasesView: View {
    @Environment(WatchModel.self) private var model
    @State private var loader = PageLoader<[Shelf]>()

    var body: some View {
        List {
            if let shelves = loader.value {
                ForEach(distinctItems(shelves.flatMap(\.items)).prefix(60)) { WatchItemRow(item: $0) }
            } else {
                WatchStateRow(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .navigationTitle(Text("new.allReleases"))
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        await loader.load(force: force) { try await catalog.newReleases() }
    }
}

// MARK: - Строки

/// Шапка детального экрана: обложка, название, «Слушать», «Перемешать».
struct WatchCollectionHeader: View {
    @Environment(WatchModel.self) private var model
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let tracks: [Track]

    var body: some View {
        VStack(spacing: 4) {
            ArtworkView(url: artworkURL, size: 72)
            Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        Button { model.playAll(tracks, shuffled: false) } label: {
            Label("collection.play", systemImage: "play.fill")
        }
        Button { model.playAll(tracks, shuffled: true) } label: {
            Label("collection.shuffle", systemImage: "shuffle")
        }
    }
}

struct WatchTrackRow: View {
    let track: Track
    var number: Int?
    var showsArtwork = true
    var downloaded = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let number {
                    Text("\(number)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                }
                if showsArtwork {
                    ArtworkView(url: track.artworkURL, size: 32)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title).font(.footnote).lineLimit(2)
                    if showsArtwork, let artists = track.artistsText {
                        Text(artists).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if downloaded {
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel(Text("badge.downloaded"))
                }
            }
        }
        .opacity(track.unavailable ? 0.4 : 1)
    }
}

/// Строка альбома, плейлиста или исполнителя; трек играет — трек и радио.
struct WatchItemRow: View {
    @Environment(WatchModel.self) private var model
    let item: MusicItem

    var body: some View {
        switch item {
        case .track(let track):
            WatchTrackRow(track: track) { model.play(single: track) }
        case .album(let album):
            WatchCollectionRow(title: album.title, subtitle: album.subtitle, artworkURL: album.thumbnailUrl, route: .album(album.browseId))
        case .playlist(let playlist):
            WatchCollectionRow(title: playlist.title, subtitle: playlist.subtitle ?? "", artworkURL: playlist.thumbnailUrl,
                               route: .playlist(playlist.playlistId))
        case .artist(let artist):
            WatchCollectionRow(title: artist.name, subtitle: artist.subtitle ?? "", artworkURL: artist.thumbnailUrl,
                               route: .artist(artist.browseId), circle: true)
        case .mood(let mood):
            NavigationLink(value: WatchRoute.mood(mood)) { Text(mood.title) }
        }
    }
}

struct WatchCollectionRow: View {
    let title: String
    let subtitle: String
    let artworkURL: String?
    let route: WatchRoute
    var circle = false

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 8) {
                ArtworkView(url: artworkURL, size: 32, shape: circle ? .circle : .rounded)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.footnote).lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Загрузка или ошибка с «Повторить».
struct WatchStateRow<Value>: View {
    let state: Loadable<Value>
    let retry: () -> Void

    var body: some View {
        switch state {
        case .failed(let kind):
            Text(kind.watchText).font(.footnote).foregroundStyle(.secondary)
            Button("common.retry", action: retry)
        default:
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(Color.clear)
        }
    }
}

extension YouTubeError.Kind {
    var watchText: LocalizedStringResource {
        switch self {
        case .offline: "error.offline"
        case .blocked: "error.blocked"
        case .parser: "error.parser"
        case .unknown: "error.unknown"
        }
    }
}
