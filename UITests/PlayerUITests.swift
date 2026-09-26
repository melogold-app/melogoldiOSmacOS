import XCTest

/// Отделка плеера (срез 7): очередь из «Сейчас играет», таймер сна в меню «…». Нужна сеть; звук выключен.
final class PlayerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testQueueAndSleepTimer() {
        let app = launchApp(section: "trends", language: "ru", arguments: [
            "-MelogoldOpenLink", "https://music.youtube.com/watch?v=xtxjm7ciwmc", "-MelogoldShowNowPlaying", "YES",
        ])
        let queue = app.buttons["Очередь"]
        XCTAssertTrue(queue.waitForExistence(timeout: 30), "нет «Сейчас играет»")
        sleep(4)
        queue.tap()
        XCTAssertTrue(app.staticTexts["Сейчас играет"].waitForExistence(timeout: 10), "очередь не открылась")
        sleep(3)
        saveScreenshot("iphone-queue")
        app.buttons["Готово"].tap()
        app.buttons["Ещё"].firstMatch.tap()
        let sleepMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Таймер сна'")).firstMatch
        XCTAssertTrue(sleepMenu.waitForExistence(timeout: 5))
        sleepMenu.tap()
        app.buttons["30 мин"].tap()
        XCTAssertTrue(app.buttons["Таймер сна"].waitForExistence(timeout: 5), "нет чипа таймера")
        saveScreenshot("iphone-sleep-chip")
        app.terminate()
    }
}
