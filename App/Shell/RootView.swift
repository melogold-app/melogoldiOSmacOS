import SwiftUI
import MelogoldCore

/// Корень окна: iPhone и Vision — вкладки; iPad в широком окне и Mac — боковая панель (docs/PROMPT.md §5.2–§5.5).
/// В узком окне iPad (Split View, Slide Over) — как на iPhone.
struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        shell
            .onOpenURL { model.handle(url: $0) }
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

    var body: some View {
        content
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
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
        }
    }
}
