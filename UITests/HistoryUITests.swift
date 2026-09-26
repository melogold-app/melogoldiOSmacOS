import XCTest

/// История через сервер (задание 0002): прослушивания другого устройства аккаунта приходят синком, фильтр по устройствам
/// показывает их по имени устройства, «Очистить историю» и «Убрать из истории» доходят до сервера. Другое устройство
/// (android) работает прямо из теста по API: регистрация с proof-of-work, `play.add`, синк со своего курсора. iPhone
/// входит в тот же аккаунт; свои прослушивания — отладочный `-MelogoldSeedPlays` (без плеера, звук не нужен). Тестовый
/// аккаунт в конце удаляется.
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
        signIn(app, login: login)
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

    /// Прослушивания «Pixel тест» (10 минут между ними) приходят на iPhone; фильтр — «Все устройства», «Pixel тест»,
    /// «Это устройство». «Убрать из истории» на iPhone после «Отменить» (5 с) доходит до Pixel: следующий синк с его
    /// курсора приносит `playForgets` трека с обнулённым общим временем, и в истории аккаунта трека больше нет.
    @MainActor
    func testPlaysFromOtherDeviceAndRemoveFromHistory() async throws {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        let login = "hist\(Int.random(in: 10_000_000 ... 99_999_999))"
        let password = "h-\(UUID().uuidString.lowercased())"
        let pixel = try await TestDevice.register(server: server, login: login, password: password, name: "Pixel тест", platform: "android")
        addTeardownBlock { try? await pixel.deleteAccount(password: password) }
        let removed = "JGwWNGJdvx8"
        let cursor = try await pixel.play([
            (removed, "Shape of You", "Ed Sheeran"),
            ("OPf0YbXqDm0", "Uptown Funk", "Mark Ronson"),
        ], spacing: 600)

        var app = launchApp(section: "settings", language: "ru",
                            arguments: ["-server.url", server, "-MelogoldUITestPassword", password, "-MelogoldSeedPlays", "YES"])
        signIn(app, login: login)
        app.terminate()

        // История: прослушивания Pixel тест приходят синком
        app = launchApp(section: "library", language: "ru", arguments: ["-server.url", server, "-MelogoldOpen", "history"])
        let devices = app.buttons["history.devices"]
        XCTAssertTrue(devices.waitForExistence(timeout: 30), "нет фильтра по устройствам")
        let shape = app.cells.containing(label("Shape of You")).firstMatch
        XCTAssertTrue(shape.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.containing(label("Uptown Funk")).firstMatch.exists)
        XCTAssertTrue(app.cells.containing(label("Bohemian Rhapsody")).firstMatch.exists)
        saveScreenshot("history-pixel/01-all-devices")

        devices.tap()
        let pixelItem = app.buttons["Pixel тест"].firstMatch
        XCTAssertTrue(pixelItem.waitForExistence(timeout: 5), "нет устройства в меню")
        XCTAssertTrue(app.buttons["Все устройства"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Это устройство"].firstMatch.exists)
        saveScreenshot("history-pixel/02-menu")
        pixelItem.tap()
        XCTAssertTrue(app.cells.containing(label("Bohemian Rhapsody")).firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(shape.exists)
        XCTAssertTrue(app.cells.containing(label("Uptown Funk")).firstMatch.exists)
        saveScreenshot("history-pixel/03-pixel")

        devices.tap()
        app.buttons["Это устройство"].firstMatch.tap()
        XCTAssertTrue(shape.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.cells.containing(label("Bohemian Rhapsody")).firstMatch.exists)
        XCTAssertFalse(app.cells.containing(label("Uptown Funk")).firstMatch.exists)
        saveScreenshot("history-pixel/04-this-device")

        devices.tap()
        app.buttons["Все устройства"].firstMatch.tap()
        XCTAssertTrue(shape.waitForExistence(timeout: 5))

        // «Убрать из истории» из «…» строки (нажатие по самой строке включило бы трек): плашка с «Отменить»
        shape.buttons["Ещё"].tap()
        app.buttons["Убрать из истории"].firstMatch.tap()
        let undo = app.staticTexts.containing(label("Убрано из истории на всех устройствах")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(shape.waitForNonExistence(timeout: 5))
        saveScreenshot("history-pixel/05-removed-undo")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 15), "плашка «Отменить» не ушла")
        saveScreenshot("history-pixel/06-after-remove")

        // Pixel тест синхронизируется со своего курсора: приходит playForgets трека, общее время обнулено (resetTotal)
        var forget: [String: Any]?
        var next = cursor
        for _ in 0 ..< 30 where forget == nil {
            try await Task.sleep(for: .seconds(1))
            let page = try await pixel.changes(since: next)
            next = page["cursor"] as? String ?? next
            forget = (page["playForgets"] as? [[String: Any]] ?? []).first { $0["videoId"] as? String == removed }
        }
        let row = try XCTUnwrap(forget, "history.forget не дошёл до Pixel тест")
        XCTAssertNotNil(row["eventsBefore"] as? String)
        XCTAssertNotNil(row["totalBefore"] as? String, "общее время трека не обнулено (resetTotal)")
        let played = try await pixel.playedVideoIds()
        XCTAssertFalse(played.contains(removed), "трек остался в истории аккаунта")
        XCTAssertTrue(played.contains("OPf0YbXqDm0"))

        // Выход: устройство уходит из аккаунта, аккаунт удаляет teardown
        app.terminate()
        app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server])
        signOutIfNeeded(app)
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
