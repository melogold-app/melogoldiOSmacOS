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
        if let paths {
            Log.configure(directory: paths.logs)
            ArtworkSession.configure(directory: paths.artwork)
        }
        #if DEBUG
        HTTPConfiguration.setDebugProxy(UserDefaults.standard.string(forKey: "MelogoldDebugProxy"))
        #endif
        Log.info("app", "Melogold для часов \(AppVersion.current) (\(AppVersion.build)) запущен")
        _model = State(initialValue: WatchModel(services: Services(settings: AppSettings(), paths: paths)))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                #if DEBUG
                .task {
                    if let query = UserDefaults.standard.string(forKey: "MelogoldSearch") {
                        model.pendingQuery = query
                        model.path = [.section(.search)]
                    }
                }
                #endif
        }
    }
}

/// Куда ведёт строка корня часов.
enum WatchRoute: Hashable {
    case section(AppSection)
    case nowPlaying
}

/// Состояние приложения часов.
@MainActor
@Observable
final class WatchModel {
    let services: Services
    var path: [WatchRoute] = []
    /// Запрос, который Поиск выполнит при открытии (отладочный запуск `-MelogoldSearch`).
    var pendingQuery: String?

    var settings: AppSettings { services.settings }

    init(services: Services) {
        self.services = services
    }

    /// Нажатие по треку: играет по правилу очереди и открывает «Сейчас играет» — мини-плеера на часах нет (§5.6).
    func play(single track: Track) {
        services.player.playSingle(track)
        path.append(.nowPlaying)
    }
}
