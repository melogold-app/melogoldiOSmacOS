import SwiftUI
import MelogoldCore
import MelogoldInnerTube
import MelogoldData

/// «Поиск» (REWRITE §3.1). На iPhone поле встаёт в панель вкладок (вкладка поиска iOS 26), на iPad с боковой панелью
/// и на Mac — вверху раздела; ⌘F и повторное нажатие на «Поиск» ставят в него курсор.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        @Bindable var search = model.search
        SearchContent()
            .navigationTitle(Text(AppSection.search.title))
            .searchable(text: $model.searchQuery, prompt: Text("search.prompt"))
            .searchScopes($search.scope, activation: .onSearchPresentation) {
                ForEach(SearchModel.Scope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .searchSuggestions {
                if let title = YouTubeLinkParser.parse(model.searchQuery).openTitle {
                    Button {
                        model.openLink(model.searchQuery)
                    } label: {
                        Label(title, systemImage: "link")
                    }
                }
                // «В библиотеке» — свои треки по вводу (REWRITE §3.1.2): нажатие — трек и радио.
                ForEach(model.library?.library.search(model.searchQuery, limit: 3) ?? []) { track in
                    Button {
                        model.play(single: track)
                    } label: {
                        TrackRow(track: track, subtitle: [String(localized: "search.inLibrary"), track.artistsText].compactMap { $0 }.joined(separator: " · "))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(search.suggestions, id: \.self) { suggestion in
                    Button {
                        model.searchQuery = suggestion
                        search.submit(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "magnifyingglass")
                    }
                    .searchCompletion(suggestion)
                }
            }
            .onSubmit(of: .search) { submit() }
            .onChange(of: model.searchQuery) { _, text in search.queryChanged(text) }
            .searchFocused($focused)
            .onChange(of: model.searchFocusRequest) { focused = true }
            .onChange(of: focused) { _, value in model.textInputActive = value }
            .onAppear { if model.searchFocusRequest > 0 { focused = true } }
    }

    /// Enter: ссылка YouTube открывает свою цель (REWRITE §2.3), остальное — поиск.
    private func submit() {
        if YouTubeLinkParser.parse(model.searchQuery).openTitle != nil {
            model.openLink(model.searchQuery)
        } else {
            model.search.submit(model.searchQuery)
        }
    }
}

/// «Вставить ссылку» — системная `PasteButton`: буфер читается только по нажатию и без вопроса «Разрешить
/// вставку» (docs/PROMPT.md §5.9).
private struct PasteLinkButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            Task { @MainActor in model.openLink(text) }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
    }
}

/// Корень (недавние запросы) или выдача запроса.
private struct SearchContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        if search.submitted != nil {
            SearchResultsView()
        } else {
            SearchRootView()
        }
    }
}

/// Корень Поиска: недавние запросы; пусто — подсказка про два источника (REWRITE §3.1.1).
private struct SearchRootView: View {
    @Environment(AppModel.self) private var model
    @State private var recentPlays: [HistoryEntry] = []

    var body: some View {
        let search = model.search
        Group {
            if search.recent.isEmpty, recentPlays.isEmpty {
                ContentUnavailableView {
                    Label(AppSection.search.title, systemImage: AppSection.search.systemImage)
                } description: {
                    Text(model.settings.historyPaused ? "search.historyPaused" : "search.tip")
                } actions: {
                    PasteLinkButton()
                }
            } else {
                List {
                    Section {
                        PasteLinkButton()
                            .listRowSeparator(.hidden)
                    }
                    if !search.recent.isEmpty {
                        Section {
                            ForEach(search.recent, id: \.self) { query in
                                Button {
                                    model.searchQuery = query
                                    search.submit(query)
                                } label: {
                                    Label(query, systemImage: "clock.arrow.circlepath")
                                        .foregroundStyle(.primary)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { search.removeRecent(query) } label: {
                                        Label("search.removeRecent", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) { search.removeRecent(query) } label: {
                                        Label("search.removeRecent", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("search.recent")
                                Spacer()
                                Button("search.clearRecent") { search.clearRecent() }
                                    .font(.subheadline)
                            }
                        }
                    }
                    RecentlyPlayedSection(entries: recentPlays)
                }
            }
        }
        .task(id: model.library?.revision) {
            recentPlays = model.settings.historyPaused ? [] : model.library?.library.recentHistory(limit: 10) ?? []
        }
    }
}

/// Выдача: «Всё» — две секции; «Музыка» и «YouTube» — фильтр и бесконечный список (REWRITE §3.1.3).
private struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        switch search.scope {
        case .all:
            AllResultsList()
        case .music:
            PagedResultsList(state: search.music) {
                FilterChips(options: MusicSearchFilter.shown, selection: Binding(get: { search.musicFilter }, set: { search.musicFilter = $0 })) { $0.title }
            }
        case .youtube:
            PagedResultsList(state: search.web) {
                FilterChips(options: WebSearchFilter.shown, selection: Binding(get: { search.webFilter }, set: { search.webFilter = $0 })) { $0.title }
            }
        }
    }
}

/// «Всё»: секция YouTube Music (лучший результат и до 4 строк, «Ещё ›») и секция YouTube (до 4 видео, «Ещё ›»).
/// Если каталог ничего не нашёл — YouTube первым с пояснением.
private struct AllResultsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        let all = search.all
        let musicEmpty = (all.music.value?.isEmpty ?? false) && all.top == nil
        if case .failed(let kind) = all.music, case .failed = all.videos {
            ErrorStateView(kind: kind) { search.retry() }
        } else if musicEmpty, all.videos.value?.isEmpty == true {
            ContentUnavailableView {
                Label("search.nothingFound", systemImage: "magnifyingglass")
            }
        } else {
            SelectableList(target: target) {
                if musicEmpty {
                    Section {
                        videosRows(all.videos)
                    } header: {
                        sectionHeader("YouTube", more: .youtube)
                    } footer: {
                        Text("search.onlyYouTube")
                    }
                } else {
                    Section {
                        if let top = all.top { ItemRow(item: top).tag(RowID.make("top", top.id)) }
                        switch all.music {
                        case .loaded(let items):
                            ForEach(items) { ItemRow(item: $0).tag(RowID.make("m", $0.id)) }
                        case .failed:
                            UnavailableSourceRow(source: "YouTube Music") { search.retry() }
                        default:
                            ProgressRow()
                        }
                    } header: {
                        sectionHeader("YouTube Music", more: .music)
                    }
                    Section {
                        videosRows(all.videos)
                    } header: {
                        sectionHeader("YouTube", more: .youtube)
                    }
                }
            }
        }
    }

