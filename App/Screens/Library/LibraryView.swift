import SwiftUI
import MelogoldCore
import MelogoldData

/// «Библиотека» — хаб (REWRITE §3.2.1, docs/PROMPT.md §5.9): Избранное, Скачанное, История; плейлисты; «Все треки»
/// (задание 0007), Альбомы, Исполнители и каналы. Сети не требует.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: [LibraryPlaylist] = []
    @State private var newPlaylist = false
    @State private var hasHistory = false

    var body: some View {
        let library = model.library
        let counts = library?.counts ?? LibraryCounts()
        let visible = playlists.filter { !model.isHidden(PendingKey.playlist($0.id)) }
        let isEmpty = counts.likes == 0 && counts.playlists == 0 && counts.albums == 0 && counts.artists == 0
            && counts.allTracks == 0 && counts.downloads == 0 && !hasHistory
        List {
            Section {
                tiles(counts)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("library.empty.title", systemImage: "music.note.square.stack")
                    } description: {
                        Text("library.empty.message")
                    } actions: {
                        Button("library.findMusic") { model.focusSearch() }
                            .buttonStyle(.borderedProminent)
                        Button("new.forYou.trends") { model.select(.trends) }
                    }
                }
            }
            Section {
                Button {
                    newPlaylist = true
                } label: {
                    Label("library.newPlaylist", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                ForEach(visible.prefix(5)) { playlist in
                    NavigationLink(value: Route.localPlaylist(playlist.id)) {
                        PlaylistRow(playlist: playlist)
                    }
                    .contextMenu { PlaylistMenuItems(playlist: playlist) }
                }
                if visible.count > 5 {
                    NavigationLink(value: Route.playlists) {
                        Text("library.allPlaylists \(visible.count)")
                    }
                }
            } header: {
                Text("library.playlists")
            }
            Section {
                NavigationLink(value: Route.allTracks) {
                    countRow("library.allTracks", systemImage: "music.note", count: counts.allTracks)
                }
                NavigationLink(value: Route.savedAlbums) {
                    countRow("library.albums", systemImage: "square.stack", count: counts.albums)
                }
                NavigationLink(value: Route.savedArtists) {
                    countRow("library.artists", systemImage: "music.mic", count: counts.artists)
                }
            }
        }
        .navigationTitle(Text(AppSection.library.title))
        .toolbar {
            ToolbarItem {
                Menu {
                    Button { newPlaylist = true } label: { Label("library.newPlaylist", systemImage: "text.badge.plus") }
                } label: {
                    Label("library.add", systemImage: "plus")
                }
            }
        }
        .newPlaylistAlert(isPresented: $newPlaylist) { id in
            model.open(.localPlaylist(id))
        }
        .task(id: library?.revision) {
            playlists = library?.library.playlists() ?? []
            hasHistory = (library?.library.playCount() ?? 0) > 0
        }
    }

    /// Плитки коллекций: Избранное, Скачанное, История.
    private func tiles(_ counts: LibraryCounts) -> some View {
        HStack(spacing: 12) {
            tile("library.favorites", systemImage: "heart.fill", tint: .pink, count: counts.likes, route: .favorites)
            tile("library.downloads", systemImage: "arrow.down.circle.fill", tint: .green, count: counts.downloads, route: .downloads)
            tile("library.history", systemImage: "clock.arrow.circlepath", tint: .orange, count: nil, route: .history)
        }
        .padding(.vertical, 4)
    }

    private func tile(_ title: LocalizedStringResource, systemImage: String, tint: Color, count: Int?, route: Route) -> some View {
        Button {
            model.open(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(count.map { "\($0)" } ?? " ")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(12)
            .background(CardBackground.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func countRow(_ title: LocalizedStringResource, systemImage: String, count: Int) -> some View {
        LabeledContent {
            Text("\(count)").monospacedDigit()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Строка своего плейлиста: мозаика, название, «42 трека», метка связи с YouTube (REWRITE §3.2.5).
struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
    let playlist: LibraryPlaylist

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtwork(playlist: playlist, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: playlist.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text("library.tracks \(playlist.trackCount)")
                    switch playlist.link {
                    case .mirror, .append:
                        Label("playlist.link.youtube", systemImage: "link").labelStyle(.titleAndIcon)
                    case .unknown:
                        Label("playlist.link.otherDevice", systemImage: "link").labelStyle(.titleAndIcon)
                    case .none, .off:
                        EmptyView()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.services.downloads?.store.isCollection(.playlist, key: String(playlist.id)) == true {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("badge.downloaded"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Меню своего плейлиста в списках: «Переименовать», «Удалить».
struct PlaylistMenuItems: View {
    @Environment(AppModel.self) private var model
    let playlist: LibraryPlaylist

    var body: some View {
        Button { model.renameRequest = playlist } label: {
            Label("playlist.rename", systemImage: "pencil")
        }
        Button(role: .destructive) { model.deletePlaylist(playlist) } label: {
            Label("playlist.delete", systemImage: "trash")
        }
    }
}

extension View {
    /// «Новый плейлист»: название по умолчанию «Плейлист N», после создания — `created(id)`.
    func newPlaylistAlert(isPresented: Binding<Bool>, tracks: [Track] = [], created: @escaping (Int64) -> Void) -> some View {
        modifier(NewPlaylistAlert(isPresented: isPresented, tracks: tracks, created: created))
    }
}

private struct NewPlaylistAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    let tracks: [Track]
    let created: (Int64) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(Text("library.newPlaylist"), isPresented: $isPresented) {
            TextField(text: $name) { Text("playlist.name") }
            Button("common.cancel", role: .cancel) {}
            Button("playlist.create") {
                let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
                if let id = model.createPlaylist(name: title, tracks: tracks) { created(id) }
            }
        }
        .onChange(of: isPresented) { _, shown in if shown { name = defaultName } }
    }

    private var defaultName: String {
        String(localized: "playlist.defaultName \((model.library?.counts.playlists ?? 0) + 1)")
    }
}

/// Фон карточки на сгруппированном фоне — как у строк списка.
enum CardBackground {
    static var color: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.secondary.opacity(0.15)
        #endif
    }
}
