import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldPlayback

/// Библиотека часов (docs/PROMPT.md §5.6): «Все треки» — главный список (задание 0007), Избранное, Плейлисты,
/// Альбомы, Исполнители и каналы, Скачанное, История (недавние). Всё из базы часов: прослушанное на часах, лайки и
/// плейлисты, пришедшие синком, скачанное на часах.
struct WatchLibraryView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let counts = model.services.library?.counts ?? LibraryCounts()
        List {
            NavigationLink(value: WatchRoute.library(.allTracks)) {
                row("library.allTracks", "music.note", counts.allTracks)
            }
            NavigationLink(value: WatchRoute.library(.favorites)) {
                row("library.favorites", "heart.fill", counts.likes)
            }
            NavigationLink(value: WatchRoute.library(.playlists)) {
                row("library.playlists", "music.note.list", counts.playlists)
            }
            NavigationLink(value: WatchRoute.library(.albums)) {
                row("library.albums", "square.stack", counts.albums)
            }
            NavigationLink(value: WatchRoute.library(.artists)) {
                row("library.artists", "music.mic", counts.artists)
            }
            NavigationLink(value: WatchRoute.library(.downloads)) {
                row("library.downloads", "arrow.down.circle.fill", counts.downloads)
            }
            NavigationLink(value: WatchRoute.library(.history)) {
                Label("library.history", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle(Text(AppSection.library.title))
    }

    private func row(_ title: LocalizedStringResource, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Экран библиотеки часов.
enum WatchLibraryPage: Hashable {
    case allTracks, favorites, playlists, albums, artists, downloads, history
    case playlist(Int64)
}

struct WatchLibraryPageView: View {
    @Environment(WatchModel.self) private var model
    let page: WatchLibraryPage
    @State private var tracks: [Track] = []
    @State private var playlists: [LibraryPlaylist] = []
    @State private var albums: [AlbumItem] = []
    @State private var artists: [ArtistItem] = []
    @State private var title = ""

    var body: some View {
        List {
            switch page {
            case .playlists:
                ForEach(playlists) { playlist in
                    NavigationLink(value: WatchRoute.library(.playlist(playlist.id))) {
                        VStack(alignment: .leading) {
                            Text(verbatim: playlist.name).font(.footnote).lineLimit(2)
                            Text("library.tracks \(playlist.trackCount)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if playlists.isEmpty { empty }
            case .albums:
                ForEach(albums) { WatchItemRow(item: .album($0)) }
                if albums.isEmpty { empty }
            case .artists:
                ForEach(artists) { WatchItemRow(item: .artist($0)) }
                if artists.isEmpty { empty }
            case .history:
                ForEach(tracks) { track in
                    WatchLibraryTrackRow(track: track) { model.play(single: track) }
                }
                if tracks.isEmpty { empty }
            default:
                if !tracks.isEmpty {
                    Button { model.playAll(tracks, shuffled: false) } label: {
                        Label("collection.play", systemImage: "play.fill")
                    }
                    Button { model.playAll(tracks, shuffled: true) } label: {
                        Label("collection.shuffle", systemImage: "shuffle")
                    }
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    WatchLibraryTrackRow(track: track) { model.play(tracks, startAt: index) }
                }
                if tracks.isEmpty { empty }
            }
        }
        .navigationTitle(Text(verbatim: title))
        .task(id: model.services.library?.revision) { reload() }
    }

    private var empty: some View {
        Text("catalog.empty").font(.footnote).foregroundStyle(.secondary)
    }

    private func reload() {
        guard let store = model.services.library else { return }
        let library = store.library
        switch page {
        case .allTracks:
            title = String(localized: "library.allTracks")
            tracks = library.allTracks().map(\.track)
        case .favorites:
            title = String(localized: "library.favorites")
            tracks = library.favorites()
        case .playlists:
            title = String(localized: "library.playlists")
            playlists = library.playlists()
        case .albums:
            title = String(localized: "library.albums")
            albums = library.savedAlbums()
        case .artists:
            title = String(localized: "library.artists")
            artists = library.savedArtists()
        case .downloads:
            title = String(localized: "library.downloads")
            tracks = (model.services.downloads?.store.entries() ?? []).filter { $0.state == .completed }.compactMap(\.track)
        case .history:
            title = String(localized: "library.history")
            tracks = library.recentHistory(limit: 100).map(\.track)
        case .playlist(let id):
            title = library.playlist(id)?.name ?? ""
            tracks = library.playlistTracks(id)
        }
    }
}

/// Строка трека на часах: обложка, название, исполнитель, метка «скачано». Меню — долгое нажатие: ♡, «Играть
/// следующим», «В конец очереди», «Скачать» или «Удалить загрузку» (§5.6).
struct WatchLibraryTrackRow: View {
    @Environment(WatchModel.self) private var model
    let track: Track
    let action: () -> Void

    var body: some View {
        WatchTrackRow(track: track, downloaded: model.services.library?.isDownloaded(track.videoId) == true, action: action)
            .contextMenu { WatchTrackMenu(track: track) }
    }
}

struct WatchTrackMenu: View {
    @Environment(WatchModel.self) private var model
    let track: Track

    var body: some View {
        let library = model.services.library
        let liked = library?.isLiked(track.videoId) == true
        Button { library?.library.setLiked(track, !liked) } label: {
            Label(liked ? "menu.unlike" : "menu.like", systemImage: liked ? "heart.slash" : "heart")
        }
        Button { model.services.player.playNext([track]) } label: {
            Label("menu.playNext", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { model.services.player.enqueue([track]) } label: {
            Label("menu.addToQueue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if let downloads = model.services.downloads {
            if library?.downloadStates[track.videoId] == nil {
                Button { model.download(track) } label: {
                    Label("menu.download", systemImage: "arrow.down.circle")
                }
            } else {
                Button(role: .destructive) { downloads.remove(track.videoId) } label: {
                    Label("menu.removeDownload", systemImage: "trash")
                }
            }
        }
    }
}

/// «Очередь» на часах: нажатие переходит к треку, смахивание удаляет; перетаскивания нет (§5.6).
struct WatchQueueView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let player = model.services.player
        List {
            ForEach(Array(player.items.enumerated()), id: \.element.id) { index, item in
                Button { player.jump(to: item.id) } label: {
                    HStack(spacing: 8) {
                        ArtworkView(url: item.track.artworkURL, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.track.title).font(.footnote).lineLimit(2)
                                .foregroundStyle(index == player.index ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            Text(item.track.artistsText ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { player.remove(item.id) } label: { Label("menu.removeFromQueue", systemImage: "trash") }
                }
            }
        }
        .navigationTitle(Text("player.queue"))
    }
}

/// «Хранилище» в Настройках часов: сколько занимают загрузки, сколько свободно на часах, «Только по Wi‑Fi», «Удалить
/// все загрузки» (§5.6).
struct WatchStorageSection: View {
    @Environment(WatchModel.self) private var model
    @State private var free: Int64?
    @State private var confirm = false

    var body: some View {
        @Bindable var settings = model.settings
        let _ = model.services.library?.downloadsRevision
        let bytes = model.services.downloads?.store.totalBytes() ?? 0
        Section("settings.storage") {
            LabeledContent {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            } label: {
                Text("settings.downloads")
            }
            if let free {
                LabeledContent {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                } label: {
                    Text("settings.freeOnWatch")
                }
            }
            Toggle("settings.downloadsWifiOnly", isOn: $settings.downloadsWifiOnly)
                .onChange(of: settings.downloadsWifiOnly) { _, value in model.services.downloads?.wifiOnly = value }
            Button("settings.downloadsRemoveAll", role: .destructive) { confirm = true }
                .disabled(bytes == 0)
                .confirmationDialog(Text("settings.downloadsRemoveAll"), isPresented: $confirm) {
                    Button("settings.downloadsRemoveAll", role: .destructive) { model.services.downloads?.removeAll() }
                }
        }
        .task {
            let url = model.services.downloads?.store.directory ?? FileManager.default.temporaryDirectory
            free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        }
    }
}

/// Библиотечные настройки часов: нормализация и «Не сохранять историю».
struct WatchPlaybackSection: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section("settings.playback") {
            Toggle("settings.normalize", isOn: $settings.normalization)
                .onChange(of: settings.normalization) { _, value in model.services.player.normalization = value }
            Toggle("settings.historyPaused", isOn: $settings.historyPaused)
        }
    }
}
