import XCTest

/// Библиотека (срез 4): хаб, Избранное, «Все треки», История, свой плейлист, очередь после перезапуска. Нужна сеть
/// для примера библиотеки (`-MelogoldSeedLibrary`); звук выключен.
final class LibraryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func label(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    @MainActor
    func testHubAndCollections() {
        let app = launchApp(section: "library", language: "ru", arguments: ["-MelogoldSeedLibrary", "YES"])
        XCTAssertTrue(app.staticTexts["Все треки"].waitForExistence(timeout: 30))
        saveScreenshot("iphone-library")
        app.buttons.matching(label("Избранное")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Слушать"].waitForExistence(timeout: 10), "Избранное пусто")
        saveScreenshot("iphone-favorites")
        app.navigationBars.buttons.firstMatch.tap()
        app.staticTexts["Все треки"].tap()
        XCTAssertTrue(app.cells.containing(label("Группа крови")).firstMatch.waitForExistence(timeout: 10))
        saveScreenshot("iphone-all-tracks")
        app.terminate()
    }

    /// Очередь и позиция переживают перезапуск, без автостарта (docs/PROMPT.md §4 «Очередь»).
    @MainActor
    func testQueueRestoredWithoutAutostart() {
        var app = launchApp(section: "trends", language: "ru", arguments: ["-MelogoldOpen", "album:MPREb_OLmD8O5IYNS"])
        let row = app.cells.containing(label("Война")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 20), "трек не заиграл")
        sleep(6)
        app.terminate()
        app = launchApp(section: "library", language: "ru")
        XCTAssertTrue(app.buttons["Воспроизвести"].waitForExistence(timeout: 15), "очередь не восстановилась")
        XCTAssertFalse(app.buttons["Пауза"].exists, "очередь не должна стартовать сама")
        saveScreenshot("iphone-queue-restored")
        app.terminate()
    }
}
