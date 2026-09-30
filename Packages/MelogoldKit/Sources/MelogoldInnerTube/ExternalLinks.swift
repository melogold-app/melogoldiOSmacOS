import Foundation
import MelogoldCore

// Ссылки других музыкальных сервисов → YouTube (задание 0019, как `providers/songlink` Android): Spotify, Apple Music,
// Яндекс Музыка, Deezer, Tidal, SoundCloud. song.link с 2026-09 отвечает без ключа `401 PUBLIC_API_ACCESS_DEPRECATED`,
// поэтому главный путь без ключа — название и исполнитель из заголовка страницы самой ссылки и поиск по ним.

public enum MusicService: String, Sendable, CaseIterable {
    case spotify, appleMusic, yandexMusic, deezer, tidal, soundCloud

    public var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .yandexMusic: "Yandex Music"
        case .deezer: "Deezer"
        case .tidal: "Tidal"
        case .soundCloud: "SoundCloud"
        }
    }
}

/// На что ведёт ссылка; `unknown` — короткая ссылка, куда — видно только после перехода.
public enum MusicLinkKind: Sendable {
    case track, album, artist, playlist, unknown
}

public struct MusicServiceLink: Equatable, Sendable {
    public let service: MusicService
    public let kind: MusicLinkKind
    public let url: URL

    /// Первая ссылка такого сервиса в тексте (вставка в Поиске, «Открыть с помощью»). Сеть не трогает.
    public static func parse(_ input: String) -> MusicServiceLink? {
        guard let match = input.firstMatch(of: /(?i)https?:\/\/\S+/) else { return nil }
        let trailing = Set(".,;:!?)]}>»\"'…")
        var text = String(match.output)
        while let last = text.last, trailing.contains(last) { text.removeLast() }
        guard let url = URL(string: text), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let segments = components.path.split(separator: "/").map(String.init)
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        let service: MusicService
        let kind: MusicLinkKind
        if ["open.spotify.com", "play.spotify.com", "spotify.link", "spotify.app.link"].contains(host) {
            service = .spotify
            guard let spotifyKind = spotify(host, segments) else { return nil }
            kind = spotifyKind
        } else if ["music.apple.com", "itunes.apple.com", "geo.music.apple.com"].contains(host) {
            service = .appleMusic
            kind = apple(segments, query)
        } else if host.hasPrefix("music.yandex.") {
            service = .yandexMusic
            kind = yandex(segments)
        } else if ["deezer.com", "link.deezer.com", "deezer.page.link", "dzr.page.link"].contains(host) {
            service = .deezer
            kind = host == "deezer.com" ? first(segments, ["track": .track, "album": .album, "artist": .artist, "playlist": .playlist]) : .unknown
        } else if ["tidal.com", "listen.tidal.com", "link.tidal.com"].contains(host) {
            service = .tidal
            kind = host == "link.tidal.com" ? .unknown : first(segments, ["track": .track, "album": .album, "artist": .artist, "playlist": .playlist, "mix": .playlist])
        } else if ["soundcloud.com", "m.soundcloud.com", "on.soundcloud.com"].contains(host) {
            service = .soundCloud
            kind = soundcloud(host, segments)
        } else {
            return nil
        }
        return MusicServiceLink(service: service, kind: kind, url: url)
    }

    private static func first(_ segments: [String], _ kinds: [String: MusicLinkKind]) -> MusicLinkKind {
        segments.first { kinds[$0] != nil }.flatMap { kinds[$0] } ?? .unknown
    }

    /// `open.spotify.com/intl-de/track/<id>` — язык впереди.
    private static func spotify(_ host: String, _ segments: [String]) -> MusicLinkKind? {
        guard host == "open.spotify.com" || host == "play.spotify.com" else { return .unknown }
        let path = segments.first?.hasPrefix("intl-") == true ? Array(segments.dropFirst()) : segments
        switch path.first {
        case "track": return .track
        case "album": return .album
        case "artist": return .artist
        case "playlist": return .playlist
        default: return nil
        }
    }

    /// `music.apple.com/<страна>/album/<имя>/<id>?i=<трек>` — трек альбома.
    private static func apple(_ segments: [String], _ query: [String: String]) -> MusicLinkKind {
        switch segments.first(where: { ["song", "album", "playlist", "artist", "music-video"].contains($0) }) {
        case "song": .track
        case "album": query["i"] != nil ? .track : .album
        case "playlist": .playlist
        case "artist": .artist
        default: .unknown
        }
    }

    private static func yandex(_ segments: [String]) -> MusicLinkKind {
        if segments.contains("playlists") { return .playlist }
        if segments.first == "album", segments.count > 2, segments[2] == "track" { return .track }
        switch segments.first {
        case "track": return .track
        case "album": return .album
        case "artist": return .artist
        default: return .unknown
        }
    }

