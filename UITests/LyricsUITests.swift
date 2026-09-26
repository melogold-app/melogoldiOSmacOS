import XCTest

/// Тексты (срез 6): синхронный текст в «Сейчас играет» и редактор. Нужна сеть; звук выключен.
final class LyricsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncedLyricsAndEditor() {
        let app = launchApp(section: "trends", language: "ru", arguments: [
            "-MelogoldOpenLink", "https://music.youtube.com/watch?v=xtxjm7ciwmc", "-MelogoldShowNowPlaying", "YES", "-MelogoldShowLyrics", "YES",
        ])
        let line = app.buttons.matching(NSPredicate(format: "label CONTAINS 'улицы ждут'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 30), "текст не появился")
        saveScreenshot("iphone-lyrics")
        app.buttons["Меню текста"].tap()
        app.buttons["Редактировать текст"].tap()
        XCTAssertTrue(app.buttons["Разметка"].waitForExistence(timeout: 5), "редактор не открылся")
        saveScreenshot("iphone-editor")
        app.buttons["Отмена"].tap()
        app.terminate()
    }
}
