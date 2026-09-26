import XCTest

/// История через сервер (задание 0002): прослушивания другого устройства аккаунта приходят синком, фильтр по устройствам
/// показывает их по имени устройства, «Очистить историю» доходит до сервера. Другое устройство — «Pixel 9» (android) —
/// работает прямо из теста по API: регистрация с proof-of-work, `play.add`. iPhone входит в тот же аккаунт; свои
/// прослушивания — отладочный `-MelogoldSeedPlays` (без плеера, звук не нужен). Тестовый аккаунт в конце удаляется.
///
/// Нужен сервер Melogold: `TEST_RUNNER_MELOGOLD_TEST_SERVER=http://127.0.0.1:8787`. Без переменной тест пропускается.
final class HistoryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func label(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    @MainActor
    func testDeviceFilterAndClearOnAllDevices() async throws {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        let login = "hist\(Int.random(in: 10_000_000 ... 99_999_999))"
        let password = "h-\(UUID().uuidString.lowercased())"
        let phone = try await TestDevice.register(server: server, login: login, password: password, name: "Pixel 9", platform: "android")
        addTeardownBlock { try? await phone.deleteAccount(password: password) }
        try await phone.play([
            ("JGwWNGJdvx8", "Shape of You", "Ed Sheeran"),
            ("OPf0YbXqDm0", "Uptown Funk", "Mark Ronson"),
        ])

        // Вход в тот же аккаунт; пароль — отладочной подстановкой, логин — набором
        var app = launchApp(section: "settings", language: "ru",
                            arguments: ["-server.url", server, "-MelogoldUITestPassword", password, "-MelogoldSeedPlays", "YES"])
        signOutIfNeeded(app)
        app.buttons["account.signIn"].tap()
        let loginField = app.textFields["Логин"]
        XCTAssertTrue(loginField.waitForExistence(timeout: 5))
        loginField.tap()
        loginField.typeText(login)
        XCTAssertEqual(loginField.value as? String, login, "симулятор потерял символы логина")
        app.buttons["account.signIn.submit"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.buttons["account.overview"].waitForExistence(timeout: 20), "вход не прошёл")
        app.terminate()

        // История: прослушивания Pixel 9 приходят синком, фильтр появляется
        app = launchApp(section: "library", language: "ru", arguments: ["-server.url", server, "-MelogoldOpen", "history"])
        let devices = app.buttons["history.devices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 30), "нет фильтра по устройствам")
        XCTAssertTrue(app.cells.containing(label("Shape of You")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.containing(label("Bohemian Rhapsody")).firstMatch.exists)
        saveScreenshot("history/01-all-devices")

        devices.tap()
        let pixel = app.buttons["Pixel 9"].firstMatch
        XCTAssertTrue(pixel.waitForExistence(timeout: 5), "нет устройства в меню")
        XCTAssertTrue(app.buttons["Это устройство"].firstMatch.exists)
        saveScreenshot("history/02-menu")
        pixel.tap()
        XCTAssertTrue(app.cells.containing(label("Uptown Funk")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.containing(label("Bohemian Rhapsody")).firstMatch.waitForNonExistence(timeout: 5))
        saveScreenshot("history/03-pixel")

        devices.tap()
        app.buttons["Это устройство"].firstMatch.tap()
        XCTAssertTrue(app.cells.containing(label("Bohemian Rhapsody")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.containing(label("Shape of You")).firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["Чаще всего"].tap()
        XCTAssertTrue(app.cells.containing(label("Smells Like Teen Spirit")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot("history/04-this-device-top")

        // «Очистить историю…» — на всех устройствах аккаунта, с «Отменить»
        app.buttons["history.more"].tap()
        app.buttons["Очистить историю…"].tap()
        XCTAssertTrue(app.staticTexts.containing(label("на всех устройствах аккаунта")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot("history/05-clear-confirm")
        app.buttons["Очистить"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(label("История очищена на всех устройствах")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot("history/06-cleared-undo")

        // Через 5 с действие выполняется, синк отправляет history.clear: у Pixel 9 история пуста
        var remaining = -1
        for _ in 0 ..< 30 {
            try await Task.sleep(for: .seconds(1))
            remaining = try await phone.playCount()
            if remaining == 0 { break }
        }
        XCTAssertEqual(remaining, 0, "history.clear не дошёл до сервера")

        // Выход: устройство уходит из аккаунта, аккаунт удаляет teardown
        app.terminate()
        app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server])
        signOutIfNeeded(app)
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
