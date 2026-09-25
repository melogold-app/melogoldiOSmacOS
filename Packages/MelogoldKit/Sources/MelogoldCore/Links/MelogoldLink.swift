import Foundation

/// Ссылка `melogold://` (API §7.2): адрес сервера или привязка устройства.
public enum MelogoldLink: Equatable, Sendable {
    /// `melogold://server?v=1&url=<base>&sid=<serverId>` — экран «Сервер» с заполненным адресом и явным
    /// подтверждением. Если `sid` есть, он должен совпасть с `serverId` ответа `/server/info`.
    case server(url: String, insecure: Bool, serverId: String?)
    /// `melogold://link?v=1&mode=<request|invite>&server=<base>&sid=<serverId>&token=<linkToken>`.
    /// Автоматического входа или одобрения по ней не бывает никогда.
    case link(mode: LinkMode, server: String, serverId: String, token: String)

    public enum LinkMode: String, Sendable {
        /// QR показывает новое устройство — из ОС не выполняется, только инструкция.
        case request
        /// QR показывает вошедшее устройство — экран «Войти с другого устройства» с кнопкой «Подключиться».
        case invite
    }

    /// Почему ссылка не принята. Для пользователя — «Это не код Melogold» или причина адреса сервера.
    public enum ParseError: Error, Equatable, Sendable {
        case notMelogold
        case unsupportedVersion
        case badServer(ServerAddressError)
        case badParameters
    }

    public static let scheme = "melogold"

    public static func parse(_ url: URL) -> Result<MelogoldLink, ParseError> {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.notMelogold)
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("v") == "1" else { return .failure(.unsupportedVersion) }

        switch components.host?.lowercased() {
        case "server":
            guard let raw = value("url") else { return .failure(.badParameters) }
            let sid = value("sid")
            if let sid, !isUuid(sid) { return .failure(.badParameters) }
            switch ServerAddressPolicy.normalize(raw) {
            case .valid(let url, let insecure):
                return .success(.server(url: url, insecure: insecure, serverId: sid))
            case .invalid(let error):
                return .failure(.badServer(error))
            }
        case "link":
            guard let modeText = value("mode"), let mode = LinkMode(rawValue: modeText),
                  let rawServer = value("server"), let sid = value("sid"), isUuid(sid),
                  let token = value("token"), isLinkToken(token) else {
                return .failure(.badParameters)
            }
            switch ServerAddressPolicy.normalize(rawServer) {
            case .valid(let url, _):
                return .success(.link(mode: mode, server: url, serverId: sid, token: token))
            case .invalid(let error):
                return .failure(.badServer(error))
            }
        default:
            return .failure(.notMelogold)
        }
    }

    /// `Uuid` API §1.6: только нижний регистр.
    public static func isUuid(_ text: String) -> Bool {
        let pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
        return text.wholeMatch(of: pattern) != nil
    }

    /// `LinkToken` API §1.6.
    public static func isLinkToken(_ text: String) -> Bool {
        text.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil
    }
}
