import SwiftUI
import MelogoldCore
import MelogoldData

// MARK: - Избранное (REWRITE §3.2.2)

struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []
    @State private var filter = ""
    @State private var sort: FavoritesSort = .dateAdded

    var body: some View {
        let visible = tracks.filter { !model.isHidden(PendingKey.like($0.videoId)) && matches($0, filter) }
        SelectableList(target: { id in
            RowID.split(id).flatMap { key in visible.firstIndex { $0.videoId == key.key }.map { .list(visible, $0) } }
        }, context: { _ in .favorites }) {
            if !visible.isEmpty {
                TrackListHeader(summary: LibraryText.summary(visible)) {
                    model.playAll(visible, shuffled: false)
                } shuffle: {
                    model.playAll(visible, shuffled: true)
                }
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                TrackListRow(track: track, target: .list(visible, index), context: .favorites)
                    .tag(RowID.make("f", track.videoId))
            }
            if visible.isEmpty {
                EmptyRow(title: "library.favorites.empty", systemImage: "heart", filter: filter)
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text("library.favorites"))
        .inlineTitle()
        .searchable(text: $filter, prompt: Text("library.filter"))
        .toolbar {
            ToolbarItemGroup {
                CollectionDownloadButton(kind: .liked, key: "", title: String(localized: "library.favorites"))
                SortMenu(options: FavoritesSort.allCases, selection: $sort) { $0.title }
            }
        }
        .onAppear { sort = model.settings.sortOption("favorites", default: .dateAdded) }
        .onChange(of: sort) { _, value in
            model.settings.setSort(value.rawValue, for: "favorites")
            reload()
        }
        .task(id: model.library?.revision) { reload() }
    }

    private func reload() {
        tracks = model.library?.library.favorites(sort: sort) ?? []
    }
}

extension FavoritesSort {
    var title: LocalizedStringResource {
        switch self {
        case .dateAdded: "sort.dateAdded"
        case .title: "sort.title"
        case .artist: "sort.artist"
        case .duration: "sort.duration"
        }
    }
}

// MARK: - «Все треки» (задание 0007)

struct AllTracksView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AllTracksEntry] = []
    @State private var filter = ""
    @State private var sort: AllTracksSort = .recentlyPlayed

    var body: some View {
        let visible = entries.filter { matches($0.track, filter) }
        let tracks = visible.map(\.track)
        SelectableList(target: { id in
            RowID.split(id).flatMap { key in tracks.firstIndex { $0.videoId == key.key }.map { .list(tracks, $0) } }
        }) {
            if !tracks.isEmpty {
                TrackListHeader(summary: LibraryText.summary(tracks)) {
                    model.playAll(tracks, shuffled: false)
                } shuffle: {
                    model.playAll(tracks, shuffled: true)
                }
            }
            ForEach(Array(visible.enumerated()), id: \.element.track.id) { index, entry in
                TrackListRow(track: entry.track, subtitle: subtitle(entry), target: .list(tracks, index))
                    .tag(RowID.make("a", entry.track.videoId))
            }
            if visible.isEmpty {
                EmptyRow(title: "library.allTracks", systemImage: "music.note", description: "library.allTracks.empty", filter: filter)
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text("library.allTracks"))
        .inlineTitle()
        .searchable(text: $filter, prompt: Text("library.filter"))
        .toolbar {
            ToolbarItem {
                SortMenu(options: AllTracksSort.allCases, selection: $sort) { $0.title }
            }
        }
        .onAppear { sort = model.settings.sortOption("allTracks", default: .recentlyPlayed) }
        .onChange(of: sort) { _, value in
            model.settings.setSort(value.rawValue, for: "allTracks")
            reload()
        }
        .task(id: model.library?.revision) { reload() }
    }

    /// «Кино · 35 ч 54 мин» — исполнитель и сколько его слушали.
    private func subtitle(_ entry: AllTracksEntry) -> String {
        guard entry.playTimeMs > 0 else { return entry.track.artistsText ?? "" }
        return [entry.track.artistsText, LibraryText.playTime(entry.playTimeMs)].compactMap { $0 }.joined(separator: " · ")
    }

    private func reload() {
        entries = model.library?.library.allTracks(sort: sort) ?? []
    }
}

