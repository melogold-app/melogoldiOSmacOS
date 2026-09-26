import Foundation

/// Куда ведёт ссылка или текст из «Поделиться» (REWRITE §4.9 Android).
public enum LinkTarget: Hashable, Sendable {
    case video(videoId: String, playlistId: String?, index: Int?, startMs: Int64?)
    /// PL…, RDCLAK5uy_…, RD…, UU…, OLAK5uy_… (альбом: резолвер находит его по первому треку).
    case playlist(String)
    case album(String)
    case channel(String)
    /// `/@name`: нужен `resolve_url`.
    case handle(String)
    /// `/c/…`, `/user/…`: нужен `resolve_url`.
    case legacyChannel(String)
    case search(String)
    /// Apple Music, Яндекс Музыка или Spotify: импорт появится позже.
    case external(service: String, url: String)
    case unsupported(Reason)

    public enum Reason: String, Sendable {
        case empty
        case invalidVideoId = "invalid_video_id"
        case missingParameter = "missing_parameter"
        case privatePlaylist = "private_playlist"
        case clip, post
        case unknownPath = "unknown_path"
        case unknownHost = "unknown_host"
        case unsupportedExternal = "unsupported_external"
    }
}

/// Разбор ссылок YouTube и YouTube Music и текста из других приложений по векторам `spec/youtube-links.vectors.json`.
/// Без сети: `resolve_url` и альбом плейлиста `OLAK5uy_` — дело резолвера. Порт `YouTubeLinkParser.cs` Windows.
public enum YouTubeLinkParser {
    private static let maxQueryLength = 200
    private static let maxUnwrapDepth = 3
    private static let vndPrefix = "vnd.youtube:"
    private static let trailingPunctuation = Set(".,;:!?)]}>»\"'…")

