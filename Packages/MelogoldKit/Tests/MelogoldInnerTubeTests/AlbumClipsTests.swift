import Foundation
import Synchronization
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

/// Клипы в списке альбома заменяются песнями из плейлиста альбома (задание 0029), а если плейлист их не дал — песнями из
/// поиска «Песни» (задание 0032). Фикстуры и случаи — как у Linux (`crates/melogold-innertube/tests/album_clips.rs`).
@Suite("Альбом: песни, а не клипы")
struct AlbumClipsTests {
    static let album = "MPREb_rMqWqQe5N3L"
    static let playlist = "VLOLAK5uy_np90iV2eD-YiScFePYgA7-i3c9kOYXMpc"
    static let estateSale = "MPREb_VpXYEs5HeNs"
    static let estateSalePlaylist = "VLOLAK5uy_kSIbgi-WxAiBFs28kWN1cMy7bewO3-LCs"

    static func album(_ name: String, _ browseId: String) throws -> AlbumDetails {
        try YouTubeMusic.parseAlbum(try Fixture.json("album-clips/\(name)"), browseId: browseId)
    }

    static func playlistTracks() throws -> [Track] {
        try YouTubeMusic.parsePlaylist(try Fixture.json("album-clips/call-me-if-you-get-lost.playlist.en"), browseId: playlist).tracks
    }

    static func songs(_ name: String) throws -> [Track] {
        YouTubeMusic.parseSearchPage(try Fixture.json("album-clips/\(name)")).items.compactMap(\.track)
    }

    /// Выдача поиска «Песни» из фикстур: LEMONHEAD и CORSO — записанные ответы, остальные запросы — пустая выдача.
    static func estateSaleSearch(_ query: String) throws -> ItemsPage {
        if query.contains("LEMONHEAD") { return ItemsPage(items: try songs("estate-sale.songs-lemonhead.en").map(MusicItem.track), continuation: nil) }
        if query.contains("CORSO") { return ItemsPage(items: try songs("estate-sale.songs-corso.en").map(MusicItem.track), continuation: nil) }
        return ItemsPage(items: [], continuation: nil)
    }

    // MARK: - Плейлист альбома (0029)

    /// 18.10.2026: LEMONHEAD показывал 2:11, а играл клип на 1:25 — текст песни расходился со звуком.
    @Test func albumClipsBecomeTheAlbumSongs() throws {
        var album = try Self.album("call-me-if-you-get-lost.album.en", Self.album)
        #expect(album.tracks.count == 16)
        #expect(album.tracks.allSatisfy { $0.videoType == VideoType.video }, "в записи все строки — клипы")
        #expect(album.album.playlistId == String(Self.playlist.dropFirst(2)), "плейлист альбома берётся из строк")

        #expect(YouTubeMusic.preferAlbumAudio(&album.tracks, audio: try Self.playlistTracks()) == 16)

        let lemonhead = try #require(album.tracks.first { $0.title.hasPrefix("LEMONHEAD") })
        #expect(lemonhead.videoId == "QjckqsLmb1o", "песня, а не клип a5JCltuobqQ")
        #expect(lemonhead.videoType == VideoType.song)
        #expect(lemonhead.durationMs == 131_000)
        #expect(lemonhead.albumId == Self.album, "альбом остаётся тем, который открыт")
        #expect(album.tracks.allSatisfy { $0.videoType == VideoType.song })
    }