extension AllTracksSort {
    var title: LocalizedStringResource {
        switch self {
        case .recentlyPlayed: "sort.recentlyPlayed"
        case .playTime: "sort.playTime"
        case .title: "sort.title"
        case .artist: "sort.artist"
        case .duration: "sort.duration"
        }
    }
}

// MARK: - Плейлисты (REWRITE §3.2.5)

enum PlaylistsSort: String, CaseIterable {
    case created, name, count

    var title: LocalizedStringResource {
        switch self {
        case .created: "sort.created"
        case .name: "sort.title"
        case .count: "sort.trackCount"
        }
    }
}

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: [LibraryPlaylist] = []
    @State private var filter = ""
    @State private var sort: PlaylistsSort = .created
    @State private var newPlaylist = false

    var body: some View {
        let visible = sorted(playlists.filter {
            !model.isHidden(PendingKey.playlist($0.id))
                && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
        })
        List {
            Button { newPlaylist = true } label: {
                Label("library.newPlaylist", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            ForEach(visible) { playlist in
                NavigationLink(value: Route.localPlaylist(playlist.id)) {
                    PlaylistRow(playlist: playlist)
                }
                .contextMenu { PlaylistMenuItems(playlist: playlist) }
                .swipeActions {
                    Button(role: .destructive) { model.deletePlaylist(playlist) } label: {
                        Label("playlist.delete", systemImage: "trash")
                    }
                }
            }
            if visible.isEmpty {
                EmptyRow(title: "library.playlists", systemImage: "music.note.list", description: "library.playlists.empty", filter: filter)
            }
        }
        .navigationTitle(Text("library.playlists"))
        .inlineTitle()
        .searchable(text: $filter, prompt: Text("library.filter"))
        .toolbar {
            ToolbarItem {
                SortMenu(options: PlaylistsSort.allCases, selection: $sort) { $0.title }
            }
        }
        .newPlaylistAlert(isPresented: $newPlaylist) { id in model.open(.localPlaylist(id)) }
        .onAppear { sort = model.settings.sortOption("playlists", default: .created) }
        .onChange(of: sort) { _, value in model.settings.setSort(value.rawValue, for: "playlists") }
        .task(id: model.library?.revision) { playlists = model.library?.library.playlists() ?? [] }
    }

    private func sorted(_ list: [LibraryPlaylist]) -> [LibraryPlaylist] {
        switch sort {
        case .created: list
        case .name: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .count: list.sorted { $0.trackCount > $1.trackCount }
        }
    }
}

// MARK: - Альбомы (REWRITE §3.2.6)

enum AlbumsSort: String, CaseIterable {
    case dateAdded, title, artist, year

    var title: LocalizedStringResource {
        switch self {
        case .dateAdded: "sort.dateAdded"
        case .title: "sort.title"
        case .artist: "sort.artist"
        case .year: "sort.year"
        }
    }
}

struct SavedAlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var albums: [AlbumItem] = []
    @State private var filter = ""
    @State private var sort: AlbumsSort = .dateAdded

    var body: some View {
        let visible = sorted(albums.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || ($0.artistsText ?? "").localizedCaseInsensitiveContains(filter)
        })
        Group {
            if visible.isEmpty {
                if filter.isEmpty {
                    ContentUnavailableView {
                        Label("library.albums", systemImage: "square.stack")
                    } description: {
                        Text("library.albums.empty")
                    }
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            } else {
                CardGrid(items: visible.map(MusicItem.album))
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text("library.albums"))
        .inlineTitle()
        .searchable(text: $filter, prompt: Text("library.filter"))
        .toolbar {
            ToolbarItem {
                SortMenu(options: AlbumsSort.allCases, selection: $sort) { $0.title }
            }
        }
        .onAppear { sort = model.settings.sortOption("albums", default: .dateAdded) }
        .onChange(of: sort) { _, value in model.settings.setSort(value.rawValue, for: "albums") }
        .task(id: model.library?.revision) { albums = model.library?.library.savedAlbums() ?? [] }
    }

    private func sorted(_ list: [AlbumItem]) -> [AlbumItem] {
        switch sort {
        case .dateAdded: list
        case .title: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: list.sorted { ($0.artistsText ?? "").localizedStandardCompare($1.artistsText ?? "") == .orderedAscending }
        case .year: list.sorted { ($0.year ?? "") > ($1.year ?? "") }
        }
    }
}

// MARK: - Исполнители и каналы (REWRITE §3.2.7)

enum ArtistsSort: String, CaseIterable {
    case dateAdded, name

    var title: LocalizedStringResource {
        switch self {
        case .dateAdded: "sort.dateAdded"
        case .name: "sort.name"
        }
    }
}

struct SavedArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: [ArtistItem] = []
    @State private var filter = ""
    @State private var sort: ArtistsSort = .dateAdded

    var body: some View {
        let visible = sorted(artists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) })
        List {
            ForEach(visible) { artist in
                NavigationLink(value: Route.artist(artist.browseId)) {
                    HStack(spacing: 12) {
                        ArtworkView(url: artist.thumbnailUrl, size: 48, shape: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: artist.name).lineLimit(1)
                            if artist.isChannel {
                                Text("library.youtubeChannel").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { model.setArtistSaved(artist, false) } label: {
                        Label("artist.unsubscribe", systemImage: "person.badge.minus")
                    }
                }
            }
            if visible.isEmpty {
                EmptyRow(title: "library.artists", systemImage: "music.mic", description: "library.artists.empty", filter: filter)
            }
        }
        .navigationTitle(Text("library.artists"))
        .inlineTitle()
        .searchable(text: $filter, prompt: Text("library.filter"))
        .toolbar {
            ToolbarItem {
                SortMenu(options: ArtistsSort.allCases, selection: $sort) { $0.title }
            }
        }
        .onAppear { sort = model.settings.sortOption("artists", default: .dateAdded) }
        .onChange(of: sort) { _, value in model.settings.setSort(value.rawValue, for: "artists") }
        .task(id: model.library?.revision) { artists = model.library?.library.savedArtists() ?? [] }
    }

    private func sorted(_ list: [ArtistItem]) -> [ArtistItem] {
        switch sort {
        case .dateAdded: list
        case .name: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

// MARK: - Скрытые треки (Настройки › Библиотека и история)

struct HiddenTracksView: View {
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []

    var body: some View {
        List {
            ForEach(tracks) { track in
                HStack {
                    TrackRow(track: track)
                    Button("hidden.show") { model.library?.library.setHidden(track, false) }
                        .buttonStyle(.borderless)
                }
            }
            if tracks.isEmpty {
                EmptyRow(title: "settings.hidden", systemImage: "eye.slash", description: "hidden.empty")
            }
        }
        .navigationTitle(Text("settings.hidden"))
        .inlineTitle()
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem {
                    Button("hidden.showAll") {
                        for track in tracks { model.library?.library.setHidden(track, false) }
                    }
                }
            }
        }
        .task(id: model.library?.revision) { tracks = model.library?.library.hiddenTracks() ?? [] }
    }
}

// MARK: - «Добавить в плейлист…»

/// Лист выбора плейлиста: галочки у плейлистов, где трек уже есть; «Новый плейлист» сверху.
struct PlaylistPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PlaylistPickerRequest
    @State private var playlists: [LibraryPlaylist] = []
    @State private var containing: Set<Int64> = []
    @State private var newPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Button { newPlaylist = true } label: {
                    Label("library.newPlaylist", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                ForEach(playlists) { playlist in
                    Button {
                        model.add(request.tracks, toPlaylist: playlist)
                        dismiss()
                    } label: {
                        HStack {
                            PlaylistRow(playlist: playlist)
                            if containing.contains(playlist.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(Text("menu.addToPlaylist"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .newPlaylistAlert(isPresented: $newPlaylist, tracks: request.tracks) { _ in
                model.toast = Toast(text: String(localized: "library.playlistCreated"))
                dismiss()
            }
        }
        .task {
            playlists = model.library?.library.playlists() ?? []
            if request.tracks.count == 1, let track = request.tracks.first {
                containing = model.library?.library.playlistsContaining(track.videoId) ?? []
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}
