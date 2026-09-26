import XCTest

/// Аккаунт на iPhone (срез 5): регистрация с proof-of-work, код восстановления, аккаунт с устройствами, выход. Тестовый
/// аккаунт в конце удаляется.
///
/// Нужен сервер Melogold: `TEST_RUNNER_MELOGOLD_TEST_SERVER=http://127.0.0.1:8787` (локальный, `npm start` в
/// melogoldServer). На живом сервере тест аккаунты не создаёт: без переменной он пропускается.
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRegisterRecoveryCodeAccountAndSignOut() throws {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        let password = "longpassword2026"
        let app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server, "-MelogoldUITestPassword", password])
        signOutIfNeeded(app)
        saveScreenshot("account/01-settings-signed-out")

        app.buttons["account.register"].tap()
        let login = "ui\(Int.random(in: 10_000_000 ... 99_999_999))"
        let loginField = app.textFields["Логин"]
        XCTAssertTrue(loginField.waitForExistence(timeout: 5))
        loginField.tap()
        loginField.typeText(login)
        // Под нагрузкой симулятор теряет нажатия: дальше — то, что реально в поле
        let typed = loginField.value as? String ?? login
        // Тестовый аккаунт в конце удаляется (вход по API новым устройством)
        addTeardownBlock { try? await TestDevice.signIn(server: server, login: typed, password: password).deleteAccount(password: password) }
        saveScreenshot("account/02-register")
        app.buttons["account.register.submit"].tap()

        // Proof-of-work и регистрация, затем код восстановления — один раз, назад не уйти
        let code = app.staticTexts["account.recoveryCode.value"]
        if !code.waitForExistence(timeout: 60) {
            saveScreenshot("account/02b-after-submit")
            XCTFail("Нет экрана кода восстановления")
        }
        XCTAssertEqual(code.label.count, 24, "XXXX-XXXX-XXXX-XXXX-XXXX")
        XCTAssertFalse(app.buttons["account.recoveryCode.done"].isEnabled)
        saveScreenshot("account/03-recovery-code")
        dismissSavePassword(app)
        // Переключатель в строке формы: нажатие по его правому краю, где сам переключатель
        let saved = app.switches["account.recoveryCode.saved"]
        for _ in 0 ..< 3 where (saved.value as? String) != "1" {
            saved.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = app.buttons["account.recoveryCode.done"].waitForEnabled(timeout: 3)
        }
        saveScreenshot("account/03b-saved")
        XCTAssertTrue(app.buttons["account.recoveryCode.done"].isEnabled)
        app.buttons["account.recoveryCode.done"].tap()

        let overview = app.buttons["account.overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[typed].exists)
        saveScreenshot("account/04-settings-signed-in")

        overview.tap()
        XCTAssertTrue(app.staticTexts["Это устройство"].waitForExistence(timeout: 10))
        saveScreenshot("account/05-account")

        app.buttons["account.signOut"].tap()
        app.buttons["Выйти"].firstMatch.tap()
        XCTAssertTrue(app.buttons["account.signIn"].waitForExistence(timeout: 10))
    }
}

private extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
