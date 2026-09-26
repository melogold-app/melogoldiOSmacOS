import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldInnerTube

/// Порядок треков своего плейлиста (`sort.playlistItems`, одна на все свои плейлисты).
enum PlaylistItemsSort: String, CaseIterable {
    case custom, title, artist, dateAdded

    var title: LocalizedStringResource {
        switch self {
        case .custom: "sort.custom"
        case .title: "sort.title"
        case .artist: "sort.artist"
        case .dateAdded: "sort.dateAdded"
        }
    }
}

/// Свой плейлист (REWRITE §3.8.1): мозаика, «42 трека · 2 ч 10 мин», строка связи с YouTube, «Слушать · Перемешать ·
/// Скачать»; перетаскивание в своём порядке (VoiceOver — «Переместить выше/ниже»), фильтр; меню — «Переименовать»,
/// «Связь с YouTube», «Обновить из YouTube», «Поделиться», «Удалить плейлист».
struct LocalPlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistId: Int64
    @State private var playlist: LibraryPlaylist?
    @State private var tracks: [Track] = []
    @State private var filter = ""
    @State private var sort: PlaylistItemsSort = .custom
    @State private var updating = false
    @State private var linkSheet = false

    var body: some View {
        let visible = sorted(tracks.filter { !model.isHidden(PendingKey.item(playlistId, $0.videoId)) && matches($0, filter) })
        let canReorder = sort == .custom && filter.isEmpty
        Group {
            if let playlist {
                DetailPage(title: playlist.name) {
                    header(playlist, visible)
                } rows: {
                    if updating {
                        Label("playlist.updating", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, track in
                        TrackListRow(track: track, target: .list(visible, index), context: .playlist(playlistId))
                            .tag(RowID.make("p", track.videoId))
                            .accessibilityActions {
                                if canReorder, index > 0 {
                                    Button("playlist.moveUp") { move(track, to: index - 1) }
                                }
                                if canReorder, index + 1 < visible.count {
                                    Button("playlist.moveDown") { move(track, to: index + 1) }
                                }
                            }
                    }
                    .onMove(perform: canReorder ? { source, destination in
                        guard let from = source.first else { return }
                        let track = visible[from]
                        move(track, to: destination > from ? destination - 1 : destination)
                    } : nil)
                    if visible.isEmpty {
                        EmptyRow(title: "playlist.empty.title", systemImage: "music.note.list", description: "playlist.empty.message", filter: filter)
                    }
                } target: { id in
                    RowID.split(id).flatMap { key in visible.firstIndex { $0.videoId == key.key }.map { .list(visible, $0) } }
                } context: { _ in .playlist(playlistId) }
                .searchable(text: $filter, prompt: Text("library.filter"))
                .toolbar { toolbar(playlist) }
                .sheet(isPresented: $linkSheet) { LinkModeSheet(playlist: playlist) }
            } else {
                ContentUnavailableView { Label("playlist.missing", systemImage: "music.note.list") }
            }
        }
        .onAppear { sort = model.settings.sortOption("playlistItems", default: .custom) }
        .onChange(of: sort) { _, value in model.settings.setSort(value.rawValue, for: "playlistItems") }
        .task(id: model.library?.revision) { reload() }
        .task { await refreshIfStale() }
    }

    private func header(_ playlist: LibraryPlaylist, _ visible: [Track]) -> some View {
        VStack(spacing: 12) {
            PlaylistArtwork(playlist: playlist, size: 200)
            Text(verbatim: playlist.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(verbatim: LibraryText.summary(tracks))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            linkLine(playlist)
            HStack(spacing: 12) {
                PlayButton { model.playAll(visible, shuffled: false) }
                ShuffleButton { model.playAll(visible, shuffled: true) }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: 480)
            Picker(selection: $sort) {
                ForEach(PlaylistItemsSort.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("library.sort")
            }
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity)
    }

    /// «⛓ YouTube · Только добавлять · обновлено 2 ч назад»; режим другого устройства — «Взять на себя».
    @ViewBuilder
    private func linkLine(_ playlist: LibraryPlaylist) -> some View {
        switch playlist.link {
        case .mirror, .append:
            Button { linkSheet = true } label: {
                Label {
                    Text(verbatim: [String(localized: "playlist.link.youtube"),
                                    String(localized: playlist.link == .mirror ? "playlist.link.mirror" : "playlist.link.append"),
                                    playlist.linkSyncedAt.map(updatedText)].compactMap { $0 }.joined(separator: " · "))
                } icon: {
                    Image(systemName: "link")
                }
                .font(.footnote)
            }
            .buttonStyle(.borderless)
        case .unknown:
            HStack(spacing: 6) {
                Label("playlist.link.otherDeviceLine", systemImage: "link")
                Button("playlist.link.takeOver") { model.library?.library.setLink(.append, ofPlaylist: playlist.id) }
                    .buttonStyle(.borderless)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .none, .off:
            EmptyView()
        }
    }

    private func updatedText(_ at: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(at) / 1000)
        return String(localized: "playlist.link.updated \(date.formatted(.relative(presentation: .named)))")
    }

    @ToolbarContentBuilder
    private func toolbar(_ playlist: LibraryPlaylist) -> some ToolbarContent {
        ToolbarItem {
            CollectionDownloadButton(kind: .playlist, key: String(playlist.id), title: playlist.name)
        }
        ToolbarItem {
            Menu {
                Button { model.renameRequest = playlist } label: { Label("playlist.rename", systemImage: "pencil") }
                if playlist.browseId != nil {
                    Button { linkSheet = true } label: { Label("playlist.link.menu", systemImage: "link") }
                    if playlist.link == .mirror || playlist.link == .append {
                        Button { Task { await update(force: true) } } label: {
                            Label("playlist.link.update", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    if let browseId = playlist.browseId {
                        ShareLink(item: ShareLinks.playlist(browseId)) { Label("menu.share", systemImage: "square.and.arrow.up") }
                    }
                }
                Divider()
                Button(role: .destructive) { model.deletePlaylist(playlist) } label: { Label("playlist.delete", systemImage: "trash") }
            } label: {
                Label("menu.more", systemImage: "ellipsis")
            }
        }
        #if os(iOS)
        if sort == .custom, filter.isEmpty {
            ToolbarItem { EditButton() }
        }
        #endif
    }

    private func sorted(_ list: [Track]) -> [Track] {
        switch sort {
        case .custom, .dateAdded: list
        case .title: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: list.sorted { ($0.artistsText ?? "").localizedStandardCompare($1.artistsText ?? "") == .orderedAscending }
        }
    }

    private func move(_ track: Track, to index: Int) {
        model.library?.library.move(track.videoId, inPlaylist: playlistId, to: index)
    }

    private func reload() {
        playlist = model.library?.library.playlist(playlistId)
        tracks = model.library?.library.playlistTracks(playlistId) ?? []
    }

    /// Связанный плейлист обновляется при открытии, если с прошлого раза прошло больше 12 часов (тихо).
    private func refreshIfStale() async {
        guard let playlist = model.library?.library.playlist(playlistId), playlist.link == .mirror || playlist.link == .append else { return }
        let stale = playlist.linkSyncedAt.map { EpochMs.now() - $0 > 12 * 3600 * 1000 } ?? true
        if stale { await update(force: false) }
    }

    /// «Обновить из YouTube»: только полный список (все продолжения), иначе плейлист не меняется.
    private func update(force: Bool) async {
        guard let library = model.library?.library, let playlist = library.playlist(playlistId),
              let browseId = playlist.browseId else { return }
        updating = true
        defer { updating = false }
        do {
            let remote = try await model.services.catalog.playlistTracks(browseId, max: 5000)
            guard !remote.isEmpty else { throw YouTubeError(.parser, "пустой плейлист") }
            let added = library.applyYouTube(remote, toPlaylist: playlistId, mode: playlist.link)
            if let added {
                if added > 0 || force {
                    model.toast = Toast(text: String(localized: "playlist.link.added \(added)"))
                }
            } else {
                model.toast = Toast(text: String(localized: "playlist.link.remembered"))
            }
        } catch {
            if force { model.toast = Toast(text: String(localized: "playlist.link.incomplete")) }
        }
    }
}

/// «Связь с YouTube»: «Зеркало», «Только добавлять» (рекомендуем), «Отвязать» — с пояснениями (REWRITE §3.8.1).
struct LinkModeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: LibraryPlaylist

    var body: some View {
        NavigationStack {
            List {
                option(.append, title: "playlist.link.append", note: "playlist.link.append.note", recommended: true)
                option(.mirror, title: "playlist.link.mirror", note: "playlist.link.mirror.note")
                option(.off, title: "playlist.link.unlink", note: "playlist.link.unlink.note")
            }
            .navigationTitle(Text("playlist.link.menu"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func option(_ mode: LibraryPlaylist.YouTubeLink, title: LocalizedStringResource, note: LocalizedStringResource,
                        recommended: Bool = false) -> some View {
        Button {
            model.library?.library.setLink(mode, ofPlaylist: playlist.id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                        if recommended {
                            Text("playlist.link.recommended").font(.caption).foregroundStyle(.tint)
                        }
                    }
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if playlist.link == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
