import Foundation

/// Отказ сервера или сети. Ветвление — только по `code` (API §2.2).
public struct APIError: Error, Sendable, Equatable {
    /// HTTP-статус; `0` — ответа нет (сеть, таймаут).
    public let status: Int
    /// Код из реестра API §2.2 или свой: `network`, `bad_response`, `not_melogold`, `incompatible`.
    public let code: String
    /// Английский текст для журнала, не для экрана.
    public let message: String
    public var retryAfterSeconds: Int?
    public var deviceLimit: Int?
    public var deviceCount: Int?
    public var minLength: Int?
    public var maxLength: Int?

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// Сети нет или сервер не ответил: токены и сессия остаются (API §1.7).
    public var isNetwork: Bool { status == 0 && code == "network" }

    static func network(_ error: any Error) -> APIError {
        APIError(status: 0, code: "network", message: String(describing: error))
    }

    static func badResponse(_ status: Int, _ detail: String) -> APIError {
        APIError(status: status, code: "bad_response", message: detail)
    }
}

/// Конверт ошибки API §2.1. Ответ не в JSON (прокси, шлюз) разбирается по статусу.
struct ErrorResponse: Decodable {
    let statusCode: Int?
    let message: String?
    let code: String
    let retryAfterSeconds: Int?
    let minLength: Int?
    let maxLength: Int?
    let deviceLimit: Int?
    let deviceCount: Int?

    func error(status: Int) -> APIError {
        var error = APIError(status: status, code: code, message: message ?? code)
        error.retryAfterSeconds = retryAfterSeconds
        error.minLength = minLength
        error.maxLength = maxLength
        error.deviceLimit = deviceLimit
        error.deviceCount = deviceCount
        return error
    }
}
