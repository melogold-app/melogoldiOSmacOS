import SwiftUI
import MelogoldCore

/// iPad в широком окне и Mac: `NavigationSplitView` — те же пять разделов (и части Библиотеки, плейлисты) в боковой панели и одна
/// `NavigationStack` на всю колонку детали (грабли §9 п. 18: без неё у открытой страницы нет «Назад»,
/// а свой стек в каждом разделе рисует второй заголовок). Стек текущего раздела берётся из модели,
/// поэтому при переключении разделов он сохраняется.
struct SplitShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            // Секции и плейлисты, как в Music.app (`Sidebar`); на iPad та же панель
            Sidebar()
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            #else
            .navigationTitle(Text(verbatim: "Melogold"))
            #endif
        } detail: {
            NavigationStack(path: model.path(for: model.section)) {
                // iPad: мини-плеер — полоса внизу колонки детали (docs/PROMPT.md §5.3); ставит её каждый экран стека.
                SectionRoot(section: model.section, miniPlayerBar: true)
            }
            .id(model.section)
            #if !os(visionOS)
            // Очередь — колонка справа (docs/PROMPT.md §5.4, iPad — §5.3).
            // Пока открыт «Сейчас играет», колонка очереди — его собственная: окно под ним не перестраивается (иначе SwiftUI
            // возвращает в панель окна скрытые название и кнопки)
            .inspector(isPresented: Binding(get: { model.queueVisible && !model.showNowPlaying }, set: { model.queueVisible = $0 })) {
                QueueView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
            #endif
            #if os(macOS)
            // Esc: сначала «Сейчас играет», потом шаг назад в стеке раздела (docs/PROMPT.md §5.4)
            .onExitCommand {
                if model.showNowPlaying { model.showNowPlaying = false } else { model.goBack() }
            }
            #endif
        }
        #if os(macOS)
        // Панель воспроизведения — плавающее стекло внизу окна во всю ширину; боковая панель и колонка детали
        // заканчиваются над ней, содержимое уходит под неё с мягким затуханием
        .safeAreaBar(edge: .bottom, spacing: 0) {
            MacPlayerBar()
        }
        // «Сейчас играет» — слой поверх окна; пока он открыт, панель инструментов окна (поле поиска, заголовок раздела)
        // скрыта (`NowPlayingChrome`), чтобы не спорить с ним, а кнопки окна остаются
        .overlay {
            if model.showNowPlaying {
                NowPlayingView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.showNowPlaying)
        // Пробел и ⌘A не мешают вводу текста: курсор в поле — из AppKit, а не из флага самого поля
        .background { TextInputWatcher(model: model) }
        #else
        // iPad: лист во всю высоту с системным grabber, закрывается смахиванием вниз
        .sheet(isPresented: $model.showNowPlaying) {
            NowPlayingView()
        }
        #endif
        .overlay(alignment: .bottom) {
            ToastHost()
                .padding(.bottom, 90)
        }
        // ⌘N и «Новый плейлист» в боковой панели: название и открытие созданного в Библиотеке
        .newPlaylistAlert(isPresented: $model.newPlaylistPrompt) { id in model.selectSidebar(.playlist(id)) }
    }
}

/// Полоса мини-плеера на системном стекле внизу экрана (iPad с боковой панелью). Ставится на каждый экран стека:
/// полоса, повешенная на сам `NavigationStack`, у открытых экранов пропадает.
struct MiniPlayerBar: ViewModifier {
    @Environment(AppModel.self) private var model
    let enabled: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled {
            content.safeAreaBar(edge: .bottom) {
                if model.services.player.currentTrack != nil {
                    MiniPlayer()
                        .padding(.vertical, 8)
                        .controlGlass(Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// Поле поиска в панели инструментов корня каждого раздела, как у Music.app: справа, на одном месте. Щелчок по нему
/// открывает раздел «Поиск» (в нём то же поле — `SearchView`, с областями, подсказками и фокусом) с курсором в поле, как
/// ⌘F (docs/PROMPT.md §5.4). В самом «Поиске», на экранах со своим фильтром и на открытых страницах (альбом, плейлист) в
/// панели их собственные кнопки.
struct ToolbarSearchField: ViewModifier {
    let section: AppSection
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        @Bindable var model = model
        if section == .search {
            content
        } else {
            content
                .searchable(text: $model.searchQuery, placement: .toolbar, prompt: Text("search.prompt"))
                .searchFocused($focused)
                .onChange(of: focused) { _, isFocused in if isFocused { model.focusSearch() } }
        }
    }
}
#endif
