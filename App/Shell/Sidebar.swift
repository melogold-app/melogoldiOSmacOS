import SwiftUI
import MelogoldCore
import MelogoldData

/// Строка боковой панели: один из пяти разделов (docs/PROMPT.md §5.4), часть Библиотеки или свой плейлист.
enum SidebarItem: Hashable {
    case section(AppSection)
    case shortcut(LibraryShortcut)
    case playlist(Int64)
}

/// Быстрые переходы в часть Библиотеки — группа «Библиотека» боковой панели, как в Music.app («Альбомы», «Исполнители»…).
/// Порядок и значки — как в хабе Библиотеки.
enum LibraryShortcut: CaseIterable, Hashable {
    case favorites, downloads, history, allTracks, albums, artists

    var route: Route {
        switch self {
        case .favorites: .favorites
        case .downloads: .downloads
        case .history: .history
        case .allTracks: .allTracks
        case .albums: .savedAlbums
        case .artists: .savedArtists
        }
    }

    init?(route: Route) {
        guard let match = Self.allCases.first(where: { $0.route == route }) else { return nil }
        self = match
    }

    var title: LocalizedStringResource {
        switch self {
        case .favorites: "library.favorites"
        case .downloads: "library.downloads"
        case .history: "library.history"
        case .allTracks: "library.allTracks"
        case .albums: "library.albums"
        case .artists: "library.artists"
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: "heart"
        case .downloads: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        case .allTracks: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        }
    }
}

extension AppModel {
    /// Какая строка боковой панели подсвечена: по разделу и первому экрану его стека, глубже — всё та же строка
    /// (открытый из «Избранного» альбом оставляет подсвеченным «Избранное»).
    var sidebarSelection: SidebarItem {
        Self.sidebarSelection(section: section, library: routes[.library])
    }

    static func sidebarSelection(section: AppSection, library: [Route]?) -> SidebarItem {
        if section == .library, let first = library?.first {
            if let shortcut = LibraryShortcut(route: first) { return .shortcut(shortcut) }
            if case .localPlaylist(let id) = first { return .playlist(id) }
        }
        return .section(section)
    }

    /// Щелчок по строке боковой панели. Раздел — как нажатие на вкладку (повторное: к корню, в корне — наверх), часть
    /// Библиотеки и плейлист — открываются корнем стека раздела «Библиотека».
    func selectSidebar(_ item: SidebarItem) {
        switch item {
        case .section(let section): select(section)
        case .shortcut(let shortcut): openInLibrary(shortcut.route)
        case .playlist(let id): openInLibrary(.localPlaylist(id))
        }
    }

    private func openInLibrary(_ route: Route) {
        section = .library
        routes[.library] = [route]
    }
}

/// Боковая панель Mac и iPad (docs/PROMPT.md §5.3, §5.4), секциями, как в Music.app: пять разделов (⌘1…⌘5) без заголовка,
/// затем «Библиотека» — её части, затем «Плейлисты» — свои плейлисты и «Новый плейлист». Секции сворачиваются, состояние
/// помнится. Подсвеченной остаётся строка, из которой открыт экран (Избранное → альбом): назад — «Назад», ⌘[ и Esc.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.library.expanded") private var libraryExpanded = true
    @AppStorage("sidebar.playlists.expanded") private var playlistsExpanded = true
    @State private var playlists: [LibraryPlaylist] = []

    var body: some View {
        let library = model.library
        let visible = playlists.filter { !model.isHidden(PendingKey.playlist($0.id)) }
        List(selection: Binding(get: { Optional(model.sidebarSelection) }, set: { if let item = $0 { model.selectSidebar(item) } })) {
            ForEach(AppSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(SidebarItem.section(section))
                    .accessibilityIdentifier("sidebar.\(section.rawValue)")
            }
            Section(isExpanded: $libraryExpanded) {
                ForEach(LibraryShortcut.allCases, id: \.self) { shortcut in
                    Label(shortcut.title, systemImage: shortcut.systemImage)
                        .tag(SidebarItem.shortcut(shortcut))
                }
            } header: {
                Text("section.library")
            }
            Section(isExpanded: $playlistsExpanded) {
                ForEach(visible) { playlist in
                    Label { Text(verbatim: playlist.name).lineLimit(1) } icon: { Image(systemName: "music.note.list") }
                        .tag(SidebarItem.playlist(playlist.id))
                        .contextMenu { PlaylistMenuItems(playlist: playlist) }
                        .accessibilityValue(Text("library.tracks \(playlist.trackCount)"))
                }
                if library != nil {
                    Button { model.newPlaylistPrompt = true } label: {
                        Label("library.newPlaylist", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.newPlaylist")
                }
            } header: {
                Text("library.playlists")
            }
        }
        .playerBarClearance()
        .listStyle(.sidebar)
        .task(id: library?.revision) {
            playlists = library?.library.playlists() ?? []
        }
    }
}
