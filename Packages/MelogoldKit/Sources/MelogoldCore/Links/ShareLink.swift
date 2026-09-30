import Foundation

/// Ссылка на снимок плейлиста (API §4.11, §7.2; задание 0019): `https://<сервер>/s/<shareId>` из браузера и
/// мессенджеров или `melogold://share?v=1&url=<сервер>&id=<shareId>` с кнопки «Открыть в Melogold». Снимок читается
/// без входа с сервера из ссылки (`GET /shares/{id}`) — он может быть не тем, что выбран в Настройках.
public struct ShareLink: Equatable, Sendable {
    /// Адрес сервера без `/` в конце.
    public let server: String
    public let shareId: String

    public init(server: String, shareId: String) {
        self.server = server
        self.shareId = shareId
    }

    /// 10 знаков base62 (`SHARE_ID_PATTERN` сервера).
    public static func isShareId(_ text: String) -> Bool {
        text.wholeMatch(of: /^[0-9A-Za-z]{10}$/) != nil
    }

    /// Первая ссылка на снимок в тексте (вставка в Поиске, сообщение): `melogold://share…` или `https://<сервер>/s/<код>`,
    /// где бы они ни стояли; знаки после ссылки — точка, скобка — отбрасываются.
    public static func parse(text: String) -> ShareLink? {
        guard let match = text.firstMatch(of: /(?i)(?:melogold|https?):\/\/\S+/) else { return nil }
        let trailing = Set(".,;:!?)]}>»\"'…")
        var link = String(match.output)
        while let last = link.last, trailing.contains(last) { link.removeLast() }
        return URL(string: link).flatMap(parse)
    }

    public static func parse(_ url: URL) -> ShareLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        if scheme == MelogoldLink.scheme {
            guard components.host?.lowercased() == "share" else { return nil }
            let items = components.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard value("v") == "1", let id = value("id"), isShareId(id), let raw = value("url"),
                  case .valid(let server, _) = ServerAddressPolicy.normalize(raw) else { return nil }
            return ShareLink(server: server, shareId: id)
        }
        guard scheme == "https" || scheme == "http", let host = components.host?.lowercased(), !isYouTube(host) else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2] == "s", let id = parts.last.map(String.init), isShareId(id) else { return nil }
        // Сервер может стоять не в корне домена: всё до «/s/<id>» — его адрес
        var base = components
        base.path = parts.count > 2 ? "/" + parts.dropLast(2).joined(separator: "/") : ""
        base.query = nil
        base.fragment = nil
        guard let text = base.url?.absoluteString, case .valid(let server, _) = ServerAddressPolicy.normalize(text) else { return nil }
        return ShareLink(server: server, shareId: id)
    }

    private static func isYouTube(_ host: String) -> Bool {
        ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
