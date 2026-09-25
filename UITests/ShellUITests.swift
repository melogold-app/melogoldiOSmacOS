import XCTest

/// Оболочка iPhone (docs/PROMPT.md §5.2, REWRITE §2.3): разделы, повторное нажатие, ссылки.
final class ShellUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Повторное нажатие на активный раздел во вложенном экране возвращает к корню раздела.
    @MainActor
    func testReselectingActiveSectionPopsToRoot() {
        let app = launchApp(section: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.buttons["settings.server"].tap()
        XCTAssertTrue(app.navigationBars["Melogold server"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Melogold server"].exists)
    }

    /// Стек раздела переживает переключение на другой раздел и обратно.
    @MainActor
    func testSectionStacksAreKeptWhenSwitching() {
        let app = launchApp(section: "settings")
        app.buttons["settings.server"].tap()
        XCTAssertTrue(app.navigationBars["Melogold server"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Melogold server"].waitForExistence(timeout: 5))
    }

    /// Приложение открывается в разделе, где пользователь был при выходе (`shell.lastTab`).
    @MainActor
    func testLastSectionIsRestored() {
        let app = launchApp(section: "library")
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        app.tabBars.buttons["New"].tap()
        XCTAssertTrue(app.navigationBars["New"].waitForExistence(timeout: 5))
        app.terminate()
        // Без аргумента раздела — значение из UserDefaults, записанное при переключении.
        let again = launchApp()
        XCTAssertTrue(again.navigationBars["New"].waitForExistence(timeout: 10))
    }

    /// Ссылка `melogold://server` открывает «Сервер Melogold» с заполненным адресом (API §7.2).
    @MainActor
    func testServerLinkOpensServerScreen() {
        let app = launchApp(arguments: ["-MelogoldOpenURL", "melogold://server?v=1&url=http%3A%2F%2F192.168.1.50%3A8080"])
        XCTAssertTrue(app.navigationBars["Melogold server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Insecure connection"].exists)
    }

    /// Вкладка «Поиск» на iPhone: поле встаёт в панель вкладок внизу и сразу активно (iOS 26).
    @MainActor
    func testSearchTabActivatesFieldAtBottom() {
        let app = launchApp(section: "library")
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(field.frame.minY, app.frame.height / 2, "поле поиска должно быть внизу экрана")
        dismissKeyboardTip(app)
    }

    /// Снимки корней разделов на русском — для отчёта среза.
    @MainActor
    func testScreenshotsRussian() {
        var app = launchApp(section: "trends", language: "ru")
        XCTAssertTrue(app.navigationBars["Тренды"].waitForExistence(timeout: 10))
        saveScreenshot("iphone-trends")
        app.tabBars.buttons["Поиск"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        dismissKeyboardTip(app)
        sleep(1)
        saveScreenshot("iphone-search")
        app.terminate()

        app = launchApp(section: "settings", language: "ru")
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 10))
        saveScreenshot("iphone-settings")
        app.buttons["settings.server"].tap()
        XCTAssertTrue(app.navigationBars["Сервер Melogold"].waitForExistence(timeout: 5))
        saveScreenshot("iphone-server")
    }

    /// Подсказка клавиатуры симулятора о наборе скольжением появляется один раз — закрываем её.
    @MainActor
    private func dismissKeyboardTip(_ app: XCUIApplication) {
        let button = app.buttons["Continue"]
        if button.waitForExistence(timeout: 2) { button.tap() }
    }
}