    private static func soundcloud(_ host: String, _ segments: [String]) -> MusicLinkKind {
        if host == "on.soundcloud.com" { return .unknown }
        if segments.count >= 3, segments[1] == "sets" { return .playlist }
        if segments.count == 2 { return .track }
        if segments.count == 1 { return .artist }
        return .unknown
    }
}

/// Куда ведёт ссылка другого сервиса в Melogold.
public enum ExternalResolution: Equatable, Sendable {
    /// То же на YouTube Music или YouTube: открыть как любую ссылку YouTube.
    case onYouTube(URL)
    /// Ссылки на YouTube нет, но известны название и исполнитель: искать это.
    case search(String)
    case notFound
}

public enum ExternalLinks {
    static let songLinkEndpoint = URL(string: "https://api.song.link/v1-alpha.1/links")!
    static let maxPageBytes = 400_000
    static let browser = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// song.link (только с ключом — без него запроса нет) для трека и альбома, иначе заголовок страницы ссылки.
    /// Плейлисты других сервисов не переносятся (это отдельная задача): для них — `notFound`.
    public static func resolve(_ link: MusicServiceLink, songLinkKey: String? = nil, session: URLSession = .shared) async -> ExternalResolution {
        if link.kind == .playlist { return .notFound }
        if link.kind != .artist, let key = songLinkKey, !key.isEmpty, let url = try? await songLink(link.url, key: key, session: session) {
            return .onYouTube(url)
        }
        guard let html = await page(link.url, session: session) else { return .notFound }
        return PageTitles.searchText(link, html: html).map(ExternalResolution.search) ?? .notFound
    }

    static func songLink(_ url: URL, key: String, session: URLSession) async throws -> URL? {
        var components = URLComponents(url: songLinkEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "key", value: key)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return youTubeURL(in: data)
    }

    /// Из ответа Odesli: `linksByPlatform.youtubeMusic.url`, иначе `linksByPlatform.youtube.url`.
    static func youTubeURL(in data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = object["linksByPlatform"] as? [String: Any] else { return nil }
        for platform in ["youtubeMusic", "youtube"] {
            if let entry = links[platform] as? [String: Any], let text = entry["url"] as? String, let url = URL(string: text) { return url }
        }
        return nil
    }

