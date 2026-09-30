import XCTest

/// Аудит доступности главных экранов (слайс S8): `performAccessibilityAudit()` — тот же набор проверок, что в
/// «Accessibility Inspector › Audit»: контраст, описание элемента, зона нажатия, обрезанный текст, Dynamic Type, признаки.
/// Нужна сеть; звук выключен. Экран открывается параметрами запуска (`DebugLaunch`), данные — в своей папке.
///
/// Режим задаёт переменная `MELOGOLD_AUDIT_MODE` (`TEST_RUNNER_MELOGOLD_AUDIT_MODE=ax5 xcodebuild test …`): `normal`, `ax5`
/// (самый крупный размер шрифта), `ax5hard` (то же, но только проверки `hard`), `dark`, `ax3dark`. Замечания пишутся в `MELOGOLD_SHOTS_DIR/audit-<режим>-<экран>.txt`
/// (по строке на замечание) и в журнал теста. Тест падает на замечаниях `hard` — зона нажатия, описание элемента, обнаружение
/// элемента, признаки, — кроме внесённых в `accepted` с причиной. Остальное (`contrast`, `textClipped`, `dynamicType`)
/// только записывается: аудит Apple мерит контраст по пикселям под полупрозрачными панелями, системный `.secondary` на
/// системном фоне у него «не проходит» (у Apple так же), а «может обрезаться» он пишет у любого `lineLimit` и у текста на
/// границе экрана; настоящие обрезки ищутся по снимкам (`docs/STATUS.md`, слайс S8).
final class AccessibilityAuditUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private var mode: String { ProcessInfo.processInfo.environment["MELOGOLD_AUDIT_MODE"] ?? "normal" }

    /// Папка данных экрана. Чистая (новая на каждый запуск, без очереди и мини-плеера под содержимым) — для списков и
    /// настроек; `cached` — копия кэша с уже скачанным треком (`TEST_RUNNER_MELOGOLD_AUDIT_DATA=<папка>`), чтобы не просить у
    /// YouTube поток заново на каждый запуск; без переменной и она временная.
    private func dataDirectory(cached: Bool) -> String {
        if cached, let directory = ProcessInfo.processInfo.environment["MELOGOLD_AUDIT_DATA"] { return directory }
        return NSTemporaryDirectory() + "audit-\(UUID().uuidString)"
    }

    /// Какие проверки гонять. `normal` и `hard` — только те, на которых тест падает (прогон в разы короче, а пакет результатов не
    /// пухнет до сотен мегабайт скриншотов замечаний); остальные режимы — все.
    private var auditTypes: XCUIAccessibilityAuditType {
        switch mode {
        case "normal", "hard", "ax5hard": [.hitRegion, .sufficientElementDescription, .elementDetection, .trait]
        default: .all
        }
    }

    private var modeArguments: [String] {
        switch mode {
        case "ax5", "ax5hard": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        case "ax3dark": ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL", "-AppleInterfaceStyle", "Dark"]
        case "dark": ["-AppleInterfaceStyle", "Dark"]
        default: []
        }
    }

    private struct Screen {
        let name: String
        var cached = false
        let section: String
        var arguments: [String] = []
        var settle: UInt32 = 8
        /// Сколько раз прокрутить вниз и проверить снова: аудит видит только то, что на экране сейчас.
        var scrolls = 0
        /// Действия после запуска (открыть вложенный экран).
        var prepare: (@MainActor (XCUIApplication) -> Void)?
    }

    /// Замечания, на которых тест падает.
    private static let hard: Set<String> = ["hitRegion", "description", "elementDetection", "trait"]

    /// Замечания `hard`, которые не чиним, и почему. Ключ — `<экран>|<вид замечания>|<подпись элемента или пусто>`.
    private let accepted: [String: String] = [
        // Строка предсказаний системной клавиатуры над полем поиска (вкладка поиска iOS 26 открывает клавиатуру сама)
        "search-root|description|": "TUIPredictionViewCell — системная клавиатура",
        // Название альбома приходит от YouTube Music как есть («12_22»)
        "artist|description|12_22, 2022": "название альбома из ответа YouTube",
        // Подписи осей внутри диаграммы: диаграмма читается как «аудиограф» по `accessibilityChartDescriptor`, а не подписями осей
        "stats|elementDetection|": "подписи осей Swift Charts",
    ]

    @MainActor
    private func audit(_ screens: [Screen]) throws {
        for screen in screens {
            let app = launchApp(section: screen.section, language: "ru", arguments: [
                "-MelogoldDataDir", dataDirectory(cached: screen.cached),
            ] + modeArguments + screen.arguments)
            sleep(screen.settle)
            screen.prepare?(app)
            var lines: [String] = []
            var unexpected: [String] = []
            for pass in 0 ... screen.scrolls {
                if pass > 0 {
                    app.swipeUp()
                    sleep(1)
                }
                try app.performAccessibilityAudit(for: self.auditTypes) { issue in
                    let element = issue.element
                    let label = element?.label ?? ""
                    let kind = Self.name(of: issue.auditType)
                    let line = "[\(kind)] \(issue.compactDescription) | \(issue.detailedDescription) | \(element.map { "\($0.elementType.rawValue) “\(label)” \($0.frame.integral)" } ?? "—")"
                    let marked = pass > 0 ? "(прокрутка \(pass)) " + line : line
                    if !lines.contains(marked) { lines.append(marked) }
                    if Self.hard.contains(kind), self.accepted["\(screen.name)|\(kind)|\(label)"] == nil, !unexpected.contains(marked) {
                        unexpected.append(marked)
                    }
                    // Аудит идёт до конца: замечания собираются, а не останавливают его на первом
                    return true
                }
            }
            record(screen.name, lines)
            XCTAssertTrue(unexpected.isEmpty, "\(screen.name): \(unexpected.count) замечаний аудита\n" + unexpected.joined(separator: "\n"))
            app.terminate()
        }
    }

    private func record(_ screen: String, _ lines: [String]) {
        let text = lines.isEmpty ? "замечаний нет\n" : lines.joined(separator: "\n") + "\n"
        print("AUDIT \(mode) \(screen):\n\(text)")
        guard let directory = ProcessInfo.processInfo.environment["MELOGOLD_SHOTS_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("audit-\(mode)-\(screen).txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "description"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "other(\(type.rawValue))"
        }
    }

    // MARK: - Экраны

    /// Корни разделов: Тренды, Новое, Библиотека, Настройки.
    @MainActor
    func testRoots() throws {
        try audit([
            Screen(name: "trends", section: "trends", settle: 10, scrolls: 3),
            Screen(name: "new", section: "new", settle: 10, scrolls: 3),
            Screen(name: "library", section: "library", arguments: ["-MelogoldSeedLibrary", "YES"], scrolls: 2),
            Screen(name: "settings", section: "settings", settle: 5, scrolls: 4),
        ])
    }

    /// Поиск: корень и выдача обеих областей (без клавиатуры и подсказок — `-MelogoldSearchBlur`).
    @MainActor
    func testSearch() throws {
        try audit([
            Screen(name: "search-root", section: "search", settle: 5),
            Screen(name: "search-music", section: "search", arguments: ["-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchBlur", "YES"], settle: 14, scrolls: 2),
            Screen(name: "search-youtube", section: "search", arguments: ["-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "youtube", "-MelogoldSearchBlur", "YES"], settle: 14, scrolls: 2),
        ])
    }

    /// Библиотека внутри: История, Итоги, Избранное, Скачанное.
    @MainActor
    func testLibraryScreens() throws {
        try audit([
            Screen(name: "history", section: "library", arguments: ["-MelogoldOpen", "history", "-MelogoldSeedPlays", "YES"], settle: 8, scrolls: 2),
            Screen(name: "stats", section: "library", arguments: ["-MelogoldOpen", "stats", "-MelogoldSeedStats", "YES"], settle: 9, scrolls: 3),
            Screen(name: "favorites", section: "library", arguments: ["-MelogoldOpen", "favorites", "-MelogoldSeedLibrary", "YES"], settle: 10, scrolls: 2),
            Screen(name: "downloads", section: "library", arguments: ["-MelogoldOpen", "downloads", "-MelogoldSeedDownloads", "YES"], settle: 8, scrolls: 2),
        ])
    }

    /// Детальные экраны каталога.
    @MainActor
    func testCatalogDetails() throws {
        try audit([
            Screen(name: "album", section: "trends", arguments: ["-MelogoldOpen", "album:MPREb_OLmD8O5IYNS"], settle: 12, scrolls: 2),
            Screen(name: "artist", section: "trends", arguments: ["-MelogoldOpen", "artist:UCL9NQ06h7I0CRUcGxPWMtkQ"], settle: 12, scrolls: 3),
        ])
    }

    /// Аккаунт без входа: вход, регистрация, «Войти по коду», код восстановления, сервер, «Диагностика».
    @MainActor
    func testAccountScreens() throws {
        try audit([
            Screen(name: "account-signin", section: "settings", arguments: ["-MelogoldOpen", "signIn"], settle: 4, scrolls: 1),
            Screen(name: "account-register", section: "settings", arguments: ["-MelogoldOpen", "register"], settle: 4, scrolls: 1),
            Screen(name: "account-link", section: "settings", arguments: ["-MelogoldOpen", "signInByCode"], settle: 5, scrolls: 1),
            Screen(name: "account-recovery", section: "settings", arguments: ["-MelogoldOpen", "recoveryCode"], settle: 4, scrolls: 1),
            Screen(name: "server", section: "settings", arguments: ["-MelogoldOpen", "server"], settle: 4),
            Screen(name: "diagnostics", section: "settings", arguments: ["-MelogoldOpen", "diagnostics"], settle: 4, scrolls: 1),
        ])
    }

    /// «Сейчас играет»: обложка, текст, очередь и мини-плеер. Играет один и тот же трек, звук выключен.
    @MainActor
    func testNowPlaying() throws {
        let play = ["-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "music", "-MelogoldPlayFirst", "YES"]
        try audit([
            Screen(name: "miniplayer", cached: true, section: "trends", arguments: ["-MelogoldOpenLink", "https://music.youtube.com/watch?v=xtxjm7ciwmc"], settle: 14),
            Screen(name: "nowplaying", cached: true, section: "search", arguments: play + ["-MelogoldShowNowPlaying", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"], settle: 24),
            Screen(name: "lyrics", cached: true, section: "search", arguments: play + ["-MelogoldShowNowPlaying", "YES", "-MelogoldShowLyrics", "YES", "-MelogoldSeedLyrics", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"], settle: 26),
            Screen(name: "queue", cached: true, section: "search", arguments: play + ["-MelogoldShowNowPlaying", "YES", "-MelogoldShowQueue", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"], settle: 28),
        ])
    }
}
