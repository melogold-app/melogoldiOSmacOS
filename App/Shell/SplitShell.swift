import SwiftUI
import MelogoldCore

/// iPad в широком окне и Mac: `NavigationSplitView` — те же пять разделов в боковой панели и одна
/// `NavigationStack` на всю колонку детали (грабли §9 п. 18: без неё у открытой страницы нет «Назад»,
/// а свой стек в каждом разделе рисует второй заголовок). Стек текущего раздела берётся из модели,
/// поэтому при переключении разделов он сохраняется.
struct SplitShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.section) }, set: { if let section = $0 { model.select(section) } })) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
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
            .inspector(isPresented: $model.queueVisible) {
                QueueView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
            #endif
            #if os(macOS)
            .onExitCommand { model.goBack() }
            #endif
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacPlayerBar()
        }
        .overlay {
            if model.showNowPlaying {
                NowPlayingView()
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy, value: model.showNowPlaying)
        #else
        .fullScreenCover(isPresented: $model.showNowPlaying) {
            NowPlayingView()
        }
        #endif
        .overlay(alignment: .bottom) {
            ToastHost()
                .padding(.bottom, 90)
        }
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
                        .glassEffect(.regular, in: .capsule)
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
