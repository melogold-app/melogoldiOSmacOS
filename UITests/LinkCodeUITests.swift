import XCTest

/// Вход по коду на iPhone (задание 0017, API §4.6): оба режима нового устройства и «Показать код для нового
/// устройства» на вошедшем. Второе устройство — `TestDevice` по API. Тестовый аккаунт в конце удаляется.
///
/// Нужен сервер Melogold: `TEST_RUNNER_MELOGOLD_TEST_SERVER=http://127.0.0.1:8787` (локальный). На живом сервере
/// тест аккаунты не создаёт: без переменной он пропускается.
final class LinkCodeUITests: XCTestCase {
    private let password = "linkcode-pass-2026"

    override func setUp() {
        continueAfterFailure = false
    }

    private func server() throws -> String {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        return server
    }

    /// Аккаунт с одним устройством («Pixel») — это оно одобряет вход; в конце аккаунт удаляется.
    @MainActor
    private func approver(_ server: String) async throws -> (device: TestDevice, login: String) {
        let login = "code\(Int.random(in: 10_000_000 ... 99_999_999))"
        let device = try await TestDevice.register(server: server, login: login, password: password, name: "Google Pixel 8", platform: "android")
        let password = password
        addTeardownBlock { try? await device.deleteAccount(password: password) }
        return (device, login)
    }

