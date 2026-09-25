import Foundation
import MelogoldCore

/// HTTP-клиент сервера Melogold: один базовый адрес, эндпоинты API §3. Токены и их обновление — у `Account`,
/// сюда access-токен приходит аргументом.
public struct ServerAPI: Sendable {
    public let baseURL: URL
    let session: URLSession
    let userAgent: String

    /// Сервер отвечает на `/server/info` за 10 с (API §7.1), остальное — за 20 с; long-poll привязки — 35 с (§4.6).
    static let infoTimeout: TimeInterval = 10
    static let defaultTimeout: TimeInterval = 20
    static let pollTimeout: TimeInterval = 35

    public init(baseURL: URL, userAgent: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.session = session
    }

    // MARK: - Сервер и вход (API §4.2, §4.3, §4.5)

    public func serverInfo() async throws -> ServerInfo {
        try await send("GET", "/server/info", timeout: Self.infoTimeout)
    }

    public func registerChallenge() async throws -> RegisterChallenge {
        try await send("GET", "/auth/register/challenge")
    }

    func register(_ body: RegisterRequest) async throws -> AuthSession {
        try await send("POST", "/auth/register", body: body)
    }

    func login(_ body: LoginRequest) async throws -> AuthSession {
        try await send("POST", "/auth/login", body: body)
    }

    func refresh(_ body: RefreshRequest) async throws -> RefreshResponse {
        try await send("POST", "/auth/refresh", body: body)
    }

    func logout(refreshToken: String) async throws {
        try await sendEmpty("POST", "/auth/logout", body: LogoutRequest(refreshToken: refreshToken))
    }

    func recover(_ body: RecoverRequest) async throws -> AuthSession {
        try await send("POST", "/auth/recover", body: body)
    }

    // MARK: - Аккаунт и устройства (API §4.3–4.5)

    public func me(token: String) async throws -> MeResponse {
        try await send("GET", "/auth/me", token: token)
    }

    public func devices(token: String) async throws -> DeviceListResponse {
        try await send("GET", "/auth/me/devices", token: token)
    }

    func renameDevice(token: String, deviceId: String, name: String?, password: String?) async throws -> DeviceDto {
        try await send("PATCH", "/auth/me/devices/\(deviceId)", body: RenameDeviceRequest(name: name, password: password), token: token)
    }

    func revokeDevice(token: String, deviceId: String, password: String?) async throws {
        try await sendEmpty("POST", "/auth/me/devices/\(deviceId)/revoke", body: PasswordConfirmation(password: password), token: token)
    }

    func revokeOthers(token: String, password: String?) async throws -> RevokeOthersResponse {
        try await send("POST", "/auth/me/devices/revoke-others", body: PasswordConfirmation(password: password), token: token)
    }

    func changePassword(token: String, _ body: ChangePasswordRequest) async throws -> ChangePasswordResponse {
        try await send("POST", "/auth/me/password", body: body, token: token)
    }

    func rotateRecoveryCode(token: String, password: String) async throws -> RecoveryCodeResponse {
        try await send("POST", "/auth/me/recovery-code", body: PasswordConfirmation(password: password), token: token)
    }

    func confirmRecoveryCode(token: String, createdAt: String) async throws {
        try await sendEmpty("POST", "/auth/me/recovery-code/confirm", body: ConfirmRecoveryCodeRequest(recoveryCodeCreatedAt: createdAt), token: token)
    }

    // MARK: - Привязка устройств (API §4.6)

    func createLinkRequest(device: DeviceInput) async throws -> LinkCreated {
        try await send("POST", "/auth/link/requests", body: CreateLinkRequestRequest(device: device))
    }

    /// Long-poll: ответ сразу, если статус уже не `knownStatus`, иначе через `waitSeconds`.
    func pollLink(pollSecret: String, knownStatus: String, waitSeconds: Int) async throws -> LinkPollResponse {
        try await send(
            "POST", "/auth/link/poll",
            body: PollLinkRequest(pollSecret: pollSecret, waitSeconds: waitSeconds, knownStatus: knownStatus),
            timeout: Self.pollTimeout
        )
    }

    func cancelLinkRequest(pollSecret: String) async throws {
        try await sendEmpty("POST", "/auth/link/cancel", body: CancelLinkRequestRequest(pollSecret: pollSecret))
    }

    func resolveLink(token: String, userCode: String) async throws -> LinkDetails {
        try await send("POST", "/auth/me/links/resolve", body: ResolveLinkRequest(linkToken: nil, userCode: userCode), token: token)
    }

    func approveLink(token: String, linkId: String, verifyCode: String) async throws -> LinkDecisionResponse {
        try await send("POST", "/auth/me/links/\(linkId)/approve", body: ApproveLinkRequest(verifyCode: verifyCode), token: token)
    }

    func denyLink(token: String, linkId: String) async throws -> LinkDecisionResponse {
        try await send("POST", "/auth/me/links/\(linkId)/deny", body: EmptyBody(), token: token)
    }

    // MARK: - Транспорт

    func request(_ method: String, _ path: String, token: String? = nil, timeout: TimeInterval = defaultTimeout) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let language = Locale.preferredLanguages.first {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func send<Response: Decodable>(
        _ method: String, _ path: String, token: String? = nil, timeout: TimeInterval = defaultTimeout
    ) async throws -> Response {
        let (data, _) = try await perform(request(method, path, token: token, timeout: timeout))
        return try decode(data)
    }

    func send<Response: Decodable>(
        _ method: String, _ path: String, body: some Encodable, token: String? = nil, timeout: TimeInterval = defaultTimeout
    ) async throws -> Response {
        let (data, _) = try await perform(withBody(request(method, path, token: token, timeout: timeout), body))
        return try decode(data)
    }

    private func sendEmpty(_ method: String, _ path: String, body: some Encodable, token: String? = nil) async throws {
        _ = try await perform(withBody(request(method, path, token: token), body))
    }

    func withBody(_ request: URLRequest, _ body: some Encodable) throws -> URLRequest {
        var request = request
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Запрос с разбором отказа: конверт API §2.1, а если тело не JSON — по статусу (§1.2).
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "No HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                var error = envelope.error(status: http.statusCode)
                if error.retryAfterSeconds == nil, let header = http.value(forHTTPHeaderField: "Retry-After") {
                    error.retryAfterSeconds = Int(header)
                }
                throw error
            }
            var error = APIError(status: http.statusCode, code: Self.codeForStatus(http.statusCode), message: "HTTP \(http.statusCode)")
            error.retryAfterSeconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw error
        }
        return (data, http)
    }

    /// Ответ не от сервера Melogold (Caddy, шлюз): код по статусу, как велит API §1.2.
    static func codeForStatus(_ status: Int) -> String {
        switch status {
        case 413: "payload_too_large"
        case 429: "rate_limited"
        case 502, 503, 504: "unavailable"
        default: "bad_response"
        }
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            Log.warning("server", "Ответ не разобрался: \(error)")
            throw APIError.badResponse(200, String(describing: error))
        }
    }
}
