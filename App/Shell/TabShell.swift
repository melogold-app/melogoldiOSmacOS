import SwiftUI
import MelogoldCore

/// iPhone, Vision и узкое окно iPad: `TabView` с пятью разделами, у каждого свой `NavigationStack`.
/// «Поиск» — `Tab(role: .search)`: в iOS 26 система сама выносит его отдельной кнопкой к правому краю,
/// на visionOS разделы — вертикальный орнамент у левого края окна.
struct TabShell: View {
    @Environment(AppModel.self) private var model
    @Namespace private var playerNamespace

    var body: some View {
        @Bindable var model = model
        let hasTrack = model.services.player.currentTrack != nil
        TabView(selection: Binding(get: { model.section }, set: { model.select($0) })) {
            Tab(value: AppSection.trends) {
                SectionStack(section: .trends)
            } label: {
                Label(AppSection.trends.title, systemImage: AppSection.trends.systemImage)
            }
            Tab(value: AppSection.new) {
                SectionStack(section: .new)
            } label: {
                Label(AppSection.new.title, systemImage: AppSection.new.systemImage)
            }
            Tab(value: AppSection.library) {
                SectionStack(section: .library)
            } label: {
                Label(AppSection.library.title, systemImage: AppSection.library.systemImage)
            }
            Tab(value: AppSection.search, role: .search) {
                SectionStack(section: .search)
            } label: {
                Label(AppSection.search.title, systemImage: AppSection.search.systemImage)
            }
            Tab(value: AppSection.settings) {
                SectionStack(section: .settings)
            } label: {
                Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
            }
        }
        // Вкладка поиска iOS 26: при выборе поле встаёт в панель вкладок внизу экрана, где до него дотягивается
        // большой палец (HIG «Search fields»). Само поле — у раздела «Поиск» (`SearchView`), не у TabView:
        // иначе оно появляется в каждом разделе.
        #if os(iOS)
        .tabViewSearchActivation(.searchTabSelection)
        .modifier(MiniPlayerAccessory(hasTrack: hasTrack, namespace: playerNamespace))
        .fullScreenCover(isPresented: $model.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "nowPlaying", in: playerNamespace))
        }
        #elseif os(visionOS)
        .ornament(visibility: hasTrack ? .visible : .hidden, attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            MiniPlayer()
                .frame(width: 420)
                .padding(.vertical, 10)
                .glassBackgroundEffect()
        }
        .sheet(isPresented: $model.showNowPlaying) {
            NowPlayingView().frame(minWidth: 640, minHeight: 480)
        }
        #endif
        .overlay(alignment: .bottom) {
            SkipNoticeOverlay()
                .padding(.bottom, hasTrack ? 120 : 60)
                .animation(.snappy, value: model.services.player.notice)
        }
    }
}

#if os(iOS)
/// Мини-плеер в `tabViewBottomAccessory`. Скрыть аксессуар без трека можно с iOS 26.1 (`isEnabled`);
/// на 26.0 он показывается пустым только до первого трека.
private struct MiniPlayerAccessory: ViewModifier {
    let hasTrack: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: hasTrack) {
                MiniPlayer().matchedTransitionSource(id: "nowPlaying", in: namespace)
            }
        } else {
            content.tabViewBottomAccessory {
                MiniPlayer().matchedTransitionSource(id: "nowPlaying", in: namespace)
            }
        }
    }
}
#endif

/// Стек раздела на iPhone и Vision.
struct SectionStack: View {
    let section: AppSection
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: model.path(for: section)) {
            SectionRoot(section: section)
        }
    }
}
