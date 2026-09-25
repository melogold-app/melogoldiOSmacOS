import Foundation

// Тела запросов и ответов сервера (API §4). Имена — как у компонентов OpenAPI. Ответы клиент читает терпимо
// (API §1.3): неизвестные поля пропускаются, перечисления — строки, новое значение не ломает разбор.
// Время — строки `Iso` (API §1.5), перевод в `Date` — `IsoTime`.

// MARK: - Сервер (API §4.2)

public struct ServerInfo: Decodable, Sendable, Equatable {
    public let software: String
    public let version: String
    public let revision: String
    public let apiVersion: Int
    public let minApiVersion: Int
    public let serverId: String
    public let instanceName: String
    public let publicUrl: String?
    public let secureTransport: Bool
    /// `open` или `closed`.
    public let registration: String
    public let features: Features
    public let limits: Limits?
    public let serverTime: String

    public var registrationOpen: Bool { registration != "closed" }

    /// Ключ `features.*` есть — функция поддерживается (API §1.3).
    public struct Features: Decodable, Sendable, Equatable {
        public let sync: Sync?
        public let deviceLinking: DeviceLinking?
        public let recoveryCode: Version?
        public let accountDeletion: Version?
        public let registrationPow: Version?
        public let lyrics: Version?

        public struct Sync: Decodable, Sendable, Equatable {
            public let protocolVersion: Int
            public let minProtocol: Int
            public let kinds: [String]
            public let streams: [String]

            enum CodingKeys: String, CodingKey {
                case protocolVersion = "protocol"
                case minProtocol, kinds, streams
            }
        }

        public struct DeviceLinking: Decodable, Sendable, Equatable {
            public let version: Int
            public let modes: [String]
            public let ttlSeconds: Int
            public let longPollSeconds: Int
        }

        public struct Version: Decodable, Sendable, Equatable {
            public let version: Int
        }
    }

    /// Нужная клиенту часть `ServerLimits` (API §11): правила логина и пароля для подсказок у полей, лимиты синка
    /// и истории.
    public struct Limits: Decodable, Sendable, Equatable {
        public let account: Account?
        public let sync: Sync?
        public let history: History?

        public struct Account: Decodable, Sendable, Equatable {
            public let maxDevices: Int?
            public let login: Rule?
            public let password: Rule?
        }

        public struct Sync: Decodable, Sendable, Equatable {
            public let maxOpsPerRequest: Int?
        }

        public struct History: Decodable, Sendable, Equatable {
            public let retentionDays: Int?
            public let maxEvents: Int?
            /// Столько последних прослушиваний отправить при первом синке, не больше (задание 0002).
            public let mergeUploadMax: Int?
        }

        public struct Rule: Decodable, Sendable, Equatable {
            public let minLength: Int
            public let maxLength: Int
            public let pattern: String?
        }
    }
}

// MARK: - Устройство и пользователь (API §4.1)

public struct DeviceInput: Encodable, Sendable, Equatable {
    public var hwid: String
    public var name: String
    public var platform: String
    public var osVersion: String?
    public var model: String?
    public var clientVersion: String?

    public init(hwid: String, name: String, platform: String, osVersion: String?, model: String?, clientVersion: String?) {
        self.hwid = hwid
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.model = model
        self.clientVersion = clientVersion
    }
}

public struct DevicePatch: Encodable, Sendable, Equatable {
    public var hwid: String
    public var clientVersion: String?

    public init(hwid: String, clientVersion: String?) {
        self.hwid = hwid
        self.clientVersion = clientVersion
    }
}

public struct DeviceDto: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let reportedName: String
    public let customName: String?
    public let platform: String
    public let osVersion: String?
    public let model: String?
    public let clientVersion: String?
    /// `register`, `login`, `link` или `recovery`.
    public let linkedVia: String
    public let linkedByDeviceId: String?
    public let createdAt: String
    public let lastSeenAt: String
    public let lastSyncAt: String?
    /// До этого момента устройство «новое»: для его действий сервер может попросить пароль.
    public let recentUntil: String?
    public let isCurrent: Bool
}

public struct RecoveryCodeStatus: Decodable, Sendable, Equatable {
    public let createdAt: String
    public let confirmed: Bool
}

public struct UserDto: Decodable, Sendable, Equatable {
    public let id: String
    public let login: String
    public let createdAt: String
    public let passwordChangedAt: String
    public let recoveryCodeStatus: RecoveryCodeStatus
}

public struct TokenPair: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let accessTokenExpiresAt: String
    public let refreshToken: String
    public let refreshTokenExpiresAt: String
}

/// Ответ регистрации, входа, восстановления и завершённой привязки.
public struct AuthSession: Decodable, Sendable, Equatable {
    public let user: UserDto
    public let device: DeviceDto
    public let tokens: TokenPair
    public let serverId: String
    public let serverTime: String
    /// Только после регистрации и восстановления: показать один раз.
    public let recoveryCode: String?
    public let signedOutDevices: Int
}

// MARK: - Регистрация, вход, сессии (API §4.3)

public struct RegisterChallenge: Decodable, Sendable, Equatable {
    public let challenge: String
    public let bits: Int
    public let expiresAt: String
}

public struct PowSolution: Encodable, Sendable, Equatable {
    public let challenge: String
    public let nonce: String
}

struct RegisterRequest: Encodable, Sendable {
    let login: String
    let password: String
    let device: DeviceInput
    let pow: PowSolution?
}

struct LoginRequest: Encodable, Sendable {
    let login: String
    let password: String
    let device: DeviceInput
}

