import XCTest

/// Поиск и воспроизведение на живом YouTube (срез 2). Нужна сеть.
final class PlaybackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func search(_ app: XCUIApplication, _ query: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
        field.typeText(query + "\n")
    }

    /// Выдача «Всё», нажатие по песне — играет, мини-плеер с кнопкой «Пауза».
    @MainActor
    func testSearchAndPlaySong() {
        let app = launchApp(section: "search", language: "ru")
        search(app, "кино группа крови")
        let song = app.cells.containing(NSPredicate(format: "label CONTAINS 'Группа крови'")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 20))
        saveScreenshot("iphone-search-all")
        song.tap()
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 20), "трек не заиграл")
        sleep(2)
        saveScreenshot("iphone-playing")
        app.terminate()
    }
}
