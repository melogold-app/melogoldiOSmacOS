import XCTest

/// Каталог на живом YouTube (срез 3): Тренды, альбом, плейлист, ссылки. Нужна сеть; звук выключен.
final class CatalogUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func label(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    /// Тренды: «В тренде» и «Настроения и жанры»; «Весь список» открывает плейлист чарта; плитка — настроение.
    @MainActor
    func testTrendsChartAndMood() {
        let app = launchApp(section: "trends", language: "ru")
        XCTAssertTrue(app.staticTexts["В тренде"].waitForExistence(timeout: 20))
        saveScreenshot("iphone-trends")
        app.buttons["Весь список"].tap()
        XCTAssertTrue(app.buttons["Слушать"].waitForExistence(timeout: 20), "плейлист чарта не открылся")
        saveScreenshot("iphone-chart")
        app.navigationBars.buttons.firstMatch.tap()
        let tile = app.buttons.matching(label("Отдых")).firstMatch
        if tile.waitForExistence(timeout: 5) {
            tile.tap()
            XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 20))
            sleep(3)
            saveScreenshot("iphone-mood")
        }
        app.terminate()
    }

    /// Альбом: нажатие по строке трека — список альбома с этого трека, мини-плеер с «Пауза».
    @MainActor
    func testAlbumRowPlaysList() {
        let app = launchApp(section: "trends", language: "ru", arguments: ["-MelogoldOpen", "album:MPREb_OLmD8O5IYNS"])
        let row = app.cells.containing(label("Война")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "альбом не открылся")
        saveScreenshot("iphone-album")
        row.tap()
        // iPhone: кнопка «Пауза» в мини-плеере; iPad: мини-плеер — один элемент «Война, Кино».
        let playing = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Пауза' OR label BEGINSWITH 'Война,'")).firstMatch
        let started = playing.waitForExistence(timeout: 20)
        if !started {
            saveScreenshot("album-not-playing")
            print("ДЕРЕВО:\n" + app.debugDescription)
        }
        XCTAssertTrue(started, "трек не заиграл")
        saveScreenshot("iphone-album-playing")
        app.terminate()
    }

    /// Ссылка в поле Поиска: подсказка «Открыть ссылку: альбом», Enter открывает альбом, а не выдачу.
    @MainActor
    func testLinkInSearchOpensAlbum() {
        let app = launchApp(section: "search", language: "ru")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
        field.typeText("https://music.youtube.com/browse/MPREb_OLmD8O5IYNS")
        XCTAssertTrue(app.buttons.matching(label("Открыть ссылку: альбом")).firstMatch.waitForExistence(timeout: 5))
        saveScreenshot("iphone-link-suggestion")
        field.typeText("\n")
        XCTAssertTrue(app.cells.containing(label("Война")).firstMatch.waitForExistence(timeout: 20), "ссылка не открыла альбом")
        app.terminate()
    }

    /// Исполнитель: «Популярное» и карусели; канал без музыкального профиля — видео канала.
    @MainActor
    func testArtistAndChannel() {
        var app = launchApp(section: "new", language: "ru", arguments: ["-MelogoldOpen", "artist:UCL9NQ06h7I0CRUcGxPWMtkQ"])
        XCTAssertTrue(app.buttons["Радио"].waitForExistence(timeout: 20), "исполнитель не открылся")
        saveScreenshot("iphone-artist")
        app.terminate()
        app = launchApp(section: "new", language: "ru", arguments: ["-MelogoldOpen", "artist:UCy_vnPBNh9FqtyH9Qc-aiSA"])
        XCTAssertTrue(app.buttons["Перемешать видео"].waitForExistence(timeout: 30), "канал не открылся")
        saveScreenshot("iphone-channel")
        app.terminate()
    }
}