    /// Плейлист без пары для строки (другой порядок, лишний трек) — строка находится по названию, а без пары остаётся
    /// клипом: лучше сыграть клип, чем чужую песню.
    @Test func aShuffledOrShortPlaylistMatchesByTitleOnly() throws {
        var album = try Self.album("call-me-if-you-get-lost.album.en", Self.album)
        var audio = try Self.playlistTracks()
        audio.reverse()
        audio.remove(at: try #require(audio.firstIndex { $0.title.hasPrefix("LEMONHEAD") }, "в плейлисте"))

        #expect(YouTubeMusic.preferAlbumAudio(&album.tracks, audio: audio) == 15)
        let lemonhead = try #require(album.tracks.first { $0.title.hasPrefix("LEMONHEAD") })
        #expect(lemonhead.videoId == "a5JCltuobqQ", "без пары — прежний клип")
        let corso = try #require(album.tracks.first { $0.title == "CORSO" })
        #expect(corso.videoType == VideoType.song)
    }

    // MARK: - Поиск «Песни» (0032)

    /// 20.10.2026: у переиздания «CALL ME IF YOU GET LOST: The Estate Sale» плейлист альбома пуст, и LEMONHEAD снова играл
    /// клип на 1:26 вместо песни на 2:11. Песню находит поиск «Песни»: то же название, исполнитель и длительность строки.
    @Test func estateSaleClipsFindTheirSongsBySearch() throws {
        let album = try Self.album("estate-sale.album.en", Self.estateSale)
        #expect(album.tracks.filter { $0.videoType == VideoType.video }.count == 16, "первые 16 строк — клипы")
        let playlistId = try #require(album.album.playlistId, "плейлист альбома")
        #expect(throws: YouTubeError.self, "плейлист пуст") {
            try YouTubeMusic.parsePlaylist(try Fixture.json("album-clips/estate-sale.playlist.en"), browseId: "VL" + playlistId)
        }

        for (title, file, clipId, songId, duration) in [
            ("LEMONHEAD (feat. 42 Dugg)", "estate-sale.songs-lemonhead.en", "a5JCltuobqQ", "QjckqsLmb1o", Int64(131_000)),
            ("CORSO", "estate-sale.songs-corso.en", "Lqvwm3zAILI", "qz-k3DoMxkw", Int64(147_000)),
        ] {
            let clip = try #require(album.tracks.first { $0.title == title })
            #expect(clip.videoId == clipId && clip.durationMs == duration, "в строке клип, длительность песни")
            let song = try #require(YouTubeMusic.songForClip(clip, found: try Self.songs(file)), "\(title)")
            #expect(song.videoId == songId && song.durationMs == duration)
        }
    }

    /// Пара строгая: другая длительность, другой исполнитель или строка без длительности — клип остаётся клипом.
    @Test func aSongFromSearchMustMatchTitleArtistAndDuration() throws {
        let album = try Self.album("estate-sale.album.en", Self.estateSale)
        let lemonhead = try #require(album.tracks.first { $0.title.hasPrefix("LEMONHEAD") })
        let found = try Self.songs("estate-sale.songs-lemonhead.en")

        var clipLength = lemonhead
        clipLength.durationMs = 86_000
        #expect(YouTubeMusic.songForClip(clipLength, found: found) == nil, "длительность клипа, а не песни")
        var noLength = lemonhead
        noLength.durationMs = nil
        #expect(YouTubeMusic.songForClip(noLength, found: found) == nil)
        var rounded = lemonhead
        rounded.durationMs = 132_500
        #expect(YouTubeMusic.songForClip(rounded, found: found)?.videoId == "QjckqsLmb1o", "округление в 1,5 с")

        let stranger = found.map { song in
            var other = song
            other.artists = [ArtistRef(id: "UCother", name: "Other")]
            other.artistsText = "Other"
            return other
        }
        #expect(YouTubeMusic.songForClip(lemonhead, found: stranger) == nil, "чужой исполнитель")
        var shouting = lemonhead
        shouting.title = "  lemonhead   (FEAT. 42 dugg) "
        #expect(YouTubeMusic.songForClip(shouting, found: found)?.videoId == "QjckqsLmb1o", "название — без регистра и лишних пробелов")
    }

    // MARK: - Весь путь альбома

    /// Плейлист дал все песни — поиск не нужен.
    @Test func aFullPlaylistNeedsNoSearch() async throws {
        var album = try Self.album("call-me-if-you-get-lost.album.en", Self.album)
        let audio = try Self.playlistTracks()
        let log = SearchLog()
        let failed = try await YouTubeMusic.replaceClips(in: &album, playlist: { _, _ in audio }, search: log.search { _ in throw YouTubeError(.unknown, "не нужен") })
        #expect(failed == nil)
        #expect(log.queries.isEmpty)
        #expect(album.tracks.allSatisfy { $0.videoType == VideoType.song })
    }

