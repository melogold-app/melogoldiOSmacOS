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
            NavigationLink(value: WatchRoute.stats) {
                Label("stats.title", systemImage: "chart.bar.xaxis")
            }
        }
        .navigationTitle(Text(AppSection.library.title))
    }

    private func row(_ title: LocalizedStringResource, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(verbatim: "\(count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
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
            // Только «Недавние», без периода и фильтра: прослушивания всех устройств аккаунта (задание 0002 §3.6)
            tracks = library.recentHistory(limit: 100).map(\.track)
        case .playlist(let id):
            title = library.playlist(id)?.name ?? ""
            tracks = library.playlistTracks(id)
        }
    }
}

/// Строка трека на часах: обложка, название, исполнитель, метка «скачано». Действия — смахивание влево, «Ещё»: ♡, «Играть
/// следующим», «В конец очереди», «Скачать» или «Удалить загрузку» (§5.6). Меню по долгому нажатию на watchOS не показывается
/// (Force Touch убран в watchOS 7, `contextMenu` там устарел): долгое нажатие просто играет трек.
struct WatchLibraryTrackRow: View {
    @Environment(WatchModel.self) private var model
    let track: Track
    let action: () -> Void
    @State private var showsActions = false

    var body: some View {
        WatchTrackRow(track: track, downloaded: model.services.library?.isDownloaded(track.videoId) == true, action: action)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { showsActions = true } label: { Label("common.more", systemImage: "ellipsis") }
            }
            .confirmationDialog(Text(verbatim: track.title), isPresented: $showsActions, titleVisibility: .visible) {
                WatchTrackMenu(track: track)
            }
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
                if track.videoType == VideoType.live {
                    Button {} label: { Label("menu.download.live", systemImage: "arrow.down.circle") }
                        .disabled(true)
                } else {
                    Button { model.download(track) } label: {
                        Label("menu.download", systemImage: "arrow.down.circle")
                    }
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
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.items.enumerated()), id: \.element.id) { index, item in
                    let current = index == player.index
                    Button { player.jump(to: item.id) } label: {
                        HStack(spacing: 8) {
                            ArtworkView(url: item.track.artworkURL, size: 34, cornerRadius: 8)
                                .overlay {
                                    // Текущий трек: поверх обложки столбики звука, бегут, пока играет
                                    if current {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.45))
                                            Image(systemName: "waveform")
                                                .font(.footnote.weight(.bold))
                                                .foregroundStyle(.white)
                                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                        }
                                    }
                                }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.track.title)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(2)
                                    .foregroundStyle(.white)
                                Text(item.track.artistsText ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .id(item.id)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(current ? 0.26 : 0.1))
                            .animation(.smooth(duration: 0.4), value: current)
                    )
                    .swipeActions {
                        Button(role: .destructive) { player.remove(item.id) } label: { Label("menu.removeFromQueue", systemImage: "trash") }
                    }
                }
            }
            .onAppear {
                if let index = player.index, player.items.indices.contains(index) { proxy.scrollTo(player.items[index].id, anchor: .top) }
            }
        }
        .navigationTitle(Text("player.queue"))
        .playerBackground()
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
