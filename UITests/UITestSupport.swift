import XCTest

/// Общие приёмы UI-тестов: запуск с нужным разделом и языком, снимки экрана в папку срезов.
///
/// Снимки пишутся, только если задана переменная `MELOGOLD_SHOTS_DIR` (xcodebuild передаёт её тестам
/// как `TEST_RUNNER_MELOGOLD_SHOTS_DIR=…`). Симулятор видит файловую систему Mac, поэтому путь — обычный путь Mac.
extension XCTestCase {
    @MainActor
    func launchApp(section: String? = nil, language: String = "en", arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var launch = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        if let section { launch += ["-shell.lastTab", section] }
        // Отладочный прокси: при VPN на Mac симулятор не разрешает имена сам (docs/STATUS.md).
        if let proxy = ProcessInfo.processInfo.environment["MELOGOLD_PROXY"], !proxy.isEmpty {
            launch += ["-MelogoldDebugProxy", proxy]
        }
        app.launchArguments = launch + arguments
        app.launch()
        return app
    }

    @MainActor
    func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["MELOGOLD_SHOTS_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }
}