    /// Пустой плейлист — песни ищет поиск: по запросу на каждый клип, «исполнители строки + название»; пара нашлась у
    /// LEMONHEAD и CORSO (остальных ответов в фикстурах нет). Ошибку плейлиста сменяет итог поиска.
    @Test func anEmptyPlaylistFallsBackToSearch() async throws {
        var album = try Self.album("estate-sale.album.en", Self.estateSale)
        let rows = album.tracks
        let log = SearchLog()
        let failed = try await YouTubeMusic.replaceClips(
            in: &album,
            playlist: { playlistId, _ in
                try YouTubeMusic.parsePlaylist(try Fixture.json("album-clips/estate-sale.playlist.en"), browseId: "VL" + playlistId).tracks
            },
            search: log.search(Self.estateSaleSearch)
        )
        #expect(failed == nil, "пустой плейлист — не ошибка, раз поиск прошёл")
        #expect(log.queries.count == 16)
        #expect(log.queries.contains("Tyler, The Creator LEMONHEAD (feat. 42 Dugg)"))
        #expect(log.queries.contains("Tyler, The Creator CORSO"))

        let changed = zip(rows, album.tracks).filter { $0.videoId != $1.videoId }
        #expect(changed.map { [$0.videoId, $1.videoId] } == [["Lqvwm3zAILI", "qz-k3DoMxkw"], ["a5JCltuobqQ", "QjckqsLmb1o"]])
        for (row, song) in changed {
            #expect(song.title == row.title && song.durationMs == row.durationMs && song.albumId == Self.estateSale, "строка остаётся строкой")
            #expect(song.videoType == VideoType.song)
        }
        #expect(album.tracks.filter { $0.videoType == VideoType.video }.count == 14, "без пары — клипы")
    }

    /// Поиск не прошёл — клип остаётся клипом, альбом открывается, а ошибка возвращается: по ней починка библиотеки
    /// вернётся к альбому при следующем запуске.
    @Test func aFailedSearchKeepsTheClipAndReportsTheError() async throws {
        var album = try Self.album("estate-sale.album.en", Self.estateSale)
        let failed = try await YouTubeMusic.replaceClips(
            in: &album, playlist: { _, _ in [] },
            search: SearchLog().search { query in
                if query.hasSuffix("CORSO") { throw YouTubeError(.offline, "нет сети") }
                return try Self.estateSaleSearch(query)
            }
        )
        #expect((failed as? YouTubeError)?.kind == .offline)
        #expect(album.tracks.first { $0.title == "CORSO" }?.videoId == "Lqvwm3zAILI")
        #expect(album.tracks.first { $0.title.hasPrefix("LEMONHEAD") }?.videoId == "QjckqsLmb1o")
    }

    /// Проверка на бота останавливает всё сразу: новые поиски не начинаются (ушли только первые восемь), после плейлиста
    /// с проверкой поиск не идёт вовсе.
    @Test func aBotCheckStopsTheSearches() async throws {
        var album = try Self.album("estate-sale.album.en", Self.estateSale)
        let log = SearchLog()
        let failed = try await YouTubeMusic.replaceClips(in: &album, playlist: { _, _ in [] },
                                                         search: log.search { _ in throw YouTubeError(.blocked, "HTTP 429 from search") })
        #expect((failed as? YouTubeError)?.kind == .blocked)
        #expect(log.queries.count == YouTubeMusic.songSearchesAtOnce)
        #expect(album.tracks.filter { $0.videoType == VideoType.video }.count == 16)

        var again = try Self.album("estate-sale.album.en", Self.estateSale)
        let afterPlaylist = SearchLog()
        let playlistFailed = try await YouTubeMusic.replaceClips(
            in: &again, playlist: { _, _ in throw YouTubeError(.blocked, "HTTP 429 from browse") }, search: afterPlaylist.search(Self.estateSaleSearch)
        )
        #expect((playlistFailed as? YouTubeError)?.kind == .blocked)
        #expect(afterPlaylist.queries.isEmpty)
    }

