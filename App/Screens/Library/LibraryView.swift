import SwiftUI
import MelogoldCore
import MelogoldData

/// «Библиотека» — хаб (REWRITE §3.2.1, docs/PROMPT.md §5.9): Избранное, Скачанное, История — плитки; «Плейлисты» —
/// адаптивная сетка обложек (на iPhone две колонки, на iPad и Mac столько, сколько влезет); «Все треки» (задание 0007),
/// Альбомы, Исполнители и каналы, «Итоги» — список; последняя строка — «Импорт из ViTune или ViMusic» (задание 0006).
/// Значки одного цвета — системного акцента (у ♡ — розовый, как сердце везде); сети экран не требует.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var playlists: [LibraryPlaylist] = []
    @State private var newPlaylist = false
    @State private var hasHistory = false

    /// Сколько плейлистов показано на хабе; остальные — на «Все плейлисты».
    private static let shownPlaylists = 5

    var body: some View {
        let library = model.library
        let counts = library?.counts ?? LibraryCounts()
        let visible = playlists.filter { !model.isHidden(PendingKey.playlist($0.id)) }
        let isEmpty = counts.likes == 0 && counts.playlists == 0 && counts.albums == 0 && counts.artists == 0
            && counts.allTracks == 0 && counts.downloads == 0 && !hasHistory
        List {
            Section {
                tiles(counts)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            // С 1 декабря по 31 января — «Итоги 2026 готовы» (задание 0018)
            if let year = wrappedSeasonYear(), hasHistory {
                Section {
                    Button { model.wrappedYear = year } label: {
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("stats.wrapped.ready \(String(year))").font(.headline)
                                Text("stats.wrapped.readyText").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.wrappedReady")
                }
            }
            if isEmpty {
                // Пустая библиотека: подсказка на фоне экрана, а не в карточке списка
                Section {
                    ContentUnavailableView {
                        Label("library.empty.title", systemImage: "music.note.square.stack")
                    } description: {
                        Text("library.empty.message")
                    } actions: {
                        Button("library.findMusic") { model.focusSearch() }
                            .buttonStyle(.borderedProminent)
                        Button("new.forYou.trends") { model.select(.trends) }
                        Button("import.fromViTune") { model.chooseBackupToImport() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                // Заголовок — строкой списка, а не заголовком секции: у системного отступ шире полей плиток
                ShelfHeader(title: Text("library.playlists"), more: visible.count > Self.shownPlaylists ? .playlists : nil,
                            moreTitle: "library.seeAllCount \(visible.count)")
                    .listRowInsets(EdgeInsets(top: Design.Space.xs, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                playlistGrid(visible)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
                NavigationLink(value: Route.stats) {
                    Label("stats.title", systemImage: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("library.stats")
            }
            // Последняя строка — импорт из ViTune или ViMusic (задание 0006); пояснение — подписью под группой
            Section {
                Button {
                    model.chooseBackupToImport()
                } label: {
                    Label("import.fromViTune", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("library.import")
            } footer: {
                Text("import.fromViTune.description")
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

    /// Плитки коллекций: Избранное, Скачанное, История — три колонки до 240 pt (на iPad и Mac плитки не растягиваются на
    /// всё окно и не сжимаются до значка); на крупном шрифте — по одной в строку.
    private func tiles(_ counts: LibraryCounts) -> some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12)]
            : Array(repeating: GridItem(.flexible(minimum: 96, maximum: 240), spacing: 12, alignment: .top), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            tile("library.favorites", systemImage: "heart.fill", tint: .pink, count: counts.likes, route: .favorites)
            tile("library.downloads", systemImage: "arrow.down.circle.fill", tint: .accentColor, count: counts.downloads, route: .downloads)
            tile("library.history", systemImage: "clock.arrow.circlepath", tint: .accentColor, count: nil, route: .history)
        }
    }

    private func tile(_ title: LocalizedStringResource, systemImage: String, tint: Color, count: Int?, route: Route) -> some View {
        Button {
            model.open(route)
        } label: {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.8)
                Text(verbatim: count.map { "\($0)" } ?? " ")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(Design.Space.s)
            .background(CardBackground.color, in: RoundedRectangle(cornerRadius: Design.Layout.tileRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Design.Layout.tileRadius, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
    }

    /// «Плейлисты»: «Новый плейлист» первой плиткой и обложки своих плейлистов крупно; на хабе — не больше пяти.
    private func playlistGrid(_ visible: [LibraryPlaylist]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
            NewPlaylistTile { newPlaylist = true }
            ForEach(visible.prefix(Self.shownPlaylists)) { playlist in
                PlaylistCard(playlist: playlist)
            }
        }
    }

    private func countRow(_ title: LocalizedStringResource, systemImage: String, count: Int) -> some View {
        LabeledContent {
            Text(verbatim: "\(count)").monospacedDigit()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Карточка своего плейлиста в сетке: обложка (мозаика из четырёх) во всю ширину колонки, название, «42 трека» и метка
/// связи с YouTube.
struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let playlist: LibraryPlaylist

    var body: some View {
        Button {
            model.open(.localPlaylist(playlist.id))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                SquareFill { side in PlaylistArtwork(playlist: playlist, size: side) }
                    .padding(.bottom, Design.Space.xxs)
                HStack(spacing: Design.Space.xxs) {
                    Text(verbatim: playlist.name)
                        .font(.subheadline)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    if model.services.downloads?.store.isCollection(.playlist, key: String(playlist.id)) == true {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("badge.downloaded"))
                    }
                }
                HStack(spacing: Design.Space.xxs) {
                    Text("library.tracks \(playlist.trackCount)")
                    switch playlist.link {
                    case .mirror, .append, .unknown:
                        Image(systemName: "link")
                    case .none, .off:
                        EmptyView()
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .contextMenu { PlaylistMenuItems(playlist: playlist) }
        .accessibilityElement(children: .combine)
    }
}

/// Первая плитка сетки плейлистов: «Новый плейлист».
struct NewPlaylistTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                SquareFill { side in
                    ZStack {
                        RoundedRectangle(cornerRadius: Design.Radius.artwork(side), style: .continuous)
                            .fill(.fill.tertiary)
                        Image(systemName: "plus")
                            .font(.system(size: side * 0.28, weight: .light))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.bottom, Design.Space.xxs)
                Text("library.newPlaylist")
                    .font(.subheadline)
                    .lineLimit(1)
                // Высоту второй подписи держит пустая строка: плитка не ниже соседних карточек
                Text(verbatim: " ").font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
    }
}

/// Квадрат во всю предложенную ширину: содержимое узнаёт сторону (обложки задаются размером в pt).
struct SquareFill<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { GeometryReader { content($0.size.width) } }
    }
}

/// Строка своего плейлиста: мозаика, название, «42 трека», метка связи с YouTube (REWRITE §3.2.5).
struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let playlist: LibraryPlaylist

    var body: some View {
        HStack(spacing: Design.Space.s) {
            PlaylistArtwork(playlist: playlist, size: Design.Layout.rowArtwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: playlist.name).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
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
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            .rowSeparatorAtText()
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
        // На белом окне Mac `controlBackgroundColor` сливается с фоном — плитки библиотеки были невидимы
        Color(nsColor: .quaternarySystemFill)
        #else
        Color.secondary.opacity(0.15)
        #endif
    }
}
