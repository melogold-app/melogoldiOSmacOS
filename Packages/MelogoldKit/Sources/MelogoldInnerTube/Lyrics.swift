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

    /// Версия трека, ближайшая по длительности, с нужной стороной текста; синхронный — только в пределах max(3 с, 10 %).
    public func bestMatch(artist: String, title: String, durationMs: Int64, synced: Bool) async throws -> LrcLibTrack? {
        let tracks = try await search(artist: artist, title: title).filter { synced ? $0.syncedLyrics != nil : $0.plainLyrics != nil }
        return Self.bestMatching(tracks, title: title, durationMs: durationMs)
    }

    /// Текст версии трека, ближайшей по длительности; синхронный — только в пределах max(3 с, 10 %).
    public func bestLyrics(artist: String, title: String, durationMs: Int64, synced: Bool) async throws -> String? {
        let best = try await bestMatch(artist: artist, title: title, durationMs: durationMs, synced: synced)
        return synced ? best?.syncedLyrics : best?.plainLyrics
    }

    /// Запись LrcLib по номеру — текст закреплённого трека (задание 0015): `GET /api/get/{id}`. `nil` — записи нет.
    public func track(id: Int64) async throws -> LrcLibTrack? {
        guard let url = URL(string: "\(Self.baseURL)/api/get/\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(userAgent, forHTTPHeaderField: "Lrclib-Client")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(LrcLibTrack.self, from: data)
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

    /// LRC трека и его номер у KuGou (`<id>:<accesskey>`, задание 0015).
    public struct Found: Sendable, Equatable {
        public let text: String
        public let ref: String
    }

    /// LRC трека: сначала песня с совпадающей длительностью (допуск до 5 с), потом поиск текста по словам.
    public func lyrics(artist: String, title: String, durationSeconds: Int64) async throws -> String? {
        try await lyricsWithRef(artist: artist, title: title, durationSeconds: durationSeconds)?.text
    }

    /// То же, но вместе со ссылкой на текст: из неё строится закрепление.
    public func lyricsWithRef(artist: String, title: String, durationSeconds: Int64) async throws -> Found? {
        let keyword = Self.keyword(artist: artist, title: title)
        let songs: SongResponse? = try await get(
            "https://mobileservice.kugou.com/api/v3/search/song?version=9108&plat=0&pagesize=8&showtype=0&keyword=\(escape(keyword))")
        let infos = songs?.data?.info ?? []
        for tolerance in 0...5 where !infos.isEmpty {
            for info in infos where abs(info.duration - durationSeconds) <= Int64(tolerance) {
                let byHash: CandidatesResponse? = try await get("https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&hash=\(info.hash)")
                if let candidate = byHash?.candidates?.first { return try await found(candidate) }
            }
        }
        let byKeyword: CandidatesResponse? = try await get("https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=\(escape(keyword))")
        guard let candidate = byKeyword?.candidates?.first else { return nil }
        return try await found(candidate)
    }

    /// Текст закреплённого трека по ссылке `<id>:<accesskey>`; `nil` — ссылка не той формы или текста уже нет.
    public func lyrics(ref: String) async throws -> String? {
        let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return try await download(id: parts[0], accesskey: parts[1])
    }

    private func found(_ candidate: CandidatesResponse.Candidate) async throws -> Found? {
        guard let text = try await download(id: candidate.id.value, accesskey: candidate.accesskey) else { return nil }
        return Found(text: text, ref: "\(candidate.id.value):\(candidate.accesskey)")
    }

    private func download(id: String, accesskey: String) async throws -> String? {
        let response: DownloadResponse? = try await get(
            "https://krcs.kugou.com/download?ver=1&man=yes&client=pc&fmt=lrc&id=\(escape(id))&accesskey=\(escape(accesskey))")
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
    /// Текст взят из своей версии пользователя на сервере (`mine`): он выбран и остаётся своим (задание 0011 §2.3).
    public var chosen: Bool = false
    /// Ссылка на найденный текст у поставщика (задание 0015): из неё строится закрепление.
    public var plainRef: String?
    public var syncedRef: String?

    public init(
        plain: String? = nil, synced: String? = nil, anyFailure: Bool = false, plainSource: String? = nil, syncedSource: String? = nil,
        offsetMs: Int64? = nil, language: String? = nil, chosen: Bool = false, plainRef: String? = nil, syncedRef: String? = nil
    ) {
        self.plain = plain
        self.synced = synced
        self.anyFailure = anyFailure
        self.plainSource = plainSource
        self.syncedSource = syncedSource
        self.offsetMs = offsetMs
        self.language = language
        self.chosen = chosen
        self.plainRef = plainRef
        self.syncedRef = syncedRef
    }

    /// Найденное в форме для записи в базу (`LyricsRules.mergeFetched`): «искали, не нашли» — пустая строка стороны,
    /// «сеть не ответила» — `nil`.
    public var found: FoundLyrics {
        FoundLyrics(
            synced: synced ?? (anyFailure ? nil : ""), plain: plain ?? (anyFailure ? nil : ""),
            syncedSource: syncedSource, plainSource: plainSource, offsetMs: offsetMs, language: language, chosen: chosen,
            syncedRef: syncedRef, plainRef: plainRef
        )
    }
}

/// Текст закрепления у его поставщика (задание 0015).
struct PinnedLyrics: Sendable {
    let source: String
    let ref: String
    let synced: String?
    let plain: String?
}

/// Цепочка источников текста (docs/PROMPT.md §5.7, Android `LyricsFetcher.kt`, Windows `LyricsFetcher.cs`). Название
/// сначала проходит `TitleCleaner`: названия YouTube как есть ничего не находят.
///
/// Порядок выбора текста трека (задание 0015): свой (набранный, из файла, выбранный: он уже в `current`) → закреплённый
/// (`pin`: другие устройства аккаунта показывают его, а не ищут свой) → поиск → общий с сервера. Закреплённый текст берётся
/// у поставщика по ссылке; поставщик не отвечает или текста там нет — поиск идёт как обычно, закрепление остаётся.
///
/// Поиск. Синхронный: у песни (есть альбом) — свой timed-текст YouTube Music, потом LRCLIB по очищенному названию и
/// длительности, потом KuGou; у видео LRCLIB первым (видео может идти не в такт песне). Обычный: YouTube Music, потом
/// LRCLIB. Название спрашивается сначала своё (задание 0014: загрузки фанатов находят по правленому названию), потом то,
/// как назвал YouTube. Стороны, которые уже есть в `current`, заново не ищутся. Если синхронного нет — текст с сервера
/// Melogold (`community`, подключает синк).
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

    public func fetch(_ track: Track, durationMs: Int64, current: StoredLyrics?, pin: LyricsPin? = nil) async -> LyricsFetchResult {
        // Свои названия (задание 0014) спрашиваются первыми, потом название YouTube
        let original = track.raw
        let rawArtist = track.artistsText ?? ""
        let rawTitle = track.title
        let isSong = original.albumId != nil || original.albumTitle != nil
        let clean = TitleCleaner.clean(title: rawTitle, channel: rawArtist.isEmpty ? nil : rawArtist, videoType: isSong ? VideoType.song : nil)
        let artist = clean.artist ?? rawArtist
        let title = clean.title.trimmingCharacters(in: .whitespaces).isEmpty ? rawTitle : clean.title
        let youTubeName: (artist: String, title: String)? = track.isOverridden ? {
            let youTubeArtist = original.artistsText ?? ""
            let cleaned = TitleCleaner.clean(title: original.title, channel: youTubeArtist.isEmpty ? nil : youTubeArtist,
                                             videoType: isSong ? VideoType.song : nil)
            let name = (cleaned.artist ?? youTubeArtist, cleaned.title.trimmingCharacters(in: .whitespaces).isEmpty ? original.title : cleaned.title)
            return name == (artist, title) ? nil : name
        }() : nil
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

        // Закреплённый текст — у поставщика по ссылке, пока своего синхронного нет
        var pinned: PinnedLyrics?
        if let pin, current?.synced == nil {
            pinned = await pinnedLyrics(pin)
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

        /// Запись LrcLib по названию: своему, затем названию YouTube.
        func lrcLibMatch(synced: Bool, allowRaw: Bool) async -> LrcLibTrack? {
            if let found = await attempt({ try await lrcLib.bestMatch(artist: artist, title: title, durationMs: durationMs, synced: synced) }) {
                return found
            }
            // Название как у трека, если очистка его изменила
            if allowRaw, artist != rawArtist || title != rawTitle,
               let found = await attempt({ try await lrcLib.bestMatch(artist: rawArtist, title: rawTitle, durationMs: durationMs, synced: synced) }) {
                return found
            }
            if let youTubeName {
                return await attempt { try await lrcLib.bestMatch(artist: youTubeName.artist, title: youTubeName.title, durationMs: durationMs, synced: synced) }
            }
            return nil
        }

        var plain = current?.plain
        var plainSource = current?.plainSource
        var plainRef = current?.plainRef
        if plain == nil {
            if let text = pinned?.plain, let pinned {
                plain = text
                plainSource = pinned.source
                plainRef = pinned.ref
            } else if let id = await lyricsBrowseId(), let text = await attempt({ try await music.lyrics(id)?.text }) {
                plain = text
                plainSource = LyricsSources.youtubeMusic
                plainRef = id
            } else if let match = await lrcLibMatch(synced: false, allowRaw: false), let text = match.plainLyrics {
                plain = text
                plainSource = LyricsSources.lrclib
                plainRef = String(match.id)
            }
        }

        func youTubeMusicTimed() async -> (text: String, ref: String)? {
            guard let id = await lyricsBrowseId(), let text = await attempt({ try await music.timedLyrics(id) }) else { return nil }
            return (text, id)
        }

        func lrcLibSynced() async -> (text: String, ref: String)? {
            guard let match = await lrcLibMatch(synced: true, allowRaw: true), let text = match.syncedLyrics else { return nil }
            return (text, String(match.id))
        }

        var synced = current?.synced
        var syncedSource = current?.syncedSource
        var syncedRef = current?.syncedRef
        var offset: Int64?
        var language: String?
        if synced == nil {
            if let text = pinned?.synced, let pinned {
                synced = text
                syncedSource = pinned.source
                syncedRef = pinned.ref
                offset = -(pin?.startTimeMs ?? 0)
            } else {
                var found: (text: String, source: String, ref: String?)?
                if isSong {
                    if let value = await youTubeMusicTimed() { found = (value.text, LyricsSources.youtubeMusic, value.ref) }
                    else if let value = await lrcLibSynced() { found = (value.text, LyricsSources.lrclib, value.ref) }
                } else {
                    if let value = await lrcLibSynced() { found = (value.text, LyricsSources.lrclib, value.ref) }
                    else if let value = await youTubeMusicTimed() { found = (value.text, LyricsSources.youtubeMusic, value.ref) }
                }
                if found == nil, let kugou = await attempt({ try await kuGou.lyricsWithRef(artist: artist, title: title, durationSeconds: durationMs / 1000) }) {
                    found = (kugou.text, LyricsSources.kugou, kugou.ref)
                }
                if let found {
                    synced = found.text
                    syncedSource = found.source
                    syncedRef = found.ref
                }
            }
        }
        var chosen = false
        if synced == nil, let community {
            do {
                if let found = try await community(track.videoId) {
                    // Своя версия остаётся своей (и выбранной, с любым источником), общая помечается «сообщество Melogold»
                    // и своей не становится
                    let text = found.payload.synced?.isEmpty == false ? found.payload.synced : nil
                    let communityPlain = found.payload.plain?.isEmpty == false ? found.payload.plain : nil
                    if let text {
                        synced = text
                        syncedSource = found.mine ? found.payload.syncedSource : LyricsSources.melogold
                        syncedRef = nil
                        offset = -(found.payload.startTimeMs ?? 0)
                        language = found.payload.language
                        chosen = found.mine
                    }
                    // Общий текст без синхронной стороны — только обычный — тоже показывается
                    if plain == nil, let communityPlain {
                        plain = communityPlain
                        plainSource = found.mine ? found.payload.plainSource : LyricsSources.melogold
                        plainRef = nil
                        language = language ?? found.payload.language
                        chosen = chosen || found.mine
                    }
                }
            } catch {
                anyFailure = true
            }
        }
        return LyricsFetchResult(plain: plain, synced: synced, anyFailure: anyFailure, plainSource: plainSource,
                                 syncedSource: syncedSource, offsetMs: offset, language: language, chosen: chosen,
                                 plainRef: plainRef, syncedRef: syncedRef)
    }

    /// Текст закрепления у поставщика по ссылке: LrcLib — `GET /api/get/{id}`, YouTube Music — вкладка «Текст» по
    /// `MPLYt…` (обычный и синхронный), KuGou — `download?id=…&accesskey=…`. `nil` — поставщик не отвечает или текста
    /// по ссылке нет.
    private func pinnedLyrics(_ pin: LyricsPin) async -> PinnedLyrics? {
        // Сеть и ошибки поставщика — `nil`; отдельный счётчик сбоя не нужен: поиск пойдёт дальше сам
        func text(_ call: @escaping () async throws -> String?) async -> String? { try? await call() ?? nil }
        var synced: String?
        var plain: String?
        switch pin.source {
        case LyricsSources.lrclib:
            guard let id = Int64(pin.ref), let record = try? await lrcLib.track(id: id) else { return nil }
            synced = record.syncedLyrics?.nilIfBlankText
            plain = record.plainLyrics?.nilIfBlankText
        case LyricsSources.youtubeMusic:
            let (timed, plainText) = await (text { try await self.music.timedLyrics(pin.ref) }, text { try await self.music.lyrics(pin.ref)?.text })
            synced = timed
            plain = plainText
        case LyricsSources.kugou:
            synced = await text { try await self.kuGou.lyrics(ref: pin.ref) }
        default:
            return nil
        }
        guard synced != nil || plain != nil else { return nil }
        return PinnedLyrics(source: pin.source, ref: pin.ref, synced: synced, plain: plain)
    }
}

private extension String {
    var nilIfBlankText: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
