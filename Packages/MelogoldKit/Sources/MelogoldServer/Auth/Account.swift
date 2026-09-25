import Foundation
import Observation
import MelogoldCore
import MelogoldData

/// Сессия на сервере Melogold, как её хранит устройство: в Keychain, без резервной копии.
public struct StoredSession: Codable, Sendable, Equatable {
    public var serverURL: String
    public var serverId: String
    public var userId: String
    public var login: String
    public var deviceId: String
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String

    /// `serverId + ":" + userId` (API §7.1 п. 6): чьи данные лежат в синке этого устройства.
    public var binding: String { "\(serverId):\(userId)" }
}

/// Аккаунт на сервере Melogold (API §4.3–4.6): вход, регистрация с proof-of-work, восстановление, токены и их
/// обновление, устройства, пароль, код восстановления, вход по коду. Экраны и синк ходят на сервер только через
/// `authorized`.
@MainActor
@Observable
public final class Account {
    public enum State: Equatable, Sendable {
        /// Аккаунта нет: приложение работает само по себе, как без сервера.
        case signedOut
        case signedIn(login: String)
        /// Сервер завершил сеанс (устройство отозвано, пароль сменён): войти снова. Библиотека остаётся (API §1.7).
        case authRequired(login: String)
    }

    public private(set) var state: State
    public private(set) var session: StoredSession?
    /// Сервер, проверенный последним (`/server/info`).
    public private(set) var serverInfo: ServerInfo?
    /// Идёт proof-of-work регистрации: экран показывает, что занят.
    public private(set) var solvingProofOfWork = false
    /// Почему сеанс закончился (`session_revoked`, `refresh_token_reused`…): сообщение для экрана, показывается один раз.
    public var endedReason: String?

    public let identity: DeviceIdentity
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var refreshTask: Task<StoredSession, any Error>?

    static let sessionAccount = "session"
    /// Access-токен обновляется за 60 с до истечения (API §1.7).
    static let refreshEarly: TimeInterval = 60
    /// Версия HTTP API этого клиента (API §1.1, §7.1 п. 4).
    static let apiVersion = 1

    public init(
        settings: AppSettings,
        secrets: any SecretStore = Keychain(),
        identity: DeviceIdentity? = nil,
        urlSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.secrets = secrets
        self.identity = identity ?? DeviceIdentity.current(secrets: secrets)
        self.urlSession = urlSession
        self.now = now
        let stored = secrets.data(Self.sessionAccount).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
        session = stored
        state = stored.map { .signedIn(login: $0.login) } ?? .signedOut
    }

    public var isSignedIn: Bool { session != nil }

    public func api(_ url: String? = nil) -> ServerAPI {
        let address = url ?? session?.serverURL ?? settings.serverURL
        return ServerAPI(baseURL: URL(string: address) ?? URL(string: ServerDefaults.baseURL)!, userAgent: identity.userAgent, session: urlSession)
    }

    // MARK: - Сервер

    /// Проверка сервера (API §7.1 п. 3–4): это Melogold и он говорит на версии API этого клиента.
    @discardableResult
    public func check(_ url: String? = nil) async throws -> ServerInfo {
        let info = try await api(url ?? settings.serverURL).serverInfo()
        guard info.software == "melogold-server" else {
            throw APIError(status: 200, code: "not_melogold", message: "Not a Melogold server")
        }
        guard info.minApiVersion <= Self.apiVersion, info.apiVersion >= Self.apiVersion else {
            throw APIError(status: 200, code: "incompatible", message: "API \(info.minApiVersion)…\(info.apiVersion)")
        }
        if url == nil || url == settings.serverURL { serverInfo = info }
        return info
    }

    /// Адрес сервера сменился: сеанс прежнего сервера на этом устройстве заканчивается.
    public func serverChanged() {
        guard let session, session.serverURL != settings.serverURL else { return }
        let token = session.refreshToken
        let old = api(session.serverURL)
        clear(to: .signedOut)
        serverInfo = nil
        Task { try? await old.logout(refreshToken: token) }
    }

    // MARK: - Вход и регистрация

    /// Регистрация: при необходимости proof-of-work, затем `AuthSession` с кодом восстановления — показать один раз.
    public func register(login: String, password: String) async throws -> AuthSession {
        let info = try await check()
        guard info.registrationOpen else {
            throw APIError(status: 403, code: "registration_closed", message: "Registration is closed")
        }
        let api = api(settings.serverURL)
        let device = identity.input(serverId: info.serverId)
        var pow = info.features.registrationPow == nil ? nil : try await solvePow(api)
        do {
            return try save(await api.register(RegisterRequest(login: login, password: password, device: device, pow: pow)))
        } catch let error as APIError where pow == nil && (error.code == "pow_required" || error.code == "pow_invalid") {
            // Требование PoW включилось между проверкой и запросом: решить и повторить один раз (API §2.2)
            pow = try await solvePow(api)
            return try save(await api.register(RegisterRequest(login: login, password: password, device: device, pow: pow)))
        }
    }

