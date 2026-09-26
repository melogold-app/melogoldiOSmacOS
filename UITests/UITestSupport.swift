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

    /// Прослушивания этого устройства за последние минуты: `play.add` с метаданными треков.
    func play(_ tracks: [(videoId: String, title: String, artist: String)]) async throws {
        let now = Date()
        let ops: [[String: Any]] = tracks.enumerated().map { index, track in
            let at = Self.iso(now.addingTimeInterval(-Double(tracks.count - index) * 300))
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
    }

    /// Сколько прослушиваний аккаунта сейчас на сервере: поток истории с начала.
    func playCount() async throws -> Int {
        var cursor = ""
        var count = 0
        while true {
            let page = try await sync(ops: [], cursor: cursor)
            count += (page["plays"] as? [Any])?.count ?? 0
            cursor = page["cursor"] as? String ?? ""
            if page["hasMore"] as? Bool != true { return count }
        }
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