    /// Поиски идут по восемь сразу, а не по одному и не все шестнадцать.
    @Test func searchesRunEightAtOnce() async throws {
        var album = try Self.album("estate-sale.album.en", Self.estateSale)
        let log = SearchLog()
        _ = try await YouTubeMusic.replaceClips(in: &album, playlist: { _, _ in [] }, search: log.search { query in
            try await Task.sleep(for: .milliseconds(50))
            return try Self.estateSaleSearch(query)
        })
        #expect(log.queries.count == 16)
        #expect((2...YouTubeMusic.songSearchesAtOnce).contains(log.mostAtOnce), "\(log.mostAtOnce)")
    }

    /// Один videoId дважды не берётся: две строки с одним названием получают одну песню на двоих — первая.
    @Test func aSongIsTakenOnce() async throws {
        let album = try Self.album("estate-sale.album.en", Self.estateSale)
        let lemonhead = try #require(album.tracks.first { $0.title.hasPrefix("LEMONHEAD") })
        var twice = lemonhead
        twice.videoId = "a5JCltuobq2"
        var tracks = [lemonhead, twice]
        let result = try await YouTubeMusic.songsForClips(&tracks, search: SearchLog().search(Self.estateSaleSearch))
        #expect(result.swapped == 1 && result.failed == nil)
        #expect(tracks.map(\.videoId) == ["QjckqsLmb1o", "a5JCltuobq2"])
    }
}

/// Запросы поиска из теста: тексты и сколько шло одновременно.
final class SearchLog: Sendable {
    private struct State {
        var queries: [String] = []
        var running = 0
        var mostAtOnce = 0
    }

    private let state = Mutex(State())

    var queries: [String] { state.withLock { $0.queries } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }

    func search(_ answer: @escaping @Sendable (String) async throws -> ItemsPage) -> @Sendable (String) async throws -> ItemsPage {
        { [self] query in
            state.withLock { state in
                state.queries.append(query)
                state.running += 1
                state.mostAtOnce = max(state.mostAtOnce, state.running)
            }
            defer { state.withLock { $0.running -= 1 } }
            return try await answer(query)
        }
    }
}

/// Пары «клип → песня» для починки библиотеки (задание 0033 §3) через настоящий `YouTubeMusic` на заглушке сети:
/// альбом, его плейлист и поиск отвечают фикстурами.
@Suite("Альбом: пары «клип → песня» на заглушке YouTube", .serialized)
struct AlbumTwinsTests {
    typealias T = AlbumClipsTests

    func catalog(_ respond: @escaping @Sendable (AlbumStub.Request) throws -> AlbumStub.Reply) async -> YouTubeMusic {
        let client = InnerTubeClient(session: AlbumStub.session(respond), preferredLanguages: ["en-US"])
        await client.setVisitorData("test-visitor")
        return YouTubeMusic(client: client)
    }

    /// Ответы фикстурами: альбом, плейлист, поиск «Песни» (`params` фильтра Songs); `searchFails` — поиск по этому
    /// названию отвечает ошибкой сервера.
    static func answer(_ request: AlbumStub.Request, searchFails: String? = nil) throws -> AlbumStub.Reply {
        switch (request.endpoint, request.browseId) {
        case ("browse", T.album): return .fixture("call-me-if-you-get-lost.album.en")
        case ("browse", T.playlist): return .fixture("call-me-if-you-get-lost.playlist.en")
        case ("browse", T.estateSale): return .fixture("estate-sale.album.en")
        case ("browse", T.estateSalePlaylist): return .fixture("estate-sale.playlist.en")
        case ("search", _):
            let query = request.query ?? ""
            if let searchFails, query.hasSuffix(searchFails) { return AlbumStub.Reply(status: 500, body: Data()) }
            if query.contains("LEMONHEAD") { return .fixture("estate-sale.songs-lemonhead.en") }
            if query.contains("CORSO") { return .fixture("estate-sale.songs-corso.en") }
            return AlbumStub.Reply(status: 200, body: Data("{}".utf8))
        default: return AlbumStub.Reply(status: 404, body: Data())
        }
    }