    public func signIn(login: String, password: String) async throws {
        let info = try await check()
        _ = try save(await api(settings.serverURL).login(LoginRequest(login: login, password: password, device: identity.input(serverId: info.serverId))))
    }

    /// Новый пароль по коду восстановления: прежние устройства выходят, ответ несёт новый код (API §4.5).
    public func recover(login: String, recoveryCode: String, newPassword: String) async throws -> AuthSession {
        let info = try await check()
        let request = RecoverRequest(login: login, recoveryCode: recoveryCode, newPassword: newPassword, device: identity.input(serverId: info.serverId))
        return try save(await api(settings.serverURL).recover(request))
    }

    /// Выход и на сервере: устройство удаляется из аккаунта. Библиотека остаётся на устройстве.
    public func signOut() async {
        guard let session else { return }
        let api = api(session.serverURL)
        clear(to: .signedOut)
        do {
            try await api.logout(refreshToken: session.refreshToken)
        } catch {
            Log.warning("account", "Выход на сервере не прошёл: \(error)")
        }
    }

    private func solvePow(_ api: ServerAPI) async throws -> PowSolution {
        let challenge = try await api.registerChallenge()
        solvingProofOfWork = true
        defer { solvingProofOfWork = false }
        let started = now()
        guard let nonce = await ProofOfWork.solve(challenge: challenge.challenge, bits: challenge.bits) else {
            throw CancellationError()
        }
        Log.info("account", "Proof-of-work \(challenge.bits) бит за \(Int(now().timeIntervalSince(started) * 1000)) мс")
        return PowSolution(challenge: challenge.challenge, nonce: nonce)
    }

    // MARK: - Токены

    /// `call` с живым access-токеном: он обновляется заранее, а на `access_token_expired` и `access_token_invalid`
    /// обновляется и вызов повторяется один раз. Завершённый сервером сеанс переводит в `authRequired` (API §1.7).
    public func authorized<T: Sendable>(_ call: (ServerAPI, String) async throws -> T) async throws -> T {
        var current = try await freshSession(force: false)
        do {
            return try await call(api(current.serverURL), current.accessToken)
        } catch let error as APIError where error.code == "access_token_expired" || error.code == "access_token_invalid" {
            current = try await freshSession(force: true)
            do {
                return try await call(api(current.serverURL), current.accessToken)
            } catch let error as APIError where error.code == "session_revoked" {
                end(reason: error.code)
                throw error
            }
        } catch let error as APIError where error.code == "session_revoked" {
            end(reason: error.code)
            throw error
        }
    }

    /// Обновление токенов одним запросом на всех, кто ждёт (single flight).
    private func freshSession(force: Bool) async throws -> StoredSession {
        if let refreshTask { return try await refreshTask.value }
        guard let current = session else { throw APIError(status: 401, code: "unauthorized", message: "Not signed in") }
        if !force, current.accessTokenExpiresAt.timeIntervalSince(now()) > Self.refreshEarly { return current }

        let api = api(current.serverURL)
        let patch = DevicePatch(hwid: identity.hwid(serverId: current.serverId), clientVersion: identity.clientVersion)
        let task = Task { try await api.refresh(RefreshRequest(refreshToken: current.refreshToken, device: patch)) }
        let wrapper = Task<StoredSession, any Error> { @MainActor in
            do {
                let refreshed = try await task.value
                return try self.storeTokens(refreshed.tokens, expected: current)
            } catch let error as APIError where error.status == 401 {
                // Любой 401 обновления — сеанса больше нет; ошибки сети токены не стирают (API §1.7)
                self.end(reason: error.code)
                throw error
            }
        }
        refreshTask = wrapper
        defer { refreshTask = nil }
        return try await wrapper.value
    }

    /// Новые токены сохраняются до первого использования нового access-токена (API §1.7).
    @discardableResult
    private func storeTokens(_ tokens: TokenPair, expected: StoredSession) throws -> StoredSession {
        guard var updated = session, updated.deviceId == expected.deviceId else {
            throw APIError(status: 401, code: "unauthorized", message: "Signed out meanwhile")
        }
        updated.accessToken = tokens.accessToken
        updated.accessTokenExpiresAt = IsoTime.date(tokens.accessTokenExpiresAt) ?? now()
        updated.refreshToken = tokens.refreshToken
        persist(updated)
        session = updated
        return updated
    }

    // MARK: - Аккаунт и устройства

    public func me() async throws -> MeResponse {
        try await authorized { api, token in try await api.me(token: token) }
    }

