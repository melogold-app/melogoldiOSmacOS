import XCTest

/// Выпуск (срез 8): «Диагностика › Проверить извлечение» и строка импорта в Библиотеке. Нужна сеть; звук выключен.
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDiagnosticsExtraction() {
        let app = launchApp(section: "settings", language: "ru", arguments: ["-MelogoldOpen", "diagnostics"])
        let test = app.buttons["Проверить извлечение"]
        XCTAssertTrue(test.waitForExistence(timeout: 10), "нет «Диагностики»")
        test.tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'itag'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40), "извлечение не прошло")
        saveScreenshot("iphone-diagnostics")
        app.terminate()
    }

    @MainActor
    func testLibraryImportRow() {
        let app = launchApp(section: "library", language: "ru")
        let row = app.buttons["library.import"]
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "нет строки импорта")
        saveScreenshot("iphone-library-import")
        row.tap()
        // Системное окно выбора файла («Отменить» — его кнопка)
        XCTAssertTrue(app.buttons["Отменить"].waitForExistence(timeout: 10), "окно выбора файла не открылось")
        sleep(2)
        saveScreenshot("iphone-import-picker")
        app.terminate()
    }

    @MainActor
    func testSaveCopyOpensSaveSheet() {
        let app = launchApp(section: "settings", language: "ru")
        let save = app.buttons["Сохранить копию"]
        for _ in 0..<8 where !save.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(save.waitForExistence(timeout: 5), "нет «Сохранить копию»")
        saveScreenshot("iphone-settings-backup")
        save.tap()
        // Системное окно сохранения: копия уже собрана, окно «Файлов» грузится долго
        let confirm = app.buttons["Сохранить"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 40), "окно сохранения копии не открылось")
        sleep(2)
        saveScreenshot("iphone-save-copy")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Копия сохранена"].waitForExistence(timeout: 15), "копия не сохранилась")
        saveScreenshot("iphone-copy-saved")
        app.terminate()
    }
}
