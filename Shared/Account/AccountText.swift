import SwiftUI
import MelogoldServer

/// Тексты отказов сервера на экранах аккаунта — iPhone, iPad, Mac, Vision и часы. Ветвление — только по `code`
/// (API §2.2): текст сервера для журнала, не для человека.
enum AccountText {
    static func message(for error: any Error) -> LocalizedStringResource {
        guard let error = error as? APIError else { return "account.error.generic" }
        switch error.code {
        case "network": return "account.error.network"
        case "not_melogold": return "account.error.notMelogold"
        case "incompatible", "protocol_unsupported": return "account.error.incompatible"
        case "invalid_credentials": return "account.error.invalidCredentials"
        case "invalid_recovery_code": return "account.error.invalidRecoveryCode"
        case "invalid_password": return "account.error.invalidPassword"
        case "login_throttled", "reauth_throttled", "rate_limited":
            return "account.error.throttled \(minutes(error.retryAfterSeconds))"
        case "device_limit_reached": return "account.error.deviceLimit \(error.deviceLimit ?? 20)"
        case "registration_closed": return "account.error.registrationClosed"
        case "login_taken": return "account.error.loginTaken"
        case "invalid_login_format": return "account.error.loginFormat"
        case "password_too_short": return "account.error.passwordShort \(error.minLength ?? 8)"
        case "password_too_long": return "account.error.passwordLong \(error.maxLength ?? 128)"
        case "password_too_common": return "account.error.passwordCommon"
        case "password_contains_login": return "account.error.passwordContainsLogin"
        case "link_not_found": return "account.error.linkNotFound"
        case "link_expired": return "account.error.linkExpired"
        case "link_cancelled": return "account.error.linkCancelled"
        case "link_denied": return "account.error.linkDenied"
        case "link_verify_mismatch": return "account.error.linkMismatch"
        case "link_already_claimed": return "account.error.linkClaimed"
        case "link_wrong_mode": return "account.error.linkWrongMode"
        case "server_busy", "unavailable": return "account.error.busy"
        case "storage_full": return "account.error.storageFull"
        default: return "account.error.generic"
        }
    }

    /// Почему сервер завершил сеанс (`Account.endedReason`).
    static func sessionEnded(_ reason: String?) -> LocalizedStringResource {
        switch reason {
        case "refresh_token_reused": "account.ended.reused"
        default: "account.ended.generic"
        }
    }

    private static func minutes(_ seconds: Int?) -> Int {
        max(1, ((seconds ?? 60) + 59) / 60)
    }
}

/// Значок устройства в списке аккаунта — по `platform` (API §1.6), как `DeviceSymbol` Clementine.
enum DeviceSymbol {
    static func name(for platform: String) -> String {
        switch platform.lowercased() {
        case "ios": "iphone"
        case "ipados": "ipad"
        case "macos": "laptopcomputer"
        case "watchos": "applewatch"
        case "visionos": "visionpro"
        case "android": "candybarphone"
        case "windows": "pc"
        default: "desktopcomputer"
        }
    }
}

/// Отладочные подстановки для UI-тестов. В выпускной сборке их нет.
enum UITestHooks {
    /// Пароль из `-MelogoldUITestPassword <пароль>`: симулятор под нагрузкой теряет символы при наборе в `SecureField`,
    /// поэтому тест не печатает пароль, а передаёт его при запуске.
    static var password: String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-MelogoldUITestPassword"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        #endif
        return ""
    }
}
