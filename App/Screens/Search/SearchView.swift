import SwiftUI
import MelogoldCore
import MelogoldInnerTube

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
            .onSubmit(of: .search) { search.submit(model.searchQuery) }
            .onChange(of: model.searchQuery) { _, text in search.queryChanged(text) }
            .searchFocused($focused)
            .onChange(of: model.searchFocusRequest) { focused = true }
            .onChange(of: focused) { _, value in model.textInputActive = value }
            .onAppear { if model.searchFocusRequest > 0 { focused = true } }
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

    var body: some View {
        let search = model.search
        if search.recent.isEmpty {
            ContentUnavailableView {
                Label(AppSection.search.title, systemImage: AppSection.search.systemImage)
            } description: {
                Text(model.settings.historyPaused ? "search.historyPaused" : "search.tip")
            }
        } else {
            List {
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
            List {
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
                        if let top = all.top { ItemRow(item: top) }
                        switch all.music {
                        case .loaded(let items):
                            ForEach(items) { ItemRow(item: $0) }
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

    @ViewBuilder
    private func videosRows(_ state: Loadable<[Track]>) -> some View {
        switch state {
        case .loaded(let videos):
            ForEach(videos) { ItemRow(item: .track($0), wide: true) }
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
        List {
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

/// Строка выдачи: трек или видео играет «одиночный трек + радио» (REWRITE §2.3), коллекции открываются в срезе 3.
struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: MusicItem
    var wide = false

    var body: some View {
        switch item {
        case .track(let track):
            let player = model.services.player
            let isCurrent = player.currentTrack?.videoId == track.videoId
            let cached = model.cachedIds.contains(track.videoId)
            let dimmed = !model.services.network.isOnline && !cached
            Button {
                model.play(single: track)
            } label: {
                if wide {
                    VideoRow(track: track, isCurrent: isCurrent, dimmed: dimmed)
                } else {
                    TrackRow(track: track, isCurrent: isCurrent, cached: cached, dimmed: dimmed)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAction(named: Text("action.play")) { model.play(single: track) }
        default:
            CollectionRow(item: item)
        }
    }
}

private struct ProgressRow: View {
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
