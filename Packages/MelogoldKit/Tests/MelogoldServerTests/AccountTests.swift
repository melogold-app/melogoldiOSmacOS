import CryptoKit
import Foundation
import MelogoldCore
import MelogoldData
import Testing
@testable import MelogoldServer

/// Сеанс: вход, обновление токенов (single flight, один повтор), конец сеанса и регистрация с PoW (API §1.7, §4.3).
@MainActor
@Suite("Account — сеанс на сервере-заглушке")
struct AccountTests {
    nonisolated static let serverId = "6f1c2c0e-8a3b-4f7e-9c1d-2b5e7a9f0c11"
    static let identity = DeviceIdentity(platform: "ios", platformId: "pid", name: "Test iPhone", osVersion: "26.0.0", model: "iPhone18,1", clientVersion: "0.1.0")

    let server = StubServer()
    let secrets = MemorySecretStore()

    private func account(session: StoredSession? = nil) -> Account {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        settings.serverURL = server.baseURL
        if let session { secrets.set(try! JSONEncoder().encode(session), for: Account.sessionAccount) }
        return Account(settings: settings, secrets: secrets, identity: Self.identity, urlSession: StubServer.session())
    }

    private func stored(expiresIn seconds: TimeInterval) -> StoredSession {
        StoredSession(
            serverURL: server.baseURL, serverId: Self.serverId, userId: "u1", login: "maxim", deviceId: "d1",
            accessToken: "old-access", accessTokenExpiresAt: Date().addingTimeInterval(seconds), refreshToken: "mgrt1.old.x"
        )
    }

    @Test func signInStoresSessionAndIdentifiesDevice() async throws {
        server.on("GET", "/server/info") { _ in (200, Fixtures.serverInfo(pow: false)) }
        server.on("POST", "/auth/login") { _ in (200, Fixtures.authSession(recoveryCode: nil)) }

        let account = account()
        try await account.signIn(login: "Maxim", password: "две собаки и кот")

        #expect(account.state == .signedIn(login: "maxim"))
        let login = try #require(server.requests("POST", "/auth/login").first)
        #expect(login.headers["User-Agent"] == "melogold-ios/0.1.0")
        let device = try #require(login.json["device"] as? [String: Any])
        #expect(device["platform"] as? String == "ios")
        #expect(device["hwid"] as? String == DeviceIdentity.hwid(platformId: "pid", serverId: Self.serverId))
        // Сеанс переживает перезапуск: он в хранилище секретов
        #expect(self.account().state == .signedIn(login: "maxim"))
    }

    @Test func expiredTokenIsRefreshedOnceForConcurrentCalls() async throws {
        server.on("POST", "/auth/refresh") { _ in (200, Fixtures.refreshResponse) }
        server.on("GET", "/auth/me/devices") { request in
            request.headers["Authorization"] == "Bearer new-access" ? (200, Fixtures.deviceList) : (401, Fixtures.error("access_token_invalid", 401))
        }
        let account = account(session: stored(expiresIn: 30))

        async let first = account.devices()
        async let second = account.devices()
        let (a, b) = try await (first, second)

        #expect(a.devices.count == 1 && b.devices.count == 1)
        #expect(server.requests("POST", "/auth/refresh").count == 1)
        #expect(account.session?.refreshToken == "mgrt1.new.x")
    }

    @Test func expiredAccessIsRetriedOnceAfterRefresh() async throws {
        server.on("POST", "/auth/refresh") { _ in (200, Fixtures.refreshResponse) }
        server.on("GET", "/auth/me/devices") { request in
            request.headers["Authorization"] == "Bearer new-access" ? (200, Fixtures.deviceList) : (401, Fixtures.error("access_token_expired", 401))
        }
        let account = account(session: stored(expiresIn: 3600))

        let list = try await account.devices()

        #expect(list.devices.count == 1)
        #expect(server.requests("GET", "/auth/me/devices").count == 2)
        #expect(server.requests("POST", "/auth/refresh").count == 1)
    }

    @Test func reusedRefreshTokenEndsSession() async throws {
        server.on("POST", "/auth/refresh") { _ in (401, Fixtures.error("refresh_token_reused", 401)) }
        let account = account(session: stored(expiresIn: 0))

        await #expect(throws: APIError.self) { try await account.devices() }

        #expect(account.state == .authRequired(login: "maxim"))
        #expect(account.endedReason == "refresh_token_reused")
        #expect(secrets.data(Account.sessionAccount) == nil)
    }