    @MainActor
    private func openSignInByCode(_ server: String, arguments: [String] = []) -> XCUIApplication {
        let app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server] + arguments)
        signOutIfNeeded(app)
        app.buttons["account.signIn"].tap()
        let byCode = app.buttons["account.signIn.code"]
        XCTAssertTrue(byCode.waitForExistence(timeout: 5), "нет «Войти по коду» на экране входа")
        byCode.tap()
        return app
    }

    /// «Код для входа: K, 7, Q, X, M, 2, P, D» → `K7QXM2PD`.
    private func code(from label: String) -> String {
        String(label.split(separator: ":").last ?? "").filter { $0.isLetter || $0.isNumber }
    }

    private func number(from label: String) -> String {
        label.filter(\.isNumber)
    }

    @MainActor
    func testNewDeviceShowsCodeAndSignsIn() async throws {
        let server = try server()
        let (pixel, login) = try await approver(server)
        let app = openSignInByCode(server)

        let codeText = app.staticTexts["account.link.userCode"]
        XCTAssertTrue(codeText.waitForExistence(timeout: 15), "код не показан")
        XCTAssertTrue(app.staticTexts["На устройстве, где вы уже вошли, откройте Аккаунт › Добавить устройство и введите этот код"].exists)
        saveScreenshot("link/01-code")
        let userCode = code(from: codeText.label)
        XCTAssertEqual(userCode.count, 8, codeText.label)

        let (linkId, choices) = try await pixel.resolveLink(userCode: userCode)
        XCTAssertEqual(choices.count, 3)
        let numberText = app.staticTexts["account.link.verifyCode"]
        XCTAssertTrue(numberText.waitForExistence(timeout: 30), "число не показано")
        XCTAssertTrue(app.staticTexts["Выберите это число на «Google Pixel 8»"].exists)
        XCTAssertTrue(app.staticTexts["Вход в аккаунт \(login)"].exists)
        saveScreenshot("link/02-number")
        let verifyCode = number(from: numberText.label)
        XCTAssertTrue(choices.contains(verifyCode))

        try await pixel.approveLink(linkId, verifyCode: verifyCode)
        XCTAssertTrue(app.buttons["account.overview"].waitForExistence(timeout: 40), "вход по коду не завершился")
        XCTAssertTrue(app.staticTexts[login].exists)
        saveScreenshot("link/03-signed-in")
    }

    @MainActor
    func testNewDeviceEntersInviteCode() async throws {
        let server = try server()
        let (pixel, login) = try await approver(server)
        let invite = try await pixel.createInvite()
        let app = openSignInByCode(server)

        let haveCode = app.buttons["У меня есть код с другого устройства"]
        XCTAssertTrue(haveCode.waitForExistence(timeout: 15))
        haveCode.tap()
        let field = app.textFields["account.link.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(invite.userCode.lowercased().replacingOccurrences(of: "-", with: " "))
        saveScreenshot("link/04-enter-code")
        app.buttons["Продолжить"].tap()

        let numberText = app.staticTexts["account.link.verifyCode"]
        XCTAssertTrue(numberText.waitForExistence(timeout: 20), "число не показано")
        XCTAssertTrue(app.staticTexts["Вход в аккаунт \(login)"].exists)
        saveScreenshot("link/05-invite-number")
        let verifyCode = number(from: numberText.label)

        var details = try await pixel.link(invite.linkId)
        for _ in 0 ..< 20 where details.status != "claimed" {
            try await Task.sleep(for: .milliseconds(500))
            details = try await pixel.link(invite.linkId)
        }
        XCTAssertTrue(details.choices.contains(verifyCode))
        try await pixel.approveLink(invite.linkId, verifyCode: verifyCode)
        XCTAssertTrue(app.buttons["account.overview"].waitForExistence(timeout: 40), "вход по приглашению не завершился")
    }

    @MainActor
    func testWrongModeCodeIsExplained() async throws {
        let server = try server()
        _ = try await approver(server)
        let app = openSignInByCode(server)
        let codeText = app.staticTexts["account.link.userCode"]
        XCTAssertTrue(codeText.waitForExistence(timeout: 15))
        // Свой же код (режим request) в поле «код с другого устройства» — link_wrong_mode словами
        let ownCode = code(from: codeText.label)
        app.buttons["У меня есть код с другого устройства"].tap()
        let field = app.textFields["account.link.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(ownCode)
        app.buttons["Продолжить"].tap()
        let explained = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Код устарел")).firstMatch
        let wrongMode = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Это код нового устройства")).firstMatch
        // Показанный код отменён при переключении — сервер отвечает 410 link_expired (API §4.6), не wrong_mode
        XCTAssertTrue(explained.waitForExistence(timeout: 15) || wrongMode.exists, "отказ не объяснён")
        XCTAssertEqual(field.value as? String, ownCode, "ввод не должен стираться")
        saveScreenshot("link/06-refused-code")
    }

    @MainActor
    func testSignedInDeviceShowsCodeForNewDevice() async throws {
        let server = try server()
        let (_, login) = try await approver(server)
        let app = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server, "-MelogoldUITestPassword", password])
        signIn(app, login: login)
        app.buttons["account.overview"].tap()
        XCTAssertTrue(app.staticTexts["Это устройство"].waitForExistence(timeout: 10))
        // «Добавить устройство» ниже списка устройств: форма создаёт строки, только когда они на экране
        let add = app.buttons["Добавить устройство"]
        for _ in 0 ..< 5 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        app.buttons["account.addDevice.showCode"].tap()

        let codeText = app.staticTexts["account.link.userCode"]
        XCTAssertTrue(codeText.waitForExistence(timeout: 15), "код приглашения не показан")
        XCTAssertTrue(app.staticTexts["Ждём новое устройство…"].exists)
        saveScreenshot("link/07-invite-code")

        let claimed = try await TestDevice.claim(server: server, userCode: code(from: codeText.label), name: "Windows test")
        let choice = app.buttons["Число \(claimed.verifyCode)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "карточка нового устройства не показана")
        XCTAssertTrue(app.staticTexts["Windows test"].exists)
        saveScreenshot("link/08-invite-approval")
        choice.tap()
        XCTAssertTrue(app.staticTexts["«Windows test» вошло в аккаунт"].waitForExistence(timeout: 15))
        let answer = try await TestDevice.poll(server: server, pollSecret: claimed.pollSecret, knownStatus: "claimed")
        XCTAssertEqual(answer.status, "completed")
        XCTAssertTrue(answer.hasSession)
        saveScreenshot("link/09-invite-done")
    }
}
