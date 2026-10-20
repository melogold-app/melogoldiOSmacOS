import Foundation
import Synchronization
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Подставные YouTube и googlevideo для тестов обрыва потока (задания 0025, 0026, 0033 §2). `player` на каждый запрос даёт
/// новый адрес того же файла (`n=1, 2, …`), googlevideo отвечает на каждый диапазон по сценарию теста: байты (206), код
/// ошибки или «нет сети». Каждый запрос записывается. В интернет тесты не ходят ни при каких условиях.
final class FakeGoogleVideo: URLProtocol, @unchecked Sendable {
    /// Запрос диапазона: какой трек, какие байты и каким по счёту он пришёл (с нуля).
    struct Request: Sendable, Equatable {
        var videoId: String
        var range: Range<Int>
        var number: Int
    }

    enum Answer: Sendable {
        case bytes
        case status(Int)
        case noNetwork
    }

    private struct State {
        var file = Data()
        var answer: @Sendable (Request) -> Answer = { _ in .bytes }
        var youTubeOffline = false
        var ranges: [Request] = []
        /// `videoId` каждого запроса `player`, в том числе ушедшего в пустоту без сети.
        var players: [String] = []
        /// Запросы `visitorData` (новый сеанс YouTube).
        var visitors = 0
    }

    private static let state = Mutex(State())

    /// Новый сценарий: файл `file` по любому адресу, googlevideo отвечает `answer`; `youTubeOffline` — сам YouTube без сети.
    static func serve(_ file: Data, youTubeOffline: Bool = false, answer: @escaping @Sendable (Request) -> Answer = { _ in .bytes }) {
        state.withLock { $0 = State(file: file, answer: answer, youTubeOffline: youTubeOffline) }
    }

    /// Сменить ответ googlevideo посреди теста (сеть вернулась).
    static func answer(_ answer: @escaping @Sendable (Request) -> Answer) {
        state.withLock { $0.answer = answer }
    }

    static var ranges: [Request] { state.withLock { $0.ranges } }
    static var players: [String] { state.withLock { $0.players } }
    static var visitors: Int { state.withLock { $0.visitors } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGoogleVideo.self]
        return URLSession(configuration: configuration)
    }

    /// Резолвер, каталог и сессия чтения на этой сети; `visitorData` уже есть, клиент потока — VISIONOS.
    static func stack(visitor: String = "test-visitor") async -> (resolver: StreamResolver, catalog: YouTubeMusic, client: InnerTubeClient) {
        let client = InnerTubeClient(session: session(), preferredLanguages: ["en-US"])
        await client.setVisitorData(visitor)
        let catalog = YouTubeMusic(client: client)
        let resolver = StreamResolver(catalog: catalog)
        await resolver.setClients([.visionOS])
        return (resolver, catalog, client)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://www.youtube.com")!
        if url.host?.contains("googlevideo") == true {
            answerRange(url)
        } else {
            answerYouTube(url)
        }
    }

    override func stopLoading() {}

    private func answerRange(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let videoId = query.first { $0.name == "id" }?.value ?? ""
        let header = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
        let bounds = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
        let (file, answer, seen) = Self.state.withLock { state -> (Data, Answer, Request) in
            let lower = bounds.first.flatMap { Int($0) } ?? 0
            let upper = min(bounds.count > 1 ? Int(bounds[1]) ?? state.file.count - 1 : state.file.count - 1, state.file.count - 1)
            let seen = Request(videoId: videoId, range: lower..<max(lower, upper + 1), number: state.ranges.count)
            state.ranges.append(seen)
            return (state.file, state.answer(seen), seen)
        }
        switch answer {
        case .bytes:
            let body = seen.range.isEmpty ? Data() : file.subdata(in: seen.range)
            let headers = ["Content-Range": "bytes \(seen.range.lowerBound)-\(seen.range.upperBound - 1)/\(file.count)", "Content-Type": "audio/mp4"]
            reply(url, status: 206, headers: headers, body: body)
        case .status(let code):
            reply(url, status: code, headers: [:], body: Data())
        case .noNetwork:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    private func answerYouTube(_ url: URL) {
        let body = Self.body(of: request)
        let videoId = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["videoId"] as? String
        let isPlayer = url.path.hasSuffix("/player")
        let (offline, number, length) = Self.state.withLock { state -> (Bool, Int, Int) in
            if isPlayer { state.players.append(videoId ?? "") } else { state.visitors += 1 }
            return (state.youTubeOffline, isPlayer ? state.players.count : state.visitors, state.file.count)
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let json: String
        if isPlayer, let videoId {
            json = """
                {"responseContext":{"visitorData":"visitor-p\(number)"},"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"60"},
                "streamingData":{"adaptiveFormats":[{"itag":140,
                "url":"https://rr1---sn-x.googlevideo.com/videoplayback?expire=4102444800&itag=140&id=\(videoId)&n=\(number)",
                "mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":128000,"contentLength":"\(length)","approxDurationMs":"60000"}]}}
                """
        } else {
            json = #"{"responseContext":{"visitorData":"visitor-\#(number)"}}"#
        }
        reply(url, status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    private func reply(_ url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

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