    @Test func twinsComeFromTheAlbumPlaylist() async throws {
        let twins = try await catalog { try Self.answer($0) }.albumTwins(T.album)
        #expect(twins.count == 16)
        let lemonhead = try #require(twins.first { $0.clipId == "a5JCltuobqQ" })
        #expect(lemonhead.song.videoId == "QjckqsLmb1o" && lemonhead.song.albumId == T.album && lemonhead.song.durationMs == 131_000)
        #expect(!AlbumStub.requests.contains { $0.endpoint == "search" }, "плейлист дал все песни")
    }

    @Test func twinsOfTheEstateSaleComeFromSearch() async throws {
        let twins = try await catalog { try Self.answer($0) }.albumTwins(T.estateSale)
        #expect(twins.map { [$0.clipId, $0.song.videoId] } == [["Lqvwm3zAILI", "qz-k3DoMxkw"], ["a5JCltuobqQ", "QjckqsLmb1o"]])
        #expect(twins.allSatisfy { $0.song.albumId == T.estateSale && $0.song.videoType == VideoType.song })
        let requests = AlbumStub.requests
        #expect(requests.filter { $0.endpoint == "browse" }.map(\.browseId) == [T.estateSale, T.estateSalePlaylist])
        #expect(requests.filter { $0.endpoint == "search" }.count == 16)
        #expect(requests.filter { $0.endpoint == "search" }.allSatisfy { $0.params == MusicSearchFilter.songs.params }, "фильтр «Песни»")
    }

    /// Поиск не прошёл: страница альбома открывается (LEMONHEAD — песня, CORSO — клип), а для починки это ошибка.
    @Test func aFailedSearchIsAnErrorForTheRepairButNotForTheAlbumPage() async throws {
        let catalog = await catalog { try Self.answer($0, searchFails: "CORSO") }
        let album = try await catalog.album(T.estateSale)
        #expect(album.tracks.first { $0.title == "CORSO" }?.videoId == "Lqvwm3zAILI")
        #expect(album.tracks.first { $0.title.hasPrefix("LEMONHEAD") }?.videoId == "QjckqsLmb1o")
        await #expect(throws: YouTubeError.self) { try await catalog.albumTwins(T.estateSale) }
    }

    /// Альбом без клипов — один запрос, как раньше.
    @Test func anAlbumWithoutClipsIsOneRequest() async throws {
        let catalog = await catalog { request in
            request.browseId == "MPREb_OLmD8O5IYNS" ? .fixture("album.en", in: "ytm") : AlbumStub.Reply(status: 404, body: Data())
        }
        #expect(try await catalog.albumTwins("MPREb_OLmD8O5IYNS").isEmpty)
        #expect(AlbumStub.requests.count == 1)
    }
}

/// Заглушка YouTube Music: ответ — по запросу теста, все запросы записываются.
final class AlbumStub: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var endpoint: String
        var browseId: String?
        var query: String?
        var params: String?
    }

    struct Reply {
        var status: Int
        var body: Data

        static func fixture(_ name: String, in folder: String = "album-clips") -> Reply {
            Reply(status: 200, body: (try? Fixture.data("\(folder)/\(name)")) ?? Data())
        }
    }

    private struct State {
        var respond: @Sendable (Request) throws -> Reply = { _ in Reply(status: 500, body: Data()) }
        var seen: [Request] = []
    }

    private static let state = Mutex(State())

    static func session(_ respond: @escaping @Sendable (Request) throws -> Reply) -> URLSession {
        state.withLock { $0 = State(respond: respond) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlbumStub.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [Request] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = (try? JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]) ?? [:]
        let seen = Request(endpoint: request.url?.lastPathComponent ?? "", browseId: body["browseId"] as? String,
                           query: body["query"] as? String, params: body["params"] as? String)
        let respond = Self.state.withLock { state in
            state.seen.append(seen)
            return state.respond
        }
        let reply = (try? respond(seen)) ?? Reply(status: 500, body: Data())
        let url = request.url ?? URL(string: "https://music.youtube.com")!
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` отдаёт тело потоком, а не `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
