import XCTest

/// История на часах (задание 0002 §3.6): часы входят по коду (API §4.6) — вход одобряет «Pixel тест», которым тест
/// управляет по API, — и их История показывает прослушивания Pixel; «Убрать из истории» на Pixel убирает трек и с
/// часов. Тест ничего не включает — звук не нужен. Тестовый аккаунт в конце удаляется.
///
/// Нужен сервер Melogold: `TEST_RUNNER_MELOGOLD_TEST_SERVER=http://127.0.0.1:8787`. Без переменной тест пропускается.
final class WatchHistoryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func label(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    @MainActor
    func testSignInWithCodeAndHistoryFromOtherDevice() async throws {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        let login = "watch\(Int.random(in: 10_000_000 ... 99_999_999))"
        let password = "w-\(UUID().uuidString.lowercased())"
        let pixel = try await TestDevice.register(server: server, login: login, password: password, name: "Pixel тест", platform: "android")
        addTeardownBlock { try? await pixel.deleteAccount(password: password) }
        let removed = "JGwWNGJdvx8"
        try await pixel.play([
            (removed, "Shape of You", "Ed Sheeran"),
            ("OPf0YbXqDm0", "Uptown Funk", "Mark Ronson"),
        ], spacing: 600)

        // Вход по коду: часы показывают код, Pixel находит привязку и выбирает число, которое часы показывают следом
        var app = launchApp(language: "ru", arguments: ["-server.url", server, "-MelogoldOpen", "settings"])
        signOutOnWatchIfNeeded(app)
        let byCode = app.buttons.containing(label("Войти по коду")).firstMatch
        XCTAssertTrue(byCode.waitForExistence(timeout: 10))
        byCode.tap()
        let userCode = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9A-Z]{4}-[0-9A-Z]{4}$")).firstMatch
        XCTAssertTrue(userCode.waitForExistence(timeout: 15), "часы не показали код")
        saveScreenshot("watch-history/01-code")
        let link = try await pixel.resolveLink(userCode: userCode.label)
        XCTAssertEqual(link.choices.count, 3)
        let shown = app.staticTexts.matching(NSPredicate(format: "label IN %@", link.choices)).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 30), "часы не показали число")
        saveScreenshot("watch-history/02-number")
        try await pixel.approveLink(link.linkId, verifyCode: shown.label)
        XCTAssertTrue(app.descendants(matching: .any).containing(label("Вход выполнен")).firstMatch.waitForExistence(timeout: 30))
        app.buttons["Готово"].firstMatch.tap()
        app.terminate()

        // История часов: прослушивания Pixel тест приходят синком
        app = launchApp(language: "ru", arguments: ["-server.url", server, "-MelogoldOpen", "library"])
        XCTAssertTrue(app.buttons.containing(label("Все треки")).firstMatch.waitForExistence(timeout: 10))
        // Список часов ленивый: строки ниже края экрана появляются в дереве доступности только после прокрутки
        let history = app.buttons.containing(label("История")).firstMatch
        for _ in 0 ..< 6 where !(history.exists && history.isHittable) { app.swipeUp() }
        history.tap()
        let shape = app.buttons.containing(label("Shape of You")).firstMatch
        XCTAssertTrue(shape.waitForExistence(timeout: 30), "прослушивания Pixel тест не пришли на часы")
        XCTAssertTrue(app.buttons.containing(label("Uptown Funk")).firstMatch.exists)
        saveScreenshot("watch-history/03-history")

        // «Убрать из истории» на Pixel: синк часов (событие сервера, пока приложение открыто) убирает трек
        try await pixel.forget(removed)
        XCTAssertTrue(shape.waitForNonExistence(timeout: 30), "history.forget с Pixel тест не дошёл до часов")
        XCTAssertTrue(app.buttons.containing(label("Uptown Funk")).firstMatch.exists)
        saveScreenshot("watch-history/04-after-forget")

        // Выход: часы уходят из аккаунта, аккаунт удаляет teardown
        app.terminate()
        app = launchApp(language: "ru", arguments: ["-server.url", server, "-MelogoldOpen", "settings"])
        signOutOnWatchIfNeeded(app)
        XCTAssertTrue(app.buttons.containing(label("Войти по коду")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }

    /// После прошлого запуска на часах мог остаться вход. Экран — «Настройки».
    @MainActor
    private func signOutOnWatchIfNeeded(_ app: XCUIApplication) {
        let overview = app.buttons["account.overview"]
        guard overview.waitForExistence(timeout: 3) else { return }
        overview.tap()
        let signOut = app.buttons["account.signOut"]
        _ = signOut.waitForExistence(timeout: 5)
        for _ in 0 ..< 6 where !(signOut.exists && signOut.isHittable) { app.swipeUp() }
        signOut.tap()
        // Кнопка окна подтверждения — тоже «Выйти», но без идентификатора кнопки списка
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Выйти", "account.signOut")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        _ = app.buttons.containing(label("Войти по коду")).firstMatch.waitForExistence(timeout: 10)
    }
}
