import AppIntents
import MelogoldCore

/// Ярлыки приложения (как «ярлыки» значка на Android, REWRITE §3.13): поиск, Избранное, «Перемешать Избранное»,
/// Скачанное — и управление плеером. Одни и те же действия — в приложении «Команды» и Spotlight (`App Shortcuts`), у Siri и
/// в меню значка в Dock (`MacAppDelegate`).
enum ShortcutAction {
    case search, favorites, downloads, shuffleFavorites, playPause, next, previous
}

extension AppModel {
    func perform(_ action: ShortcutAction) {
        switch action {
        case .search:
            focusSearch()
        case .favorites:
            selectSidebar(.shortcut(.favorites))
        case .downloads:
            selectSidebar(.shortcut(.downloads))
        case .shuffleFavorites:
            // Без открытия экрана: играет перемешанное Избранное, как ярлык Android
            playAll(library?.library.favorites() ?? [], shuffled: true)
        case .playPause:
            togglePlayback()
        case .next:
            playbackNext()
        case .previous:
            playbackPrevious()
        }
    }
}

/// Команда из ярлыка: приложение уже запущено (команды выполняются в его процессе), модель окна — `AppModel.current`.
@MainActor
private func run(_ action: ShortcutAction) {
    AppModel.current?.perform(action)
}

struct OpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.search"
    static let description = IntentDescription("shortcut.search.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        run(.search)
        return .result()
    }
}

struct OpenFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.favorites"
    static let description = IntentDescription("shortcut.favorites.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        run(.favorites)
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.downloads"
    static let description = IntentDescription("shortcut.downloads.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        run(.downloads)
        return .result()
    }
}

struct ShuffleFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.shuffleFavorites"
    static let description = IntentDescription("shortcut.shuffleFavorites.description")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        run(.shuffleFavorites)
        return .result()
    }
}

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.playPause"
    static let description = IntentDescription("shortcut.playPause.description")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        run(.playPause)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.next"
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        run(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.previous"
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        run(.previous)
        return .result()
    }
}

/// Готовые ярлыки: видны в приложении «Команды», в Spotlight и у Siri без настройки. Фразы — в `AppShortcuts.xcstrings`.
struct MelogoldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSearchIntent(),
                    phrases: ["Search in \(.applicationName)", "Open search in \(.applicationName)"],
                    shortTitle: "shortcut.search", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenFavoritesIntent(),
                    phrases: ["Open favorites in \(.applicationName)", "Show my favorites in \(.applicationName)"],
                    shortTitle: "shortcut.favorites", systemImageName: "heart")
        AppShortcut(intent: ShuffleFavoritesIntent(),
                    phrases: ["Shuffle favorites in \(.applicationName)", "Shuffle my favorites in \(.applicationName)"],
                    shortTitle: "shortcut.shuffleFavorites", systemImageName: "shuffle")
        AppShortcut(intent: OpenDownloadsIntent(),
                    phrases: ["Open downloads in \(.applicationName)", "Show my downloads in \(.applicationName)"],
                    shortTitle: "shortcut.downloads", systemImageName: "arrow.down.circle")
        AppShortcut(intent: PlayPauseIntent(),
                    phrases: ["Play or pause \(.applicationName)", "Pause \(.applicationName)"],
                    shortTitle: "shortcut.playPause", systemImageName: "playpause")
    }
}
