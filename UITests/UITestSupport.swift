import CryptoKit
import XCTest

/// Общие приёмы UI-тестов: запуск с нужным разделом и языком, снимки экрана в папку срезов.
///
/// Снимки пишутся, только если задана переменная `MELOGOLD_SHOTS_DIR` (xcodebuild передаёт её тестам
/// как `TEST_RUNNER_MELOGOLD_SHOTS_DIR=…`). Симулятор видит файловую систему Mac, поэтому путь — обычный путь Mac.
extension XCTestCase {
    @MainActor
    func launchApp(section: String? = nil, language: String = "en", arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var launch = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        if let section { launch += ["-shell.lastTab", section] }
        // Mac общий, и рядом спят: симулятор играет через динамики Mac — звук в тестах всегда выключен.
        launch += ["-MelogoldMute", "YES"]
        // Отладочный прокси: при VPN на Mac симулятор не разрешает имена сам (docs/STATUS.md).
        if let proxy = ProcessInfo.processInfo.environment["MELOGOLD_PROXY"], !proxy.isEmpty {
            launch += ["-MelogoldDebugProxy", proxy]
        }
        app.launchArguments = launch + arguments
        app.launch()
        return app
    }

    /// После регистрации или входа iOS предлагает сохранить пароль в «Пароли»: окно системы закрывает экран.
    @MainActor
    func dismissSavePassword(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Not Now", "Не сейчас"] {
            for candidate in [app.buttons[label], springboard.buttons[label]] where candidate.waitForExistence(timeout: 6) {
                candidate.tap()
                // Окно уезжает с анимацией: пока оно на экране, нажатия попадают в него
                _ = candidate.waitForNonExistence(timeout: 5)
                sleep(1)
                return
            }
        }
    }

    /// После прошлого запуска мог остаться вход: сеанс лежит в Keychain симулятора. Экран — «Настройки».
    @MainActor
    func signOutIfNeeded(_ app: XCUIApplication) {
        let overview = app.buttons["account.overview"]
        guard overview.waitForExistence(timeout: 3) else { return }
        overview.tap()
        // С несколькими устройствами «Выйти» ниже края экрана
        let signOut = app.buttons["account.signOut"]
        _ = signOut.waitForExistence(timeout: 5)
        for _ in 0 ..< 5 where !(signOut.exists && signOut.isHittable) { app.swipeUp() }
        signOut.tap()
        app.buttons["Выйти"].firstMatch.tap()
        _ = app.buttons["account.signIn"].waitForExistence(timeout: 10)
    }

    /// Вход в готовый аккаунт на экране «Настройки»: пароль — отладочной подстановкой (`-MelogoldUITestPassword` при
    /// запуске), логин — набором.
    @MainActor
    func signIn(_ app: XCUIApplication, login: String) {
        signOutIfNeeded(app)
        app.buttons["account.signIn"].tap()
        let loginField = app.textFields["Логин"]
        XCTAssertTrue(loginField.waitForExistence(timeout: 5))
        loginField.tap()
        loginField.typeText(login)
        XCTAssertEqual(loginField.value as? String, login, "симулятор потерял символы логина")
        app.buttons["account.signIn.submit"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.buttons["account.overview"].waitForExistence(timeout: 20), "вход не прошёл")
    }

    @MainActor
    func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["MELOGOLD_SHOTS_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }
}

/// Другое устройство аккаунта, которым тест управляет по API сервера (API §4.3, §4.8).
struct TestDevice: Sendable {
    let server: String
    let token: String

    static func register(server: String, login: String, password: String, name: String, platform: String) async throws -> TestDevice {
        let challenge = try await call(server, "GET", "/auth/register/challenge")
        let text = try XCTUnwrap(challenge["challenge"] as? String)
        let bits = try XCTUnwrap(challenge["bits"] as? Int)
        let session = try await call(server, "POST", "/auth/register", body: [
            "login": login, "password": password,
            "device": ["hwid": randomHwid(), "name": name, "platform": platform, "osVersion": "16", "model": name, "clientVersion": "0.1.2"],
            "pow": ["challenge": text, "nonce": solve(text, bits: bits)],
        ])
        let tokens = try XCTUnwrap(session["tokens"] as? [String: Any])
        return TestDevice(server: server, token: try XCTUnwrap(tokens["accessToken"] as? String))
    }

    /// Вход в готовый аккаунт новым устройством — чтобы удалить тестовый аккаунт в конце.
    static func signIn(server: String, login: String, password: String) async throws -> TestDevice {
        let session = try await call(server, "POST", "/auth/login", body: [
            "login": login, "password": password,
            "device": ["hwid": randomHwid(), "name": "UI test cleanup", "platform": "ios"],
        ])
        let tokens = try XCTUnwrap(session["tokens"] as? [String: Any])
        return TestDevice(server: server, token: try XCTUnwrap(tokens["accessToken"] as? String))
    }