    private func target(_ id: String) -> RowTarget? {
        guard let (section, key) = RowID.split(id) else { return nil }
        let all = model.search.all
        switch section {
        case "top": return all.top.flatMap(RowTarget.of)
        case "m": return all.music.value?.first { $0.id == key }.flatMap(RowTarget.of)
        case "v": return all.videos.value?.first { $0.videoId == key }.map(RowTarget.single)
        default: return nil
        }
    }

    @ViewBuilder
    private func videosRows(_ state: Loadable<[Track]>) -> some View {
        switch state {
        case .loaded(let videos):
            ForEach(videos) { ItemRow(item: .track($0), wide: true).tag(RowID.make("v", $0.videoId)) }
        case .failed:
            UnavailableSourceRow(source: "YouTube") { model.search.retry() }
        default:
            ProgressRow()
        }
    }

    private func sectionHeader(_ title: String, more scope: SearchModel.Scope) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            Button {
                model.search.scope = scope
            } label: {
                Text("common.more")
            }
            .font(.subheadline)
        }
    }
}

/// Список области «Музыка» или «YouTube» с продолжениями.
private struct PagedResultsList<Chips: View>: View {
    @Environment(AppModel.self) private var model
    let state: SearchModel.Paged
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        SelectableList(target: { id in
            guard let (_, key) = RowID.split(id) else { return nil }
            return state.items.first { $0.id == key }.flatMap(RowTarget.of)
        }) {
            Section {
                switch state.state {
                case .failed(let kind):
                    ErrorStateView(kind: kind) { model.search.retry() }
                        .listRowSeparator(.hidden)
                case .loaded where state.items.isEmpty:
                    ContentUnavailableView { Label("search.nothingFound", systemImage: "magnifyingglass") }
                        .listRowSeparator(.hidden)
                case .loaded:
                    ForEach(state.items) { item in
                        ItemRow(item: item, wide: model.search.scope == .youtube)
                            .tag(RowID.make("p", item.id))
                            .onAppear { model.search.loadMoreIfNeeded(after: item) }
                    }
                    if state.loadingMore { ProgressRow() }
                default:
                    ProgressRow()
                }
            } header: {
                chips()
            }
        }
    }
}

/// Ряд фильтров внутри области: одиночный выбор.
private struct FilterChips<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> LocalizedStringResource

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(title(option))
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .accentColor : .secondary)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        .textCase(nil)
    }
}

/// Строка выдачи. Трек или видео играет «одиночный трек + радио» (REWRITE §2.3), коллекция открывает свой экран —
/// действие даёт `rowActions` списка.
struct ItemRow: View {
    let item: MusicItem
    var wide = false

    var body: some View {
        switch item {
        case .track(let track):
            TrackListRow(track: track, wide: wide, target: .single(track))
        default:
            TapTarget(target: RowTarget.of(item)) {
                CollectionRow(item: item)
            }
        }
    }
}

struct ProgressRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .listRowSeparator(.hidden)
    }
}

/// Упал один источник — второй показывается как есть, на месте упавшего «YouTube недоступен · Повторить».
private struct UnavailableSourceRow: View {
    let source: String
    let retry: () -> Void

    var body: some View {
        HStack {
            Text("search.sourceUnavailable \(source)")
                .foregroundStyle(.secondary)
            Spacer()
            Button("common.retry", action: retry)
        }
    }
}

/// «Недавно игравшие» в корне Поиска (REWRITE §3.1.1): последние 10 треков, нажатие — трек и радио.
private struct RecentlyPlayedSection: View {
    let entries: [HistoryEntry]

    var body: some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries, id: \.track.id) { entry in
                    TrackListRow(track: entry.track, target: .single(entry.track), context: .history)
                }
            } header: {
                Text("search.recentlyPlayed")
            }
        }
    }
}
