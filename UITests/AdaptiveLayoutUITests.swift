import XCTest

/// Раскладки iPad и iPhone боком (слайс S8): боковая панель, двухколоночный альбом, «Сейчас играет» широкой раскладкой
/// (обложка слева, текст справа), лист очереди. Нужна сеть; звук выключен; играет один и тот же закэшированный трек
/// (`TEST_RUNNER_MELOGOLD_AUDIT_DATA=<папка>` — копия кэша, см. `AccessibilityAuditUITests`). Снимки — в `MELOGOLD_SHOTS_DIR`,
/// имя по устройству и ориентации; снимок `XCUIScreen` приходит в портретной ориентации, боком его поворачивает вызывающий.
final class AdaptiveLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        Task { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private var dataDirectory: String {
        ProcessInfo.processInfo.environment["MELOGOLD_AUDIT_DATA"] ?? NSTemporaryDirectory() + "adaptive-\(UUID().uuidString)"
    }

    /// Ориентации из переменной `MELOGOLD_ORIENTATIONS` (`portrait,landscape`), по умолчанию обе.
    private var orientations: [(name: String, value: UIDeviceOrientation)] {
        let wanted = (ProcessInfo.processInfo.environment["MELOGOLD_ORIENTATIONS"] ?? "portrait,landscape").split(separator: ",").map(String.init)
        return [("portrait", .portrait), ("landscape", .landscapeLeft)].filter { wanted.contains($0.name) }
    }

    private var extra: [String] {
        switch ProcessInfo.processInfo.environment["MELOGOLD_AUDIT_MODE"] ?? "normal" {
        case "ax5": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        case "ax3": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        case "dark": ["-AppleInterfaceStyle", "Dark"]
        default: []
        }
    }

    @MainActor
    private func shoot(_ name: String, section: String, arguments: [String], settle: UInt32, after: (@MainActor (XCUIApplication) -> Void)? = nil) {
        for (orientation, value) in orientations {
            XCUIDevice.shared.orientation = value
            let app = launchApp(section: section, language: "ru", arguments: ["-MelogoldDataDir", dataDirectory] + extra + arguments)
            sleep(settle)
            after?(app)
            saveScreenshot("\(device)-\(orientation)-\(name)")
            app.terminate()
        }
    }

    @MainActor
    func testCatalogScreens() {
        shoot("trends", section: "trends", arguments: [], settle: 10)
        shoot("new", section: "new", arguments: [], settle: 10)
        shoot("library", section: "library", arguments: ["-MelogoldSeedLibrary", "YES"], settle: 10)
        shoot("album", section: "trends", arguments: ["-MelogoldOpen", "album:MPREb_OLmD8O5IYNS"], settle: 12)
        shoot("artist", section: "trends", arguments: ["-MelogoldOpen", "artist:UCL9NQ06h7I0CRUcGxPWMtkQ"], settle: 12)
        shoot("search", section: "search", arguments: ["-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchBlur", "YES"], settle: 14)
        shoot("settings", section: "settings", arguments: [], settle: 6)
    }

    @MainActor
    func testLibraryScreens() {
        shoot("history", section: "library", arguments: ["-MelogoldOpen", "history", "-MelogoldSeedPlays", "YES"], settle: 8)
        shoot("stats", section: "library", arguments: ["-MelogoldOpen", "stats", "-MelogoldSeedStats", "YES"], settle: 9)
        shoot("downloads", section: "library", arguments: ["-MelogoldOpen", "downloads", "-MelogoldSeedDownloads", "YES"], settle: 8)
    }

    @MainActor
    func testNowPlaying() {
        let play = ["-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "music", "-MelogoldPlayFirst", "YES", "-MelogoldShowNowPlaying", "YES"]
        shoot("np", section: "search", arguments: play + ["-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"], settle: 24)
        shoot("np-lyrics", section: "search", arguments: play + ["-MelogoldShowLyrics", "YES", "-MelogoldSeedLyrics", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"], settle: 26)
        shoot("np-queue", section: "search", arguments: play + ["-MelogoldShowQueue", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"], settle: 28)
    }

    /// Очередь колонкой справа (iPad, `inspector`): не «Сейчас играет» поверх, а раздел с открытой очередью; в узком окне — лист.
    @MainActor
    func testQueueColumn() {
        shoot("queue-column", section: "library", arguments: [
            "-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "music", "-MelogoldPlayFirst", "YES",
            "-MelogoldShowQueue", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES",
        ], settle: 26)
    }
}
