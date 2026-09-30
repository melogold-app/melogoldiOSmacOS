import XCTest

/// Слайс S6 на iPhone: мультивыбор (задание 0013), «Сведения о треке» (0014), «Итоги» и «Итоги года» (0018), «Мои ссылки» и
/// «Плейлист по ссылке» (0019). Звук выключен, тестовые аккаунты в конце удаляются.
///
/// «Мои ссылки» и «Плейлист по ссылке» нужен сервер Melogold: `TEST_RUNNER_MELOGOLD_TEST_SERVER=http://127.0.0.1:8797`
/// (локальный). Без переменной эти тесты пропускаются; на живом сервере аккаунтов они не создают.
final class SliceS6UITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func contains(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    /// Своя база у теста: снимки не смешиваются с тем, что осталось после прошлых запусков.
    private func dataDir(_ name: String) -> [String] {
        ["-MelogoldDataDir", "/private/tmp/melogold-s6-\(name)-\(UUID().uuidString.prefix(6))"]
    }

    /// «Аккаунт» из «Настроек»: после входа список ещё перерисовывается, и первое нажатие иногда пропадает.
    @MainActor
    private func openAccount(_ app: XCUIApplication) {
        for _ in 0 ..< 3 {
            let overview = app.buttons["account.overview"]
            _ = overview.waitForExistence(timeout: 15)
            overview.tap()
            if app.staticTexts["Это устройство"].waitForExistence(timeout: 8) { return }
        }
        saveScreenshot("s6/debug-account")
        XCTFail("аккаунт не открылся")
    }

    /// Строка формы или списка по идентификатору — какого бы вида элемент ни был.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    // MARK: - Мультивыбор и сведения о треке (без сети)

    /// История с двумя своими прослушиваниями: «Выбрать», две строки, панель «Выбрано: 2», «Новый плейлист…» с названием
    /// по умолчанию; затем «Изменить сведения…» — новое название видно в строке.
    @MainActor
    func testMultiSelectAndTrackDetails() throws {
        let app = launchApp(section: "library", language: "ru", arguments: dataDir("select") + ["-MelogoldSeedPlays", "YES", "-MelogoldOpen", "allTracks"])
        let first = app.cells.containing(contains("Bohemian Rhapsody")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let second = app.cells.containing(contains("Smells Like Teen Spirit")).firstMatch
        XCTAssertTrue(second.exists)

        // Режим выбора
        app.buttons["Выбрать"].tap()
        XCTAssertTrue(app.staticTexts["Выбрано: 0"].waitForExistence(timeout: 5))
        first.tap()
        second.tap()
        XCTAssertTrue(app.staticTexts["Выбрано: 2"].waitForExistence(timeout: 5))
        saveScreenshot("s6/select-iphone-mode")

        // «Новый плейлист…»: окно с названием
        app.buttons["Ещё"].firstMatch.tap()
        let newPlaylist = app.buttons["Новый плейлист…"]
        XCTAssertTrue(newPlaylist.waitForExistence(timeout: 5))
        saveScreenshot("s6/select-iphone-menu")
        newPlaylist.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        saveScreenshot("s6/select-iphone-new-playlist")
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(" из истории")
        alert.buttons["Создать"].tap()
        XCTAssertTrue(app.staticTexts.containing(contains("Плейлист «")).firstMatch.waitForExistence(timeout: 5), "нет плашки о плейлисте")
        saveScreenshot("s6/select-iphone-created")

        // Выйти из режима выбора и открыть «Изменить сведения…» у первой строки
        if app.buttons["Готово"].exists { app.buttons["Готово"].tap() }
        let more = app.cells.containing(contains("Bohemian Rhapsody")).firstMatch.buttons["Ещё"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let edit = app.buttons["Изменить сведения…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "нет пункта «Изменить сведения…»")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Сведения о треке"].waitForExistence(timeout: 5))
        let title = app.textFields["details.field.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        saveScreenshot("s6/details-empty")
        title.tap()
        title.typeText("Богемская рапсодия")
        app.textFields["details.field.artist"].tap()
        app.textFields["details.field.artist"].typeText("Куин")
        app.textFields["details.field.album"].tap()
        app.textFields["details.field.album"].typeText("Ночь в опере")
        saveScreenshot("s6/details-filled")
        app.buttons["Сохранить"].firstMatch.tap()

        // Правка видна в строке
        let renamed = app.cells.containing(contains("Богемская рапсодия")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "правка не видна в списке")
        XCTAssertTrue(renamed.staticTexts.containing(contains("Куин")).firstMatch.exists || renamed.label.contains("Куин"))
        saveScreenshot("s6/details-in-list")

        // «Как на YouTube» снимает правку
        renamed.buttons["Ещё"].tap()
        app.buttons["Изменить сведения…"].tap()
        XCTAssertTrue(app.buttons["Как на YouTube"].waitForExistence(timeout: 5))
        app.buttons["Как на YouTube"].tap()
        XCTAssertTrue(app.cells.containing(contains("Bohemian Rhapsody")).firstMatch.waitForExistence(timeout: 10))
    }

    // MARK: - Итоги (без сети)

    @MainActor
    func testStatsPeriodsAndYearInReview() throws {
        let app = launchApp(section: "library", language: "ru", arguments: dataDir("stats") + ["-MelogoldSeedStats", "YES", "-MelogoldOpen", "stats"])
        let time = app.staticTexts["stats.time"]
        XCTAssertTrue(time.waitForExistence(timeout: 30), "нет числа времени прослушивания")
        XCTAssertTrue(app.staticTexts["stats.windowTitle"].exists)
        saveScreenshot("s6/stats-month-top")
        app.swipeUp()
        saveScreenshot("s6/stats-month-charts")

        // Стрелка назад листает месяц
        let title = app.staticTexts["stats.windowTitle"]
        for _ in 0 ..< 3 where !title.isHittable { app.swipeDown() }
        let before = title.label
        app.buttons["stats.previous"].tap()
        XCTAssertNotEqual(app.staticTexts["stats.windowTitle"].label, before)
        XCTAssertFalse(app.buttons["stats.next"].isEnabled == false, "вперёд после шага назад доступно")

        // Год и «Итоги года»
        app.buttons["Год"].firstMatch.tap()
        let wrapped = app.buttons["stats.wrapped"]
        XCTAssertTrue(wrapped.waitForExistence(timeout: 10))
        saveScreenshot("s6/stats-year")
        wrapped.tap()
        XCTAssertTrue(app.staticTexts["wrapped.minutes"].waitForExistence(timeout: 15), "нет карточки минут")
        saveScreenshot("s6/wrapped-1-minutes")
        for index in 2 ... 6 where app.buttons["Дальше"].isEnabled {
            app.buttons["Дальше"].tap()
            sleep(1)
            saveScreenshot("s6/wrapped-\(index)")
        }
        XCTAssertTrue(app.buttons["Поделиться"].waitForExistence(timeout: 15), "нет «Поделиться»")
        app.buttons["Закрыть"].firstMatch.tap()
        XCTAssertTrue(app.buttons["stats.wrapped"].waitForExistence(timeout: 5))
    }

    // MARK: - Ссылки (нужен сервер)

    @MainActor
    func testMyLinksAndSharedPlaylist() async throws {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        let login = "shr\(Int.random(in: 10_000_000 ... 99_999_999))"
        let password = "s-\(UUID().uuidString.lowercased())"
        let pixel = try await TestDevice.register(server: server, login: login, password: password, name: "Pixel 9", platform: "android")
        addTeardownBlock { try? await pixel.deleteAccount(password: password) }
        let share = try await pixel.createShare(name: "Концерт в клубе", tracks: [
            ("JGwWNGJdvx8", "Shape of You", "Ed Sheeran", "Концерт"),
            ("OPf0YbXqDm0", "Uptown Funk", "Mark Ronson", "Концерт"),
            ("fJ9rUzIMcZQ", "Bohemian Rhapsody", "Queen", nil),
        ])
        let deepLink = "melogold://share?v=1&url=\(server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? server)&id=\(share.shareId)"

        // Вход и «Мои ссылки»
        var app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server, "-MelogoldUITestPassword", password])
        signIn(app, login: login)
        openAccount(app)
        let myLinks = element(app, "account.myShares")
        for _ in 0 ..< 6 where !(myLinks.exists && myLinks.isHittable) { app.swipeUp() }
        if !myLinks.waitForExistence(timeout: 10) { saveScreenshot("s6/debug-my-links") }
        XCTAssertTrue(myLinks.exists)
        myLinks.tap()
        let row = app.cells.containing(contains("Концерт в клубе")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "снимок не в «Моих ссылках»")
        XCTAssertTrue(row.staticTexts.containing(contains("3 трека")).firstMatch.exists)
        saveScreenshot("s6/my-links")
        app.terminate()

        // Открыть ссылку Melogold без входа в этот сервер: «Плейлист по ссылке»
        app = launchApp(section: "library", language: "ru", arguments: ["-server.url", server, "-MelogoldOpenURL", deepLink])
        XCTAssertTrue(app.staticTexts["Концерт в клубе"].firstMatch.waitForExistence(timeout: 20), "экран ссылки не открылся")
        let save = app.buttons["shared.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.containing(contains("Uptown Funk")).firstMatch.exists)
        saveScreenshot("s6/shared-playlist")
        save.tap()
        XCTAssertTrue(app.staticTexts["Сохранено в Библиотеку"].firstMatch.waitForExistence(timeout: 10))
        saveScreenshot("s6/shared-playlist-saved")
        app.terminate()

        // Удалить ссылку в «Моих ссылках»: она перестаёт открываться
        app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server])
        openAccount(app)
        let again = element(app, "account.myShares")
        for _ in 0 ..< 6 where !(again.exists && again.isHittable) { app.swipeUp() }
        again.tap()
        let target = app.cells.containing(contains("Концерт в клубе")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        target.swipeLeft()
        app.buttons["Удалить ссылку"].firstMatch.tap()
        saveScreenshot("s6/my-links-delete-confirm")
        app.buttons["Удалить ссылку"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Ссылка удалена"].firstMatch.waitForExistence(timeout: 10))
        var remaining = try await pixel.shareIds()
        for _ in 0 ..< 10 where !remaining.isEmpty {
            try await Task.sleep(for: .seconds(1))
            remaining = try await pixel.shareIds()
        }
        XCTAssertTrue(remaining.isEmpty, "сервер не удалил снимок")
        app.terminate()

        app = launchApp(section: "library", language: "ru", arguments: ["-server.url", server, "-MelogoldOpenURL", deepLink])
        XCTAssertTrue(app.staticTexts["Ссылка удалена или неверна"].firstMatch.waitForExistence(timeout: 20))
        saveScreenshot("s6/shared-playlist-gone")
        app.terminate()

        // Выход: устройство уходит из аккаунта
        app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server])
        signOutIfNeeded(app)
        app.terminate()
    }
}
