import SwiftUI
import MelogoldCore
import MelogoldData

/// Melogold для Apple Watch — самостоятельное приложение (docs/PROMPT.md §5.6): свой вход, поиск, поток,
/// загрузки и синк, без iPhone. Код правил, сети и данных — общий, из MelogoldKit; интерфейс — свой, по HIG watchOS.
@main
struct MelogoldWatchApp: App {
    @State private var model: WatchModel

    init() {
        let paths: AppPaths?
        do {
            let standard = try AppPaths.standard()
            try standard.prepare()
            paths = standard
        } catch {
            paths = nil
        }
        if let paths { Log.configure(directory: paths.logs) }
        Log.info("app", "Melogold для часов \(AppVersion.current) (\(AppVersion.build)) запущен")
        _model = State(initialValue: WatchModel(settings: AppSettings(), paths: paths))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
        }
    }
}

/// Состояние приложения часов.
@MainActor
@Observable
final class WatchModel {
    let settings: AppSettings
    let paths: AppPaths?
    var path: [AppSection] = []

    init(settings: AppSettings, paths: AppPaths?) {
        self.settings = settings
        self.paths = paths
    }
}
