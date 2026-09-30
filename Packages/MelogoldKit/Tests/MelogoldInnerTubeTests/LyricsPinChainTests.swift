import Foundation
import MelogoldCore
import Synchronization
import Testing
@testable import MelogoldInnerTube

/// Ответы провайдеров текстов, заданные тестом: LrcLib (поиск и запись по номеру), KuGou, YouTube Music. Запросы
/// записываются — видно, по каким названиям и в каком порядке спрашивали.
final class ProvidersStub: URLProtocol, @unchecked Sendable {
    struct Setup {
        var lrcLibSearch = "[]"
        /// Записи LrcLib по номеру; чего нет — 404.
        var lrcLibRecords: [String: String] = [:]
        var kuGouDownload: [String: String] = [:]
        var kuGouSearch: String?
        var timedLyrics: String?
        var plainLyrics: String?
        var requests: [String] = []
    }

    static let state = Mutex(Setup())

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProvidersStub.self]
        return URLSession(configuration: configuration)
    }

    static func reset(_ setup: Setup = Setup()) { state.withLock { $0 = setup } }
    static var requests: [String] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, body) = Self.state.withLock { state -> (Int, String) in
            state.requests.append(url.absoluteString)
            let path = url.path
            switch url.host {
            case "lrclib.net":
                if path.hasPrefix("/api/get/") {
                    let id = String(path.dropFirst("/api/get/".count))
                    return state.lrcLibRecords[id].map { (200, $0) } ?? (404, "{}")
                }
                return (200, state.lrcLibSearch)
            case "krcs.kugou.com" where path == "/download":
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
                return state.kuGouDownload[id].map { (200, "{\"content\":\"\(Data($0.utf8).base64EncodedString())\"}") } ?? (200, "{}")
            case "krcs.kugou.com":
                return (200, state.kuGouSearch ?? "{}")
            case "music.youtube.com":
                let androidMusic = request.value(forHTTPHeaderField: "User-Agent")?.contains("youtube.music") == true
                if let lines = androidMusic ? state.timedLyrics : nil {
                    return (200, "{\"contents\":{\"timedLyricsModel\":{\"lyricsData\":{\"timedLyricsData\":\(lines)}}}}")
                }
                if !androidMusic, let plain = state.plainLyrics {
                    return (200, "{\"contents\":{\"musicDescriptionShelfRenderer\":{\"description\":{\"runs\":[{\"text\":\"\(plain)\"}]}}}}")
                }
                return (200, "{}")
            default:
                return (200, "{}")
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Порядок выбора текста (задание 0015): свой → закреплённый → найденный; текст по ссылке для трёх поставщиков; ссылка
/// у найденного текста; названия, которые спрашивает поиск (задание 0014).
@Suite("Цепочка поиска текста — закрепление и ссылки", .serialized)
struct LyricsPinChainTests {
    // Две строки: KuGou отбрасывает служебные первые строки, из одной строки остался бы пустой текст
    static let pinnedLrc = "[00:01.00]Закреплённый\n[00:02.00]Текст"
    static let foundLrc = "[00:01.00]Найденный\n[00:02.00]Текст"

    let track = Track(videoId: "a1aaaaaaaaa", title: "Song", artistsText: "Artist", durationMs: 200_000)

    private func fetcher() -> LyricsFetcher {
        let session = ProvidersStub.session()
        return LyricsFetcher(
            music: YouTubeMusic(client: InnerTubeClient(session: session)), lrcLib: LrcLib(userAgent: "test", session: session), kuGou: KuGou(session: session)
        )
    }

    private func record(_ id: Int, synced: String?, plain: String? = nil, name: String = "Song") -> String {
        func json(_ text: String?) -> String { text.map { "\"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"" } ?? "null" }
        return "{\"id\":\(id),\"trackName\":\"\(name)\",\"artistName\":\"Artist\",\"duration\":200,\"plainLyrics\":\(json(plain)),\"syncedLyrics\":\(json(synced))}"
    }

    /// Закреплённый текст важнее найденного: поиск даже не нужен, а сдвиг «позже» закрепления становится сдвигом текста.
    @Test func pinnedLyricsWinOverSearch() async throws {
        ProvidersStub.reset(.init(lrcLibSearch: "[\(record(999, synced: Self.foundLrc, plain: "Найденный"))]",
                                  lrcLibRecords: ["123": record(123, synced: Self.pinnedLrc, plain: "Закреплённый")]))
        let pin = try #require(LyricsPin(source: "lrclib", ref: "123", startTimeMs: 400))
        let result = await fetcher().fetch(track, durationMs: 200_000, current: nil, pin: pin)
        #expect(result.synced == Self.pinnedLrc && result.plain == "Закреплённый")
        #expect(result.syncedSource == "lrclib" && result.syncedRef == "123" && result.plainRef == "123")
        #expect(result.offsetMs == -400)
        #expect(!ProvidersStub.requests.contains { $0.contains("/api/search") }, "поиск LrcLib не нужен")
    }

    /// Поставщик не отдал текст по ссылке — обычный поиск, закрепление остаётся (оно не в этой цепочке).
    @Test func missingPinnedTextFallsBackToSearch() async throws {
        ProvidersStub.reset(.init(lrcLibSearch: "[\(record(999, synced: Self.foundLrc, plain: "Найденный"))]"))
        let pin = try #require(LyricsPin(source: "lrclib", ref: "404"))
        let result = await fetcher().fetch(track, durationMs: 200_000, current: nil, pin: pin)
        #expect(result.synced == Self.foundLrc)
        #expect(result.syncedRef == "999" && result.plainRef == "999", "найденному тексту — ссылка на него")
        #expect(ProvidersStub.requests.contains { $0.hasSuffix("/api/get/404") })
    }

    /// Свой (набранный, выбранный) текст важнее закрепления: у трека уже есть синхронная сторона — закреплённое не берётся.
    @Test func ownLyricsBeatThePin() async throws {
        ProvidersStub.reset(.init(lrcLibRecords: ["123": record(123, synced: Self.pinnedLrc, plain: "Закреплённый")]))
        let own = StoredLyrics(synced: "[00:05.00]Мой", plain: "Мой", syncedSource: LyricsSources.user, plainSource: LyricsSources.user)
        let pin = try #require(LyricsPin(source: "lrclib", ref: "123"))
        let result = await fetcher().fetch(track, durationMs: 200_000, current: own, pin: pin)
        #expect(result.synced == "[00:05.00]Мой" && result.plain == "Мой")
        #expect(!ProvidersStub.requests.contains { $0.contains("/api/get/") }, "закрепление не запрашивалось")
    }

    @Test func youTubeMusicPinIsFetchedByBrowseId() async throws {
        ProvidersStub.reset(.init(timedLyrics: "[{\"lyricLine\":\"Раз\",\"cueRange\":{\"startTimeMilliseconds\":\"1000\"}}]", plainLyrics: "Раз"))
        let pin = try #require(LyricsPin(source: "youtube_music", ref: "MPLYt_abc"))
        let result = await fetcher().fetch(track, durationMs: 200_000, current: nil, pin: pin)
        #expect(result.synced == "[00:01.00]Раз" && result.plain == "Раз")
        #expect(result.syncedSource == "youtube_music" && result.syncedRef == "MPLYt_abc" && result.plainRef == "MPLYt_abc")
    }

    @Test func kuGouPinIsFetchedByIdAndAccessKey() async throws {
        ProvidersStub.reset(.init(kuGouDownload: ["42": Self.pinnedLrc]))
        let pin = try #require(LyricsPin(source: "kugou", ref: "42:abc"))
        let result = await fetcher().fetch(track, durationMs: 200_000, current: nil, pin: pin)
        #expect(result.synced == Self.pinnedLrc)
        #expect(result.syncedSource == "kugou" && result.syncedRef == "42:abc")
        let download = try #require(ProvidersStub.requests.first { $0.contains("krcs.kugou.com/download") })
        #expect(download.contains("id=42") && download.contains("accesskey=abc"))
        // Ссылка не той формы — не ломает поиск
        ProvidersStub.reset()
        let bad = try #require(LyricsPin(source: "kugou", ref: "42"))
        let none = await fetcher().fetch(track, durationMs: 200_000, current: nil, pin: bad)
        #expect(none.synced == nil)
    }

    /// LrcLib: у трека со своим названием сначала спрашивается правленое название, потом то, что дал YouTube.
    @Test func overriddenNamesAreAskedBeforeTheYouTubeOnes() async throws {
        ProvidersStub.reset()
        let fan = Track(videoId: "a1aaaaaaaaa", title: "Кино — Звезда (live, fan upload)", artistsText: "Fan Channel", durationMs: 200_000)
        let shown = TrackOverride(title: "Звезда", artistsText: "Кино").apply(to: fan)
        _ = await fetcher().fetch(shown, durationMs: 200_000, current: nil)
        let lrcLib = ProvidersStub.requests.filter { $0.contains("/api/search?track_name") }.map { $0.removingPercentEncoding ?? $0 }
        #expect(lrcLib.first?.contains("track_name=Звезда&artist_name=Кино") == true)
        #expect(lrcLib.contains { $0.contains("Fan Channel") || $0.contains("fan upload") }, "потом — название YouTube")
        #expect((lrcLib.firstIndex { $0.contains("track_name=Звезда&") } ?? 99) < (lrcLib.firstIndex { $0.contains("Fan Channel") || $0.contains("fan upload") } ?? -1))
        // Без правки второго обращения нет
        ProvidersStub.reset()
        _ = await fetcher().fetch(Track(videoId: "b2bbbbbbbbb", title: "Song", artistsText: "Artist", durationMs: 200_000), durationMs: 200_000, current: nil)
        #expect(ProvidersStub.requests.filter { $0.contains("/api/search?track_name") }.count == 2, "обычная и синхронная сторона — по одному обращению")
    }

    @Test func kuGouFoundTextKeepsItsRef() async throws {
        ProvidersStub.reset(.init(kuGouDownload: ["7": Self.foundLrc], kuGouSearch: "{\"candidates\":[{\"id\":\"7\",\"accesskey\":\"key\"}]}"))
        let result = await fetcher().fetch(track, durationMs: 200_000, current: nil)
        #expect(result.synced == Self.foundLrc && result.syncedSource == "kugou" && result.syncedRef == "7:key")
    }
}