    private static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    ]
    private static let googleHosts: Set<String> = ["google.com", "www.google.com"]
    /// Списки самого аккаунта: вне аккаунта смысла не имеют.
    private static let privatePlaylists: Set<String> = ["LL", "WL", "LM"]
    private static let videoPathPrefixes: Set<String> = ["shorts", "live", "embed", "v", "e"]

    public static func parse(_ input: String?) -> LinkTarget {
        let text = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .unsupported(.empty) }

        if text.lowercased().hasPrefix(vndPrefix) {
            let rest = text.dropFirst(vndPrefix.count)
            let end = rest.firstIndex { $0 == "?" || $0 == "&" || $0 == "#" } ?? rest.endIndex
            return videoTarget(String(rest[..<end]), query: [:])
        }

        guard let match = text.firstMatch(of: /https?:\/\/\S+/.ignoresCase()) else { return .search(searchText(text)) }
        var url = String(match.output)
        while let last = url.last, trailingPunctuation.contains(last) { url.removeLast() }
        return parseURL(url, depth: 0)
    }

    private static func searchText(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Длина — в UTF-16, как у Kotlin и C#; суррогатная пара не рвётся.
        let units = Array(collapsed.utf16)
        guard units.count > maxQueryLength else { return collapsed }
        var end = maxQueryLength
        if UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        return String(decoding: units[..<end], as: UTF16.self)
    }

    private static func parseURL(_ url: String, depth: Int) -> LinkTarget {
        guard let match = url.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/([^\/?#]*)([^?#]*)(?:\?([^#]*))?(?:#.*)?/) else {
            return .unsupported(.unknownPath)
        }
        var authority = String(match.output.1)
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") { authority = String(authority[..<colon]) }
        let host = authority.lowercased()
        if host.isEmpty { return .unsupported(.unknownHost) }

        let rawPath = String(match.output.2)
        let query = queryParameters(match.output.3.map(String.init))
        let rawSegments = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let segments = rawSegments.map(decodePath)

        func unwrap(_ target: String?) -> LinkTarget {
            guard let target, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return .unsupported(.missingParameter) }
            if depth >= maxUnwrapDepth { return .unsupported(.unknownPath) }
            return parseURL(target, depth: depth + 1)
        }

        if host == "consent.youtube.com" { return unwrap(query["continue"]) }
        if googleHosts.contains(host), segments.first == "url" { return unwrap(query["q"] ?? query["url"]) }

        if let external = external(host: host, segments: segments, url: url) { return external }
        guard youTubeHosts.contains(host) else { return .unsupported(.unknownHost) }

        if host == "youtu.be" {
            return segments.first.map { videoTarget($0, query: query) } ?? .unsupported(.missingParameter)
        }
        guard let first = segments.first else { return .unsupported(.unknownPath) }
        let second = segments.count > 1 ? segments[1] : nil

        switch first {
        case "attribution_link":
            let target = query["u"]
            return unwrap(target.map { $0.hasPrefix("/") ? "https://www.youtube.com" + $0 : $0 })
        case "watch":
            if let videoId = query["v"] { return videoTarget(videoId, query: query) }
            return playlistTarget(query["list"])
        case _ where videoPathPrefixes.contains(first):
            return second.map { videoTarget($0, query: query) } ?? .unsupported(.missingParameter)
        case "playlist":
            return playlistTarget(query["list"])
        case "browse":
            guard let second else { return .unsupported(.missingParameter) }
            if second.hasPrefix("VL") { return .playlist(String(second.dropFirst(2))) }
            if second.hasPrefix("MPREb_") { return .album(second) }
            if second.hasPrefix("UC") { return .channel(second) }
            return .unsupported(.unknownPath)
        case "channel":
            guard let second else { return .unsupported(.missingParameter) }
            return second.hasPrefix("UC") ? .channel(second) : .unsupported(.unknownPath)
        case _ where first.hasPrefix("@") && first.count > 1:
            return .handle(String(first.dropFirst()))
        case "c", "user":
            return rawSegments.count > 1
                ? .legacyChannel("https://www.youtube.com/\(first)/\(rawSegments[1])")
                : .unsupported(.missingParameter)
        case "search":
            return searchTarget(query["q"])
        case "results":
            return searchTarget(query["search_query"])
        case "hashtag":
            return second.map { .search("#" + $0) } ?? .unsupported(.missingParameter)
        case "clip":
            return .unsupported(.clip)
        case "post":
            return .unsupported(.post)
        default:
            return .unsupported(.unknownPath)
        }
    }

    private static func playlistTarget(_ list: String?) -> LinkTarget {
        guard let list, !list.isEmpty else { return .unsupported(.missingParameter) }
        if privatePlaylists.contains(list) { return .unsupported(.privatePlaylist) }
        return .playlist(list)
    }

    private static func searchTarget(_ query: String?) -> LinkTarget {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return .unsupported(.missingParameter) }
        return .search(query)
    }

    private static func external(host: String, segments: [String], url: String) -> LinkTarget? {
        let service: String?
        switch host {
        case "music.apple.com":
            service = segments.contains("playlist") ? "apple" : nil
        case "music.yandex.ru", "music.yandex.com":
            service = segments.contains("playlists") || segments.first == "album" ? "yandex" : nil
        case "open.spotify.com":
            service = segments.first == "playlist" ? "spotify" : nil
        default:
            return nil
        }
        return service.map { .external(service: $0, url: url) } ?? .unsupported(.unsupportedExternal)
    }

    private static func videoTarget(_ videoId: String, query: [String: String]) -> LinkTarget {
        guard videoId.wholeMatch(of: /[A-Za-z0-9_\-]{11}/) != nil else { return .unsupported(.invalidVideoId) }
        let list = query["list"].flatMap { $0.isEmpty || privatePlaylists.contains($0) ? nil : $0 }
        let index = query["index"].flatMap { Int($0) }
        let time = query["t"] ?? query["start"]
        return .video(videoId: videoId, playlistId: list, index: index, startMs: time.flatMap(timeMs))
    }

    /// "90", "90s", "1m30s", "1h2m3s" → миллисекунды; иначе `nil`.
    private static func timeMs(_ value: String) -> Int64? {
        guard !value.isEmpty, let match = value.wholeMatch(of: /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?/) else { return nil }
        let (hours, minutes, seconds) = (match.output.1, match.output.2, match.output.3)
        if hours == nil, minutes == nil, seconds == nil { return nil }
        func number(_ part: Substring?) -> Int64 { part.flatMap { Int64($0) } ?? 0 }
        return (number(hours) * 3600 + number(minutes) * 60 + number(seconds)) * 1000
    }

    private static func queryParameters(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var parameters: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeQuery(String(parts[0]))
            let value = parts.count > 1 ? decodeQuery(String(parts[1])) : ""
            if parameters[key] == nil { parameters[key] = value }
        }
        return parameters
    }

    /// Путь: только percent-escapes, `+` остаётся (как `URI.getPath` в Java).
    private static func decodePath(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    /// Как `URLDecoder` в Java: `+` — пробел, неверная последовательность — строка как есть.
    private static func decodeQuery(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
