import XCTest

/// «Сейчас играет» (слайс S2): обложка и текст боком, подложка текущей строки, редактор с длинной строкой. Нужна сеть;
/// звук выключен, воспроизведение ставится на паузу на нужной секунде (`-MelogoldSeek`), чтобы снимки не зависели от
/// времени. Снимки — в `MELOGOLD_SHOTS_DIR`, имя по устройству (`iphone-…`, `ipad-…`).
final class NowPlayingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        Task { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    @MainActor
    private func launchPlaying(_ extra: [String]) -> XCUIApplication {
        launchApp(section: "search", language: "ru", arguments: [
            "-MelogoldDataDir", NSTemporaryDirectory() + "np-shots-\(UUID().uuidString)",
            "-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "music", "-MelogoldPlayFirst", "YES",
            "-MelogoldShowNowPlaying", "YES",
        ] + extra)
    }

    /// Боком: обложка слева, управление справа; текст — слева управление, справа текст с подложкой.
    @MainActor
    func testLandscapeCoverAndLyrics() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchPlaying(["-MelogoldSeedLyrics", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES"])
        let queue = app.buttons["Очередь"]
        XCTAssertTrue(queue.waitForExistence(timeout: 40), "нет «Сейчас играет»")
        sleep(6)
        saveScreenshot("\(device)-landscape-cover")
        app.buttons["Текст"].firstMatch.tap()
        let line = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Мягкое кресло'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 30), "текст не появился")
        sleep(30)
        saveScreenshot("\(device)-landscape-lyrics")
        app.terminate()
    }

    /// Редактор, «Разметка»: «Далее» — длинная строка целиком; `words` — вся строка, отмеченные слова акцентом, следующее
    /// жирным и подчёркнутым; `second` — очень длинная строка прокручивается внутри блока в ~200 pt.
    @MainActor
    func testEditorNextLineWhole() {
        for state in ["marks", "words", "second"] {
            let app = launchPlaying(["-MelogoldSeedLyrics", "editor", "-MelogoldShowLyrics", "YES", "-MelogoldLyricsEditor", state])
            XCTAssertTrue(app.staticTexts["Далее"].waitForExistence(timeout: 60), "нет блока «Далее»: \(state)")
            XCTAssertTrue(app.buttons["Отметить"].exists, "«Отметить» вне экрана: \(state)")
            sleep(2)
            saveScreenshot("\(device)-editor-next-\(state)")
            app.terminate()
        }
    }

    /// Мини-плеер: обычный вид над панелью вкладок и компактный (`inline`), когда панель свёрнута прокруткой вниз
    /// (`tabBarMinimizeBehavior(.onScrollDown)`, `tabViewBottomAccessoryPlacement`); на iPad — полоса внизу колонки.
    @MainActor
    func testMiniPlayerExpandedAndInline() {
        let app = launchApp(section: "trends", language: "ru", arguments: [
            "-MelogoldDataDir", NSTemporaryDirectory() + "np-shots-\(UUID().uuidString)",
            "-MelogoldOpenLink", "https://music.youtube.com/watch?v=xtxjm7ciwmc",
        ])
        XCTAssertTrue(app.buttons["Пауза"].waitForExistence(timeout: 40), "трек не заиграл")
        sleep(4)
        saveScreenshot("\(device)-miniplayer-expanded")
        // Медленная прокрутка пальцем: панель вкладок сворачивается, только когда прокрутка настоящая
        let list = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app
        for _ in 0 ..< 4 { list.swipeUp(velocity: .slow) }
        sleep(2)
        saveScreenshot("\(device)-miniplayer-scrolled")
        app.terminate()
    }
}
