import Foundation
import MelogoldCore
import Testing
@testable import MelogoldInnerTube

/// LRCLIB по запросу: `q=busy` — 503 (сервер перегружен), `q=limit` — 429, `q=none` — пустой список, остальное — один трек
/// с текстом. Ответ зависит только от запроса — тесты идут параллельно без общего состояния.
final class LrcLibStatusStub: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LrcLibStatusStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "q" || $0.name == "track_name" }?.value ?? ""
        let (status, body): (Int, String) = switch query {
        case "busy": (503, "<html>Service Unavailable</html>")
        case "limit": (429, "{}")
        case "none": (200, "[]")
        default: (200, #"[{"id":7,"trackName":"Кукушка","artistName":"Кино","albumName":null,"duration":403,"plainLyrics":"Песен ещё ненаписанных","syncedLyrics":null}]"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// «Найти текст»: LRCLIB не ответил — это не «текстов нет» (задание 0033 §6, Linux `4ed1034`).
@Suite("Поиск LRCLIB: не ответил или не нашёл")
struct LrcLibSearchTests {
    let lrcLib = LrcLib(userAgent: "test", session: LrcLibStatusStub.session())

    @Test func overloadedServerIsAnErrorNotAnEmptyList() async {
        await #expect(throws: LrcLibUnavailable(status: 503)) { try await lrcLib.search("busy") }
        await #expect(throws: LrcLibUnavailable(status: 429)) { try await lrcLib.search("limit") }
    }

    @Test func nothingFoundIsAnEmptyList() async throws {
        #expect(try await lrcLib.search("none").isEmpty)
        #expect(try await lrcLib.search("Кино Кукушка").map(\.id) == [7])
    }

    /// Цепочка поиска текста при этом считает перегруженный LRCLIB «не нашлось», как раньше, а не «нет сети».
    @Test func lyricsChainTreatsOverloadAsNotFound() async {
        let session = LrcLibStatusStub.session()
        let fetcher = LyricsFetcher(music: YouTubeMusic(client: InnerTubeClient(session: session)),
                                    lrcLib: LrcLib(userAgent: "test", session: session), kuGou: KuGou(session: session))
        let track = Track(videoId: "b1bbbbbbbbb", title: "busy", artists: [], artistsText: nil, durationMs: 200_000)
        let result = await fetcher.fetch(track, durationMs: 200_000, current: nil)
        #expect(!result.anyFailure)
        #expect(result.plain == nil)
    }
}
