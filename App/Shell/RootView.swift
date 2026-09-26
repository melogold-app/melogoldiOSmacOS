import SwiftUI
import MelogoldCore

/// Корень окна: iPhone и Vision — вкладки; iPad в широком окне и Mac — боковая панель (docs/PROMPT.md §5.2–§5.5).
/// В узком окне iPad (Split View, Slide Over) — как на iPhone.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var renameText = ""
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        shell
            .onOpenURL { model.handle(url: $0) }
            // Ссылку YouTube можно перетащить в окно (Mac, iPad) — она открывается, как вставленная в Поиске.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.openLink(url.absoluteString)
                return true
            }
            #if DEBUG
            .task {
                DebugLaunch.apply(to: model)
                DebugBenchmark.runIfRequested(model)
            }
            #endif
            .alert(
                model.notice.map { Text($0.title) } ?? Text(verbatim: ""),
                isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
                presenting: model.notice
            ) { _ in
                Button("common.ok") { model.notice = nil }
            } message: { notice in
                if let message = notice.message { Text(message) }
            }
            .sheet(item: $model.playlistPicker) { request in
                PlaylistPickerSheet(request: request)
            }
            .alert(Text("playlist.rename"), isPresented: Binding(get: { model.renameRequest != nil },
                                                                 set: { if !$0 { model.renameRequest = nil } })) {
                TextField(text: $renameText) { Text("playlist.name") }
                Button("common.cancel", role: .cancel) { model.renameRequest = nil }
                Button("common.save") {
                    if let playlist = model.renameRequest { model.library?.library.renamePlaylist(playlist.id, to: renameText) }
                    model.renameRequest = nil
                }
            }
            .onChange(of: model.renameRequest?.id) { renameText = model.renameRequest?.name ?? "" }
            #if !os(macOS)
            .fileExporter(isPresented: Binding(get: { model.exportedFile != nil }, set: { if !$0 { model.exportedFile = nil } }),
                          document: model.exportedFile, contentType: .mpeg4Audio,
                          defaultFilename: model.exportedFile?.url.deletingPathExtension().lastPathComponent) { result in
                if case .success = result { model.toast = Toast(text: String(localized: "export.saved")) }
                model.exportedFile = nil
            }
            #endif
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { model.undoManager = undoManager }
            .onChange(of: scenePhase) { _, phase in
                // Уход в фон: отложенное выполняется сразу, очередь сохраняется (docs/PROMPT.md §5.10, §4).
                if phase != .active {
                    model.commitPending()
                    model.services.queueKeeper?.save()
                }
            }
    }

    @ViewBuilder
    private var shell: some View {
        #if os(macOS)
        SplitShell()
        #elseif os(visionOS)
        TabShell()
        #else
        if UIDevice.current.userInterfaceIdiom == .pad, horizontalSizeClass == .regular {
            SplitShell()
        } else {
            TabShell()
        }
        #endif
    }
}

/// Корневой экран раздела и детальные экраны его стека.
struct SectionRoot: View {
    let section: AppSection
    /// iPad с боковой панелью: полоса мини-плеера на каждом экране стека.
    var miniPlayerBar = false

    var body: some View {
        content
            .modifier(MiniPlayerBar(enabled: miniPlayerBar))
            .navigationDestination(for: Route.self) { [miniPlayerBar] in
                RouteView(route: $0).modifier(MiniPlayerBar(enabled: miniPlayerBar))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .trends: TrendsView()
        case .new: NewView()
        case .library: LibraryView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .server(let prefill, let serverId):
            ServerView(prefill: prefill, expectedServerId: serverId)
        case .account(let route):
            AccountRouteView(route: route)
        case .album(let browseId):
            AlbumView(browseId: browseId)
        case .artist(let browseId):
            ArtistView(browseId: browseId)
        case .playlist(let playlistId):
            PlaylistView(playlistId: playlistId)
        case .mood(let mood):
            MoodView(mood: mood)
        case .moods:
            MoodsView()
        case .newReleases:
            NewReleasesView()
        case .browse(let title, let browseId, let params):
            BrowseView(title: title, browseId: browseId, params: params)
        case .favorites:
            FavoritesView()
        case .allTracks:
            AllTracksView()
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .playlists:
            PlaylistsView()
        case .savedAlbums:
            SavedAlbumsView()
        case .savedArtists:
            SavedArtistsView()
        case .localPlaylist(let id):
            LocalPlaylistView(playlistId: id)
        case .hiddenTracks:
            HiddenTracksView()
        }
    }
}
