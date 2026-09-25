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
                SectionRoot(section: model.section)
            }
            .id(model.section)
            #if os(iOS)
            // iPad: мини-плеер — полоса внизу колонки детали на системном стекле (docs/PROMPT.md §5.3).
            .safeAreaBar(edge: .bottom) {
                if model.services.player.currentTrack != nil {
                    MiniPlayer()
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            #elseif os(macOS)
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
            SkipNoticeOverlay()
                .padding(.bottom, 90)
                .animation(.snappy, value: model.services.player.notice)
        }
    }
}