    @Test func revokedSessionEndsSession() async throws {
        server.on("GET", "/auth/me") { _ in (401, Fixtures.error("session_revoked", 401)) }
        let account = account(session: stored(expiresIn: 3600))

        await #expect(throws: APIError.self) { try await account.me() }

        #expect(account.state == .authRequired(login: "maxim"))
    }

    @Test func networkErrorKeepsSession() async throws {
        let account = account(session: StoredSession(
            serverURL: "https://unknown.invalid", serverId: Self.serverId, userId: "u1", login: "maxim", deviceId: "d1",
            accessToken: "a", accessTokenExpiresAt: Date().addingTimeInterval(3600), refreshToken: "r"
        ))

        await #expect(throws: APIError.self) { try await account.devices() }

        #expect(account.state == .signedIn(login: "maxim"))
    }

    @Test func registrationSolvesProofOfWork() async throws {
        server.on("GET", "/server/info") { _ in (200, Fixtures.serverInfo(pow: true)) }
        server.on("GET", "/auth/register/challenge") { _ in
            (200, #"{"challenge":"mgpow1.eyJ0ZXN0IjoxfQ.abc","bits":10,"expiresAt":"2030-01-01T00:00:00.000Z"}"#)
        }
        server.on("POST", "/auth/register") { _ in (201, Fixtures.authSession(recoveryCode: "7KQ2-MX9D-4TNP-B8RW-3HZF")) }
        let account = account()

        let session = try await account.register(login: "maxim", password: "длинный пароль")

        #expect(session.recoveryCode == "7KQ2-MX9D-4TNP-B8RW-3HZF")
        let body = try #require(server.requests("POST", "/auth/register").first?.json)
        let pow = try #require(body["pow"] as? [String: String])
        let digest = SHA256.hash(data: Data("\(pow["challenge"]!):\(pow["nonce"]!)".utf8))
        #expect(ProofOfWork.leadingZeroBits(digest) >= 10)
        #expect(account.state == .signedIn(login: "maxim"))
    }
}

/// Ответы сервера-заглушки. Вне `@MainActor`: их читают обработчики заглушки в потоках URLSession.
enum Fixtures {

    static func serverInfo(pow: Bool) -> String {
        let powFeature = pow ? #","registrationPow":{"version":1}"# : ""
        return #"{"software":"melogold-server","version":"0.1.0","revision":"abc1234","apiVersion":1,"minApiVersion":1,"serverId":""# + AccountTests.serverId
            + #"","instanceName":"Melogold","publicUrl":null,"secureTransport":true,"registration":"open","features":{"sync":{"protocol":1,"minProtocol":1,"kinds":[],"streams":["library","history"]}"#
            + powFeature + #"},"limits":null,"links":{"source":"x","privacy":null,"contact":null},"serverTime":"2026-09-25T10:00:00.000Z"}"#
    }

    static func authSession(recoveryCode: String?) -> String {
        let code = recoveryCode.map { "\"\($0)\"" } ?? "null"
        return #"{"user":{"id":"u1","login":"maxim","createdAt":"2026-09-23T10:00:00.000Z","passwordChangedAt":"2026-09-23T10:00:00.000Z","recoveryCodeStatus":{"createdAt":"2026-09-23T10:00:00.000Z","confirmed":false}},"device":"#
            + device + #","tokens":{"accessToken":"access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"mgrt1.a.b","refreshTokenExpiresAt":"2099-01-01T00:00:00.000Z"},"serverId":""#
            + AccountTests.serverId + #"","serverTime":"2026-09-23T10:00:00.000Z","recoveryCode":"# + code + #","signedOutDevices":0}"#
    }

    static let device = #"{"id":"d1","name":"Test iPhone","reportedName":"Test iPhone","customName":null,"platform":"ios","osVersion":"26.0.0","model":"iPhone18,1","clientVersion":"0.1.0","linkedVia":"login","linkedByDeviceId":null,"createdAt":"2026-09-23T10:00:00.000Z","lastSeenAt":"2026-09-23T10:00:00.000Z","lastSyncAt":null,"recentUntil":null,"isCurrent":true}"#

    static let refreshResponse = #"{"tokens":{"accessToken":"new-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"mgrt1.new.x","refreshTokenExpiresAt":"2099-01-01T00:00:00.000Z"},"device":"#
        + device + #","serverId":""# + AccountTests.serverId + #"","serverTime":"2026-09-25T10:00:00.000Z"}"#

    static let deviceList = #"{"devices":["# + device + #"],"maxDevices":20}"#

    static func error(_ code: String, _ status: Int) -> String {
        #"{"statusCode":"# + "\(status)" + #","error":"x","message":"x","code":""# + code + #""}"#
    }
}