    /// Начало страницы (в `<head>` есть заголовок); сбой — `nil`, не ошибка.
    static func page(_ url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxPageBytes { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Слова для поиска из заголовка страницы ссылки: «Never Gonna Give You Up Rick Astley». Каждый сервис пишет название и
/// исполнителя по-своему (`<title>`, `og:title`, `og:description`); страница без пригодного — `nil`.
enum PageTitles {
    static let maxQuery = 120

    static func searchText(_ link: MusicServiceLink, html: String) -> String? {
        let title = tagText(html, "title").map(clean)
        let og = meta(html, "og:title")
        let description = meta(html, "og:description")
        let query: String? = switch link.service {
        case .spotify: spotify(link.kind, title, og, description)
        case .appleMusic: apple(link.kind, title, og)
        case .yandexMusic: yandex(link.kind, title, og, description)
        case .tidal: tidal(link.kind, title, og)
        case .deezer: deezer(title, og)
        case .soundCloud: soundcloud(title)
        }
        return query.map(tidy).flatMap { $0.isEmpty ? nil : $0 }
    }

    // «Never Gonna Give You Up - song and lyrics by Rick Astley | Spotify», «Rick Astley | Spotify»
    private static func spotify(_ kind: MusicLinkKind, _ title: String?, _ og: String?, _ description: String?) -> String? {
        if let title, let match = title.firstMatch(of: /(?i)^(.+?) - (?:song and lyrics|song|album|single|EP)(?: and lyrics)? by (.+?) \| Spotify$/) {
            return "\(match.1) \(match.2)"
        }
        let name = og ?? title.map { $0.replacingOccurrences(of: " | Spotify", with: "") }
        if kind == .artist { return name }
        // Страница трека: og:title — название, описание начинается с исполнителя («Rick Astley · Album · Song · 1987»)
        let artist = description.flatMap { $0.contains(" · ") ? $0.components(separatedBy: " · ").first : nil }
        return [name, artist].compactMap { $0 }.joined(separator: " ")
    }

    // «Never Gonna Give You Up - Song with Lyrics by Rick Astley - Apple Music», og «… by Rick Astley on Apple Music»
    private static func apple(_ kind: MusicLinkKind, _ title: String?, _ og: String?) -> String? {
        if let title, let match = title.firstMatch(of: /(?i)^(.+?) - (?:Song|Album|Single|EP)(?: with Lyrics)? by (.+?) - Apple Music$/) {
            return "\(match.1) \(match.2)"
        }
        if let og, let match = og.firstMatch(of: /(?i)^(.+) by (.+?) on Apple Music$/) { return "\(match.1) \(match.2)" }
        if kind == .artist {
            return og.map { $0.replacingOccurrences(of: " on Apple Music", with: "") } ?? title.map { $0.replacingOccurrences(of: " - Apple Music", with: "") }
        }
        return nil
    }

    // «Never Gonna Give You Up Rick Astley слушать онлайн на Яндекс Музыке», описание «Rick Astley • Трек • 2019»
    private static func yandex(_ kind: MusicLinkKind, _ title: String?, _ og: String?, _ description: String?) -> String? {
        func strip(_ text: String) -> String { text.replacing(/(?i)\s+слушать онлайн.*$/, with: "") }
        let artist = description.flatMap { $0.contains(" • ") ? $0.components(separatedBy: " • ").first : nil }
        if kind == .artist { return og ?? title.map(strip) }
        if let og { return [og, artist].compactMap { $0 }.joined(separator: " ") }
        return title.map(strip)
    }

    // «Never Gonna Give You Up by Rick Astley on TIDAL», og «Rick Astley - Never Gonna Give You Up»
    private static func tidal(_ kind: MusicLinkKind, _ title: String?, _ og: String?) -> String? {
        if let title, let match = title.firstMatch(of: /(?i)^(.+) by (.+?) on TIDAL$/) { return "\(match.1) \(match.2)" }
        if kind == .artist { return og ?? title.map { $0.replacingOccurrences(of: " on TIDAL", with: "") } }
        return og?.replacingOccurrences(of: " - ", with: " ")
    }

    // «Daft Punk - Harder, Better, Faster, Stronger | Deezer»
    private static func deezer(_ title: String?, _ og: String?) -> String? {
        let head = title.map { $0.replacingOccurrences(of: "| Deezer", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " |")) } ?? og
        return head?.replacingOccurrences(of: " - ", with: " ")
    }

    // Старый заголовок трека: «Stream Never Gonna Give You Up by Rick Astley | Listen online for free on SoundCloud»
    private static func soundcloud(_ title: String?) -> String? {
        guard let title, let match = title.firstMatch(of: /(?i)^Stream (.+?) by (.+?) \|/) else { return nil }
        return "\(match.1) \(match.2)"
    }

    static func tagText(_ html: String, _ tag: String) -> String? {
        guard tag == "title", let match = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/) else { return nil }
        return String(match.1)
    }

    /// `content` у `<meta property="name" …>` (или `name=`), атрибуты в любом порядке.
    static func meta(_ html: String, _ name: String) -> String? {
        for match in html.matches(of: /(?i)<meta\b[^>]*>/) {
            let tag = String(match.output)
            let lower = tag.lowercased()
            guard lower.contains("property=\"\(name)\"") || lower.contains("name=\"\(name)\"")
                || lower.contains("property='\(name)'") || lower.contains("name='\(name)'") else { continue }
            if let content = tag.firstMatch(of: /(?is)content\s*=\s*"(.*?)"/) ?? tag.firstMatch(of: /(?is)content\s*=\s*'(.*?)'/) {
                return clean(String(content.1))
            }
        }
        return nil
    }

    /// Сущности HTML, невидимые знаки, неразрывные пробелы.
    static func clean(_ raw: String) -> String {
        var text = raw
        for (entity, value) in ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = decodeNumericEntities(text)
        let invisible: Set<Character> = ["\u{200E}", "\u{200F}", "\u{200B}", "\u{FEFF}", "\u{202A}", "\u{202C}"]
        text.removeAll { invisible.contains($0) }
        return text.replacing(/[\u{00A0}\u{2007}\u{202F}]/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `&#x41;` и `&#65;` → «A».
    static func decodeNumericEntities(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#") {
            result += rest[..<start.lowerBound]
            let afterMark = rest[start.upperBound...]
            guard let end = afterMark.firstIndex(of: ";") else {
                result += rest[start.lowerBound...]
                return result
            }
            let body = afterMark[..<end]
            let hex = body.first == "x" || body.first == "X"
            let digits = hex ? String(body.dropFirst()) : String(body)
            let code: UInt32? = UInt32(digits, radix: hex ? 16 : 10)
            if let code, let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[start.lowerBound ... end]
            }
            rest = afterMark[afterMark.index(after: end)...]
        }
        return result + rest
    }

    static func tidy(_ text: String) -> String {
        let collapsed = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        guard collapsed.count > maxQuery else { return collapsed }
        return String(collapsed.prefix(maxQuery)).trimmingCharacters(in: .whitespaces)
    }
}