    private static func randomHwid() -> String {
        SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Прослушивания этого устройства за последние минуты: `play.add` с метаданными треков через `spacing` секунд, последнее —
    /// `spacing` назад. Возвращает курсор потока истории после них — с него `changes(since:)` читает, что пришло потом.
    @discardableResult
    func play(_ tracks: [(videoId: String, title: String, artist: String)], spacing: TimeInterval = 300) async throws -> String {
        let now = Date()
        let ops: [[String: Any]] = tracks.enumerated().map { index, track in
            let at = Self.iso(now.addingTimeInterval(-Double(tracks.count - index) * spacing))
            return [
                "opId": UUID().uuidString.lowercased(), "kind": "play.add", "at": at, "videoId": track.videoId, "playedAt": at,
                "playTimeMs": 200_000, "history": true, "playtime": true,
                "tracks": [["videoId": track.videoId, "title": track.title, "artistsText": track.artist, "durationMs": 240_000,
                            "thumbnailUrl": "https://i.ytimg.com/vi/\(track.videoId)/hqdefault.jpg", "videoType": "video"]],
            ]
        }
        let response = try await sync(ops: ops)
        let statuses = (response["results"] as? [[String: Any]] ?? []).compactMap { $0["status"] as? String }
        XCTAssertEqual(statuses, Array(repeating: "applied", count: tracks.count))
        return try XCTUnwrap(response["cursor"] as? String)
    }

    /// «Убрать из истории» на этом устройстве (`history.forget`): события трека до сейчас и его общее время — на всех
    /// устройствах аккаунта.
    func forget(_ videoId: String) async throws {
        let now = Self.iso(Date())
        let response = try await sync(ops: [[
            "opId": UUID().uuidString.lowercased(), "kind": "history.forget", "at": now, "videoId": videoId,
            "eventsBefore": now, "resetTotal": true,
        ]])
        let statuses = (response["results"] as? [[String: Any]] ?? []).compactMap { $0["status"] as? String }
        XCTAssertEqual(statuses, ["applied"])
    }

    /// Вход нового устройства по коду (API §4.6, режим `request`): это устройство находит привязку по коду, который
    /// показывает новое, и получает три числа на выбор.
    func resolveLink(userCode: String) async throws -> (linkId: String, choices: [String]) {
        let details = try await Self.call(server, "POST", "/auth/me/links/resolve", token: token, body: ["userCode": userCode])
        return (try XCTUnwrap(details["linkId"] as? String), details["verifyChoices"] as? [String] ?? [])
    }

    /// Одобрить вход числом, которое показывает новое устройство.
    func approveLink(_ linkId: String, verifyCode: String) async throws {
        let decision = try await Self.call(server, "POST", "/auth/me/links/\(linkId)/approve", token: token, body: ["verifyCode": verifyCode])
        XCTAssertEqual(decision["status"] as? String, "approved")
    }

    /// Изменения истории после `cursor` (API §4.8): `plays`, `playStats`, `playForgets` и новый курсор.
    func changes(since cursor: String) async throws -> [String: Any] {
        try await sync(ops: [], cursor: cursor)
    }

    /// Какие треки сейчас в истории аккаунта на сервере: поток истории с начала.
    func playedVideoIds() async throws -> [String] {
        var cursor = ""
        var ids: [String] = []
        while true {
            let page = try await sync(ops: [], cursor: cursor)
            ids += (page["plays"] as? [[String: Any]] ?? []).compactMap { $0["videoId"] as? String }
            cursor = page["cursor"] as? String ?? ""
            if page["hasMore"] as? Bool != true { return ids }
        }
    }

    /// Сколько прослушиваний аккаунта сейчас на сервере.
    func playCount() async throws -> Int {
        try await playedVideoIds().count
    }

    func deleteAccount(password: String) async throws {
        _ = try await Self.call(server, "POST", "/auth/me/delete", token: token, body: ["password": password])
    }

    private func sync(ops: [[String: Any]], cursor: String = "") async throws -> [String: Any] {
        try await Self.call(server, "POST", "/sync", token: token, body: ["cursor": cursor, "streams": ["history"], "ops": ops])
    }

    private static func call(_ server: String, _ method: String, _ path: String, token: String? = nil,
                             body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + path)))
        request.httpMethod = method
        request.setValue("melogold-android/0.1.2", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Sync-Protocol")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw NSError(domain: "TestDevice", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))"])
        }
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    /// Proof-of-work регистрации (API §4.3): `sha256(challenge + ":" + nonce)` начинается с `bits` нулевых битов.
    private static func solve(_ challenge: String, bits: Int) -> String {
        var nonce = 0
        while true {
            let digest = Array(SHA256.hash(data: Data("\(challenge):\(nonce)".utf8)))
            var zeros = 0
            for byte in digest {
                if byte == 0 { zeros += 8; continue }
                zeros += byte.leadingZeroBitCount
                break
            }
            if zeros >= bits { return String(nonce) }
            nonce += 1
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
