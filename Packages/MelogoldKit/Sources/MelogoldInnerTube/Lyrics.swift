import Foundation
import MelogoldCore

// MARK: - YouTube Music

extension YouTubeMusic {
    /// Обычный текст из вкладки «Текст» и его источник («Источник: Musixmatch»).
    public func lyrics(_ lyricsBrowseId: String) async throws -> (text: String, source: String?)? {
        Self.parseLyrics(try await client.postJSON(.webRemix, "browse", body: ["browseId": lyricsBrowseId]))
    }

    static func parseLyrics(_ response: JSON) -> (text: String, source: String?)? {
        guard let shelf = response.find("musicDescriptionShelfRenderer"),
              let text = shelf["description"].text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, shelf["footer"].text)
    }

    /// Синхронный текст YouTube Music: ту же вкладку клиент ANDROID_MUSIC отдаёт со временем строк
    /// (`timedLyricsModel`). LRC или `nil`, если времени у строк нет.
    public func timedLyrics(_ lyricsBrowseId: String) async throws -> String? {
        Self.parseTimedLyrics(try await client.postJSON(.androidMusic, "browse", body: ["browseId": lyricsBrowseId]))
    }

    static func parseTimedLyrics(_ response: JSON) -> String? {
        guard let data = response.find("timedLyricsData") else { return nil }
        let lines = data.array.compactMap { line -> String? in
            guard let start = line.int("cueRange", "startTimeMilliseconds") else { return nil }
            let centis = start / 10
            return String(format: "[%02lld:%02lld.%02lld]", centis / 6000, centis / 100 % 60, centis % 100) + (line.str("lyricLine") ?? "")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - LRCLIB

/// Трек LRCLIB с текстами.
public struct LrcLibTrack: Decodable, Hashable, Sendable, Identifiable {
    public let id: Int64
    public let trackName: String
    public let artistName: String
    public let albumName: String?
    public let duration: Double
    public let plainLyrics: String?
    public let syncedLyrics: String?
}

/// LRCLIB (Android `providers/lrclib`, Windows `LrcLib`): поиск по названию и исполнителю без альбома — YouTube Music
/// называет альбомы по-своему, и одно слово мимо ничего не находит.
public struct LrcLib: Sendable {
    public static let baseURL = "https://lrclib.net"
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String, session: URLSession = HTTPConfiguration.session(timeout: 20)) {
        self.session = session
        self.userAgent = userAgent
    }

    public func search(artist: String, title: String) async throws -> [LrcLibTrack] {
        try await get("\(Self.baseURL)/api/search?track_name=\(escape(title))&artist_name=\(escape(artist))")
    }

    /// Треки по запросу, у которых есть хоть какой-то текст («Найти текст»).
    public func search(_ query: String) async throws -> [LrcLibTrack] {
        try await get("\(Self.baseURL)/api/search?q=\(escape(query))").filter {
            !($0.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !($0.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Текст версии трека, ближайшей по длительности; синхронный — только в пределах max(3 с, 10 %).
    public func bestLyrics(artist: String, title: String, durationMs: Int64, synced: Bool) async throws -> String? {
        let tracks = try await search(artist: artist, title: title).filter { synced ? $0.syncedLyrics != nil : $0.plainLyrics != nil }
        let best = Self.bestMatching(tracks, title: title, durationMs: durationMs)
        return synced ? best?.syncedLyrics : best?.plainLyrics
    }

    /// Версия с ближайшей длительностью, если она близко (3 с или 10 %): синхронный текст записи другой длины уезжает.
    /// Без длительности — с ближайшим по длине названием.
    public static func bestMatching(_ tracks: [LrcLibTrack], title: String, durationMs: Int64) -> LrcLibTrack? {
        let seconds = Double(durationMs / 1000)
        guard seconds > 0 else { return tracks.min { abs($0.trackName.count - title.count) < abs($1.trackName.count - title.count) } }
        guard let closest = tracks.min(by: { abs($0.duration - seconds) < abs($1.duration - seconds) }) else { return nil }
        return abs(closest.duration - seconds) <= max(3, seconds * 0.1) ? closest : nil
    }

    private func get(_ address: String) async throws -> [LrcLibTrack] {
        guard let url = URL(string: address) else { return [] }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(userAgent, forHTTPHeaderField: "Lrclib-Client")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([LrcLibTrack].self, from: data)
    }

    private func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
    }
}

// MARK: - KuGou

/// KuGou (Android `providers/kugou`, Windows `KuGou`): последняя линия синхронного текста.
public struct KuGou: Sendable {
    private let session: URLSession
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    public init(session: URLSession = HTTPConfiguration.session(timeout: 20)) {
        self.session = session
    }

    private struct SongResponse: Decodable {
        struct DataBlock: Decodable { let info: [Info]? }
        struct Info: Decodable {
            let duration: Int64
            let hash: String
        }
        let data: DataBlock?
    }

    private struct CandidatesResponse: Decodable {
        struct Candidate: Decodable {
            let id: StringOrNumber
            let accesskey: String
        }
        let candidates: [Candidate]?
    }

    /// KuGou отдаёт `id` то строкой, то числом.
    private struct StringOrNumber: Decodable {
        let value: String
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) { value = String(number) } else { value = try container.decode(String.self) }
        }
    }

    private struct DownloadResponse: Decodable { let content: String? }

    /// LRC трека: сначала песня с совпадающей длительностью (допуск до 5 с), потом поиск текста по словам.
    public func lyrics(artist: String, title: String, durationSeconds: Int64) async throws -> String? {
        let keyword = Self.keyword(artist: artist, title: title)
        let songs: SongResponse? = try await get(
            "https://mobileservice.kugou.com/api/v3/search/song?version=9108&plat=0&pagesize=8&showtype=0&keyword=\(escape(keyword))")
        let infos = songs?.data?.info ?? []
        for tolerance in 0...5 where !infos.isEmpty {
            for info in infos where abs(info.duration - durationSeconds) <= Int64(tolerance) {
                let byHash: CandidatesResponse? = try await get("https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&hash=\(info.hash)")
                if let candidate = byHash?.candidates?.first { return try await download(candidate) }
            }
        }
        let byKeyword: CandidatesResponse? = try await get("https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=\(escape(keyword))")
        guard let found = byKeyword?.candidates?.first else { return nil }
        return try await download(found)
    }

    private func download(_ candidate: CandidatesResponse.Candidate) async throws -> String? {
        let response: DownloadResponse? = try await get(
            "https://krcs.kugou.com/download?ver=1&man=yes&client=pc&fmt=lrc&id=\(candidate.id.value)&accesskey=\(candidate.accesskey)")
        guard let content = response?.content, let data = Data(base64Encoded: content) else { return nil }
        return Self.normalize(String(decoding: data, as: UTF8.self))
    }

    private func get<T: Decodable>(_ address: String) async throws -> T? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        // KuGou отвечает JSON-ом с типом text/plain или text/html
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
    }

    static func keyword(artist: String, title: String) -> String {
        var newTitle = title
        var featuring = ""
        if let from = title.range(of: " (feat. "), let to = title[from.upperBound...].firstIndex(of: ")") {
            featuring = String(title[from.upperBound..<to])
            newTitle.removeSubrange(from.lowerBound...to)
        }
        let newArtist = (featuring.isEmpty ? artist : "\(artist), \(featuring)")
            .replacingOccurrences(of: ", ", with: "、").replacingOccurrences(of: " & ", with: "、").replacingOccurrences(of: ".", with: "")
        return "\(newArtist) - \(newTitle)"
    }

    private static let metaPrefixes = ["[ti:", "[ar:", "[al:", "[by:", "[hash:", "[sign:", "[qq:", "[total:", "[offset:", "[id:"]
    private static let creditMarkers = ["]Written by：", "]Lyrics by：", "]Composed by：", "]Producer：", "]作曲 : ", "]作词 : "]

    /// Без служебных тегов и титров в начале (авторы, композитор), как у Android.
    static func normalize(_ value: String) -> String {
        let text = value.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var toDrop = 0, maybeToDrop = 0
        for line in text.components(separatedBy: "\n") {
            let utf16 = Array(line.utf16)
            let isCredit = creditMarkers.contains { marker in
                let markerUnits = Array(marker.utf16)
                return utf16.count >= 9 + markerUnits.count && Array(utf16[9..<(9 + markerUnits.count)]) == markerUnits
            }
            if metaPrefixes.contains(where: line.hasPrefix) || isCredit {
                toDrop += line.utf16.count + 1 + maybeToDrop
                maybeToDrop = 0
            } else if maybeToDrop == 0 {
                maybeToDrop = line.utf16.count + 1
            } else {
                maybeToDrop = 0
                break
            }
        }
        let units = Array(text.utf16)
        let drop = min(units.count, toDrop + maybeToDrop)
        return String(decoding: units[drop...], as: UTF16.self).replacingOccurrences(of: "&apos;", with: "'")
    }
}

private extension CharacterSet {
    /// Значение параметра запроса: без `&`, `=`, `+`, `?`, `#`.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

// MARK: - Цепочка

/// Итог поиска текста: `anyFailure` — хоть один источник не ответил из-за сети (такой пустой итог не кэшируется как
/// «текста нет»).
public struct LyricsFetchResult: Sendable {
    public var plain: String?
    public var synced: String?
    public var anyFailure: Bool
    public var plainSource: String?
    public var syncedSource: String?
    public var offsetMs: Int64?
    public var language: String?
}

/// Цепочка источников текста (docs/PROMPT.md §5.7, Android `LyricsFetcher.kt`, Windows `LyricsFetcher.cs`). Название
/// сначала проходит `TitleCleaner`: названия YouTube как есть ничего не находят.
///
/// Синхронный: у песни (есть альбом) — свой timed-текст YouTube Music, потом LRCLIB по очищенному названию и
/// длительности, потом KuGou; у видео LRCLIB первым (видео может идти не в такт песне). Обычный: YouTube Music, потом
/// LRCLIB. Стороны, которые уже есть в `current`, заново не ищутся. Если синхронного нет — текст с сервера Melogold
/// (`community`, подключает синк).
public final class LyricsFetcher: @unchecked Sendable {
    public let music: YouTubeMusic
    public let lrcLib: LrcLib
    public let kuGou: KuGou
    private let lock = NSLock()
    private var communityValue: (@Sendable (String) async throws -> (payload: LyricsPayload, mine: Bool)?)?

    public init(music: YouTubeMusic, lrcLib: LrcLib, kuGou: KuGou = KuGou()) {
        self.music = music
        self.lrcLib = lrcLib
        self.kuGou = kuGou
    }

    /// Точка подключения синка: своя версия или общая версия трека с сервера; `nil` — нет аккаунта, модуля текстов или
    /// текста. Спрашивается, только если провайдеры не нашли синхронный текст.
    public var community: (@Sendable (String) async throws -> (payload: LyricsPayload, mine: Bool)?)? {
        get { lock.withLock { communityValue } }
        set { lock.withLock { communityValue = newValue } }
    }

    public func fetch(_ track: Track, durationMs: Int64, current: StoredLyrics?) async -> LyricsFetchResult {
        let rawArtist = track.artistsText ?? ""
        let rawTitle = track.title
        let isSong = track.albumId != nil || track.albumTitle != nil
        let clean = TitleCleaner.clean(title: rawTitle, channel: rawArtist.isEmpty ? nil : rawArtist, videoType: isSong ? VideoType.song : nil)
        let artist = clean.artist ?? rawArtist
        let title = clean.title.trimmingCharacters(in: .whitespaces).isEmpty ? rawTitle : clean.title
        var anyFailure = false

        func attempt<T>(_ call: () async throws -> T?) async -> T? {
            do {
                return try await call()
            } catch let error as YouTubeError {
                if error.kind == .offline { anyFailure = true }
                return nil
            } catch is URLError {
                anyFailure = true
                return nil
            } catch {
                return nil
            }
        }

        // Вкладка «Текст» страницы трека; нет её — у YouTube Music текста нет
        var browseId: String?
        var browseKnown = false
        func lyricsBrowseId() async -> String? {
            if browseKnown { return browseId }
            browseKnown = true
            browseId = await attempt { try await music.next(videoId: track.videoId) }?.lyricsBrowseId
            return browseId
        }

        var plain = current?.plain
        var plainSource = current?.plainSource
        if plain == nil {
            if let id = await lyricsBrowseId(), let text = await attempt({ try await music.lyrics(id)?.text }) {
                plain = text
                plainSource = LyricsSources.youtubeMusic
            } else if let text = await attempt({ try await lrcLib.bestLyrics(artist: artist, title: title, durationMs: durationMs, synced: false) }) {
                plain = text
                plainSource = LyricsSources.lrclib
            }
        }

        func youTubeMusicTimed() async -> String? {
            guard let id = await lyricsBrowseId() else { return nil }
            return await attempt { try await music.timedLyrics(id) }
        }

        func lrcLibSynced() async -> String? {
            if let text = await attempt({ try await lrcLib.bestLyrics(artist: artist, title: title, durationMs: durationMs, synced: true) }) {
                return text
            }
            // Название как у трека, если очистка его изменила
            guard artist != rawArtist || title != rawTitle else { return nil }
            return await attempt { try await lrcLib.bestLyrics(artist: rawArtist, title: rawTitle, durationMs: durationMs, synced: true) }
        }

        var synced = current?.synced
        var syncedSource = current?.syncedSource
        var offset: Int64?
        var language: String?
        if synced == nil {
            var found: (text: String, source: String)?
            if isSong {
                if let text = await youTubeMusicTimed() { found = (text, LyricsSources.youtubeMusic) }
                else if let text = await lrcLibSynced() { found = (text, LyricsSources.lrclib) }
            } else {
                if let text = await lrcLibSynced() { found = (text, LyricsSources.lrclib) }
                else if let text = await youTubeMusicTimed() { found = (text, LyricsSources.youtubeMusic) }
            }
            if found == nil, let text = await attempt({ try await kuGou.lyrics(artist: artist, title: title, durationSeconds: durationMs / 1000) }) {
                found = (text, LyricsSources.kugou)
            }
            if let found {
                synced = found.text
                syncedSource = found.source
            }
        }
        if synced == nil, let community {
            do {
                if let found = try await community(track.videoId), let text = found.payload.synced {
                    // Своя версия остаётся своей, общая помечается «сообщество Melogold» и своей не становится
                    synced = text
                    syncedSource = found.mine ? found.payload.syncedSource : LyricsSources.melogold
                    if plain == nil, let communityPlain = found.payload.plain {
                        plain = communityPlain
                        plainSource = found.mine ? found.payload.plainSource : LyricsSources.melogold
                    }
                    offset = -(found.payload.startTimeMs ?? 0)
                    language = found.payload.language
                }
            } catch {
                anyFailure = true
            }
        }
        return LyricsFetchResult(plain: plain, synced: synced, anyFailure: anyFailure, plainSource: plainSource,
                                 syncedSource: syncedSource, offsetMs: offset, language: language)
    }
}
