import XCTest

/// Доступность плеера и списков (слайс S8): то, что слышит VoiceOver, проверяется через дерево доступности — подписи, значения,
/// признаки и размеры зон нажатия. Нужна сеть и папка данных с закэшированным треком
/// (`TEST_RUNNER_MELOGOLD_AUDIT_DATA=<папка>`, см. `AccessibilityAuditUITests`); звук выключен, играет один и тот же трек.
final class PlayerAccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private var dataDirectory: String {
        ProcessInfo.processInfo.environment["MELOGOLD_AUDIT_DATA"] ?? NSTemporaryDirectory() + "a11y-\(UUID().uuidString)"
    }

    @MainActor
    private func launchPlaying(_ extra: [String]) -> XCUIApplication {
        launchApp(section: "search", language: "ru", arguments: [
            "-MelogoldDataDir", dataDirectory,
            "-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "music", "-MelogoldPlayFirst", "YES",
            "-MelogoldShowNowPlaying", "YES", "-MelogoldSeek", "15", "-MelogoldSeekPause", "YES",
        ] + extra)
    }

    /// «Сейчас играет»: полоса перемотки — «Позиция» со значением «0:15 из 4:43»; у каждой кнопки есть подпись; кнопки
    /// ♡ и «…» в стеклянных кругах 38 pt имеют зону нажатия не меньше 44 pt.
    @MainActor
    func testNowPlayingElements() {
        let app = launchPlaying([])
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Позиция'")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 60), "нет полосы перемотки")
        sleep(3)
        let value = seek.value as? String ?? ""
        XCTAssertTrue(value.contains(" из "), "значение полосы перемотки без полной длительности: «\(value)»")
        for label in ["Воспроизвести", "Следующий", "Предыдущий", "Текст", "Очередь"] {
            XCTAssertTrue(app.buttons[label].exists, "нет кнопки «\(label)»")
        }
        // Рамка доступности ♡ и «…» — 44 pt, а не 38 pt стекла
        let like = app.buttons.matching(NSPredicate(format: "label IN {'В Избранное', 'Убрать из Избранного'}")).firstMatch
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ещё'")).firstMatch
        XCTAssertTrue(like.exists && more.exists, "нет кнопок ♡ и «…»")
        for element in [like, more] where element.exists {
            XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, "зона нажатия уже 44 pt: \(element.label)")
            XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, "зона нажатия ниже 44 pt: \(element.label)")
        }
        saveScreenshot("a11y-nowplaying")
        app.terminate()
    }

    /// Текст: строки — кнопки с «Играет с этой строки», текущая отмечена признаком «выбрано», подпевка и перевод — значением.
    @MainActor
    func testLyricsLines() {
        let app = launchPlaying(["-MelogoldShowLyrics", "YES", "-MelogoldSeedLyrics", "YES"])
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Мягкое кресло'")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 60), "нет текущей строки текста")
        sleep(2)
        XCTAssertTrue(current.isSelected, "текущая строка не отмечена признаком «выбрано»")
        XCTAssertEqual(current.value as? String, "(эхо)", "подпевка должна читаться значением строки")
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ответ второго голоса'")).firstMatch
        XCTAssertTrue(other.exists, "нет следующей строки")
        XCTAssertFalse(other.isSelected, "следующая строка отмечена как текущая")
        saveScreenshot("a11y-lyrics")
        app.terminate()
    }

    /// Очередь: текущий трек — выбранная строка со значением «Сейчас играет», у кнопок строк «Ещё: название».
    @MainActor
    func testQueueRows() {
        let app = launchPlaying(["-MelogoldShowQueue", "YES"])
        // Мини-плеер под листом тоже называет трек, но его значение — «На паузе»; строка очереди — «Сейчас играет»
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Группа крови' AND value == 'Сейчас играет'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "у текущей строки очереди нет значения «Сейчас играет»")
        sleep(2)
        XCTAssertTrue(row.isSelected, "текущая строка очереди не отмечена признаком «выбрано»")
        saveScreenshot("a11y-queue")
        app.terminate()
    }

    /// Списки: кнопка «…» строки называет трек («Ещё: Название»), играющий трек в строке — со значением «Сейчас играет».
    @MainActor
    func testRowMenuNamesTrack() {
        let app = launchApp(section: "search", language: "ru", arguments: [
            "-MelogoldDataDir", dataDirectory, "-MelogoldSearch", "Кино Группа крови", "-MelogoldSearchScope", "music",
            "-MelogoldSearchBlur", "YES",
        ])
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ещё: '")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 60), "у строк выдачи нет кнопок «Ещё: название»")
        XCTAssertGreaterThanOrEqual(more.frame.height, 43.5)
        saveScreenshot("a11y-rows")
        app.terminate()
    }
}
