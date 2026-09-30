import XCTest

/// Пульт (задание 0020): iPhone играет (звук выключен) и сообщает серверу, что играет; «Pixel» по API видит его в
/// списке устройств, ставит на паузу и меняет громкость командами. Тестовый аккаунт в конце удаляется.
///
/// Нужен сервер Melogold 0.1.2+: `TEST_RUNNER_MELOGOLD_TEST_SERVER=http://127.0.0.1:8787` (локальный). Без переменной
/// тест пропускается; на живом сервере аккаунты не создаются.
final class RemoteUITests: XCTestCase {
    private let password = "remote-pass-2026"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOtherDeviceSeesAndControlsThisOne() async throws {
        let server = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"] ?? ""
        try XCTSkipIf(server.isEmpty, "Нужен сервер: TEST_RUNNER_MELOGOLD_TEST_SERVER")
        let login = "remote\(Int.random(in: 10_000_000 ... 99_999_999))"
        let pixel = try await TestDevice.register(server: server, login: login, password: password, name: "Google Pixel 8", platform: "android")
        let password = password
        addTeardownBlock { try? await pixel.deleteAccount(password: password) }

        // Вход на iPhone, затем запуск с воспроизведением первого найденного трека (звук выключен launchApp)
        let signIn = launchApp(section: "settings", language: "ru", arguments: ["-server.url", server, "-MelogoldUITestPassword", password])
        self.signIn(signIn, login: login)
        signIn.terminate()
        let app = launchApp(section: "search", language: "ru", arguments: [
            "-server.url", server, "-MelogoldSearch", "Rick Astley Never Gonna Give You Up", "-MelogoldPlayFirst", "YES",
        ])
        addTeardownBlock { await MainActor.run { app.terminate() } }

        // Сервер знает, что играет на iPhone, и iPhone разрешил управление (поток с remote=1)
        var iphone: String?
        for _ in 0 ..< 60 {
            if let state = try await pixel.playbackState(), state.playing,
               let device = try await pixel.playbackDevices().first(where: { $0.deviceId == state.deviceId && $0.controllable }) {
                iphone = device.deviceId
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        let target = try XCTUnwrap(iphone, "iPhone не сообщил, что играет, или не разрешил управление")
        saveScreenshot("remote/01-playing")

        try await pixel.command(target, "pause")
        var paused = false
        for _ in 0 ..< 20 {
            if let state = try await pixel.playbackState(), state.deviceId == target, !state.playing { paused = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(paused, "пауза с другого устройства не дошла")
        XCTAssertTrue(app.staticTexts["Управляет «Google Pixel 8»"].waitForExistence(timeout: 5), "нет плашки «Управляет …»")
        saveScreenshot("remote/02-paused-by-pixel")

        try await pixel.command(target, "volume", volume: 30)
        try await pixel.command(target, "play")
        var volume: Int?
        for _ in 0 ..< 20 {
            if let state = try await pixel.playbackState(), state.deviceId == target, state.playing, state.volume == 30 { volume = 30; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(volume, 30, "громкость и продолжение не дошли")
    }
}