    public func devices() async throws -> DeviceListResponse {
        try await authorized { api, token in try await api.devices(token: token) }
    }

    /// `name == nil` — вернуть имя, которое сообщает само устройство. `password` — когда сервер попросил
    /// (`recent_device_restricted`).
    public func renameDevice(_ deviceId: String, name: String?, password: String? = nil) async throws -> DeviceDto {
        try await authorized { api, token in try await api.renameDevice(token: token, deviceId: deviceId, name: name, password: password) }
    }

    public func revokeDevice(_ deviceId: String, password: String? = nil) async throws {
        try await authorized { api, token in try await api.revokeDevice(token: token, deviceId: deviceId, password: password) }
    }

    public func revokeOtherDevices(password: String? = nil) async throws -> Int {
        try await authorized { api, token in try await api.revokeOthers(token: token, password: password).revokedCount }
    }

    /// Смена пароля. Без `currentPassword` — с любого вошедшего устройства (API §4.5). Токены приходят новые.
    public func changePassword(currentPassword: String?, newPassword: String, signOutOtherDevices: Bool) async throws -> Int {
        let body = ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword, signOutOtherDevices: signOutOtherDevices)
        let response = try await authorized { api, token in try await api.changePassword(token: token, body) }
        if let current = session { try storeTokens(response.tokens, expected: current) }
        return response.signedOutDevices
    }

    public func rotateRecoveryCode(password: String) async throws -> RecoveryCodeResponse {
        try await authorized { api, token in try await api.rotateRecoveryCode(token: token, password: password) }
    }

    /// «Код сохранён»: сервер перестаёт напоминать о коде.
    public func confirmRecoveryCode(createdAt: String) async throws {
        try await authorized { api, token in try await api.confirmRecoveryCode(token: token, createdAt: createdAt) }
    }

    // MARK: - Вход по коду (API §4.6, режим `request`)

    /// Новое устройство (часы) просит вход: сервер выдаёт код, который вводят на вошедшем устройстве.
    public func startLinkRequest() async throws -> LinkCreated {
        let info = try await check()
        return try await api(settings.serverURL).createLinkRequest(device: identity.input(serverId: info.serverId))
    }

    /// Ожидание одобрения: `claimed` — показать число, `completed` — сеанс сохранён и устройство вошло.
    public func pollLink(pollSecret: String, knownStatus: String) async throws -> LinkPollResponse {
        let response = try await api(settings.serverURL).pollLink(pollSecret: pollSecret, knownStatus: knownStatus, waitSeconds: 25)
        if response.status == "completed", let session = response.session { _ = try save(session) }
        return response
    }

    public func cancelLinkRequest(pollSecret: String) async {
        try? await api(settings.serverURL).cancelLinkRequest(pollSecret: pollSecret)
    }

    /// Вошедшее устройство вводит код нового: карточка устройства и три числа на выбор.
    public func resolveLink(userCode: String) async throws -> LinkDetails {
        try await authorized { api, token in try await api.resolveLink(token: token, userCode: userCode) }
    }

    public func approveLink(_ linkId: String, verifyCode: String) async throws -> LinkDecisionResponse {
        try await authorized { api, token in try await api.approveLink(token: token, linkId: linkId, verifyCode: verifyCode) }
    }

    public func denyLink(_ linkId: String) async throws -> LinkDecisionResponse {
        try await authorized { api, token in try await api.denyLink(token: token, linkId: linkId) }
    }

    // MARK: - Хранение

    private func save(_ auth: AuthSession) throws -> AuthSession {
        let stored = StoredSession(
            serverURL: settings.serverURL,
            serverId: auth.serverId,
            userId: auth.user.id,
            login: auth.user.login,
            deviceId: auth.device.id,
            accessToken: auth.tokens.accessToken,
            accessTokenExpiresAt: IsoTime.date(auth.tokens.accessTokenExpiresAt) ?? now(),
            refreshToken: auth.tokens.refreshToken
        )
        persist(stored)
        session = stored
        endedReason = nil
        state = .signedIn(login: stored.login)
        Log.info("account", "Вход: устройство \(stored.deviceId)")
        return auth
    }

    /// Сервер завершил сеанс: войти снова, данные на устройстве остаются.
    public func end(reason: String) {
        guard let session else { return }
        Log.warning("account", "Сеанс завершён сервером: \(reason)")
        endedReason = reason
        clear(to: .authRequired(login: session.login))
    }

    private func clear(to newState: State) {
        refreshTask?.cancel()
        refreshTask = nil
        secrets.delete(Self.sessionAccount)
        session = nil
        state = newState
    }

    private func persist(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session), secrets.set(data, for: Self.sessionAccount) else {
            Log.error("account", "Сеанс не сохранился в Keychain")
            return
        }
    }
}