struct RefreshRequest: Encodable, Sendable {
    let refreshToken: String
    let device: DevicePatch
}

public struct RefreshResponse: Decodable, Sendable, Equatable {
    public let tokens: TokenPair
    public let device: DeviceDto
    public let serverId: String
    public let serverTime: String
}

struct LogoutRequest: Encodable, Sendable {
    let refreshToken: String
}

public struct MeResponse: Decodable, Sendable, Equatable {
    public let user: UserDto
    public let device: DeviceDto
    public let serverId: String
    public let serverTime: String
}

// MARK: - Устройства (API §4.4)

public struct DeviceListResponse: Decodable, Sendable, Equatable {
    public let devices: [DeviceDto]
    public let maxDevices: Int?
}

struct RenameDeviceRequest: Encodable, Sendable {
    /// `nil` — вернуть имя, которое сообщает само устройство.
    let name: String?
    let password: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(password, forKey: .password)
    }

    enum CodingKeys: String, CodingKey { case name, password }
}

struct PasswordConfirmation: Encodable, Sendable {
    let password: String?
}

public struct RevokeOthersResponse: Decodable, Sendable, Equatable {
    public let revokedCount: Int
}

// MARK: - Аккаунт (API §4.5)

struct ChangePasswordRequest: Encodable, Sendable {
    let currentPassword: String?
    let newPassword: String
    let signOutOtherDevices: Bool
}

public struct ChangePasswordResponse: Decodable, Sendable, Equatable {
    public let user: UserDto
    public let tokens: TokenPair
    public let signedOutDevices: Int
}

public struct RecoveryCodeResponse: Decodable, Sendable, Equatable {
    public let recoveryCode: String
    public let createdAt: String
}

struct ConfirmRecoveryCodeRequest: Encodable, Sendable {
    let recoveryCodeCreatedAt: String
}

struct RecoverRequest: Encodable, Sendable {
    let login: String
    let recoveryCode: String
    let newPassword: String
    let device: DeviceInput
}

// MARK: - Привязка устройств (API §4.6)

struct CreateLinkRequestRequest: Encodable, Sendable {
    let device: DeviceInput
}

public struct LinkCreated: Decodable, Sendable, Equatable {
    public let linkId: String
    public let mode: String
    public let serverId: String
    public let linkToken: String
    public let userCode: String
    public let pollSecret: String?
    public let expiresAt: String
    public let longPollSeconds: Int
}

struct ResolveLinkRequest: Encodable, Sendable {
    let linkToken: String?
    let userCode: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(linkToken, forKey: .linkToken)
        try container.encodeIfPresent(userCode, forKey: .userCode)
    }

    enum CodingKeys: String, CodingKey { case linkToken, userCode }
}

public struct LinkDeviceInfo: Decodable, Sendable, Equatable {
    public let name: String
    public let platform: String
    public let osVersion: String?
    public let model: String?
    public let clientVersion: String?
    public let alreadyLinked: Bool
}

public struct LinkDetails: Decodable, Sendable, Equatable {
    public let linkId: String
    public let mode: String
    /// `pending`, `claimed`, `approved`, `denied`, `cancelled`, `completed` или `expired`.
    public let status: String
    public let createdAt: String
    public let expiresAt: String
    public let device: LinkDeviceInfo?
    public let sameNetwork: Bool?
    /// Три варианта числа при `claimed`, иначе пусто.
    public let verifyChoices: [String]
}

public struct LinkAccount: Decodable, Sendable, Equatable {
    public let login: String
}

public struct LinkApprover: Decodable, Sendable, Equatable {
    public let name: String
    public let platform: String
}

struct PollLinkRequest: Encodable, Sendable {
    let pollSecret: String
    let waitSeconds: Int
    let knownStatus: String
}

public struct LinkPollResponse: Decodable, Sendable, Equatable {
    public let linkId: String
    /// `pending`, `claimed` или `completed`.
    public let status: String
    public let expiresAt: String
    public let account: LinkAccount?
    public let approverDevice: LinkApprover?
    /// С момента `claimed`: число, которое новое устройство показывает крупно.
    public let verifyCode: String?
    public let session: AuthSession?
}

struct ApproveLinkRequest: Encodable, Sendable {
    let verifyCode: String
}

struct CancelLinkRequestRequest: Encodable, Sendable {
    let pollSecret: String
}

public struct LinkDecisionResponse: Decodable, Sendable, Equatable {
    public let linkId: String
    public let status: String
}

/// Пустое тело `{}`: у POST тело — всегда JSON-объект (API §1.2).
struct EmptyBody: Encodable, Sendable {}

// MARK: - SSE (API §6)

/// Событие потока `GET /auth/me/events`. `payload` разбирается по `type` в `LiveEventKind`.
public struct LiveEvent: Sendable, Equatable {
    public let id: String
    public let type: String
    public let at: String
    public let kind: LiveEventKind
}

public enum LiveEventKind: Sendable, Equatable {
    case connected(heartbeatMs: Int?, retryMs: Int?)
    case syncChanged(cursor: String?)
    case devicesUpdated(reason: String, deviceId: String?)
    case sessionInvalidated(reason: String)
    case accountUpdated(reason: String, byDeviceId: String?, byDeviceName: String?)
    case linkUpdated(linkId: String, status: String)
    case lyricsChanged(videoId: String, rev: Int64)
    case playbackUpdated
    /// Тип, которого этот клиент ещё не знает (API §1.1): пропускается.
    case other
}
