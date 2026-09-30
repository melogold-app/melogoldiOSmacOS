import Foundation
import Synchronization
import Testing
import MelogoldCore
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Заглушка YouTube: каждый запрос отвечает по сценарию теста и записывается — каким клиентом и про какой трек спросили.
/// Нужна, чтобы проверить главное правило проверки на бота: после неё к YouTube не уходит ни одного лишнего запроса.
final class YouTubeStub: URLProtocol, @unchecked Sendable {
    struct Seen: Equatable {
        /// `X-YouTube-Client-Name`: 101 — VISIONOS, 28 — ANDROID_VR, 1 — WEB (диагноз), 67 — WEB_REMIX.
        var clientId: String
        var videoId: String
    }

    struct Reply {
        var status: Int
        var body: String

        static func json(_ body: String, status: Int = 200) -> Reply { Reply(status: status, body: body) }
    }

    private struct State {
        var respond: @Sendable (Seen) -> Reply = { _ in Reply(status: 500, body: "") }
        var seen: [Seen] = []
    }

    private static let state = Mutex(State())

    static func session(_ respond: @escaping @Sendable (Seen) -> Reply) -> URLSession {
        state.withLock { $0 = State(respond: respond) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YouTubeStub.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [Seen] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let videoId = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["videoId"] as? String ?? ""
        let seen = Seen(clientId: request.value(forHTTPHeaderField: "X-YouTube-Client-Name") ?? "", videoId: videoId)
        let reply = Self.state.withLock { state -> Reply in
            state.seen.append(seen)
            return state.respond(seen)
        }
        let url = request.url ?? URL(string: "https://www.youtube.com")!
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
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

/// Флаг для сценария заглушки: «адрес открылся».
final class OpenSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// Часы, которыми резолвер считает срок метки.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Проверка на бота — это адрес, а не клиент и не трек: один запрос, и всё встаёт. Ни другого клиента, ни диагноза, ни
/// повтора, ни пропуска (YouTube считает запросы гостей по адресу, лишний запрос углубляет блок).
@Suite("Проверка на бота — всё сразу", .serialized)
struct BotCheckStopTests {
    static let loginRequired = #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}}"#
    static let streamOK = """
        {"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"250"},"streamingData":{"adaptiveFormats":[
        {"itag":140,"url":"https://rr1---sn-x.googlevideo.com/videoplayback?expire=4102444800&itag=140",
        "mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":130000,"contentLength":"4000000","approxDurationMs":"250000"}]}}
        """

    /// Резолвер на заглушке; `visitorData` уже есть, чтобы к делу не примешивался запрос WEB_REMIX. `now` — часы
    /// резолвера (срок метки «адрес закрыт»).
    func resolver(now: @escaping @Sendable () -> Date = { Date() },
                  _ respond: @escaping @Sendable (YouTubeStub.Seen) -> YouTubeStub.Reply) async -> (StreamResolver, YouTubeMusic) {
        let client = InnerTubeClient(session: YouTubeStub.session(respond), preferredLanguages: ["en-US"])
        await client.setVisitorData("test-visitor")
        let catalog = YouTubeMusic(client: client)
        return (StreamResolver(catalog: catalog, now: now), catalog)
    }

    /// Класс ошибки, которой закончился `resolve` (`nil` — поток получен).
    func botCheck(_ resolver: StreamResolver, _ videoId: String, userInitiated: Bool = false) async -> StreamError.Kind? {
        do {
            _ = try await resolver.resolve(videoId, userInitiated: userInitiated)
            return nil
        } catch let error as StreamError {
            return error.kind
        } catch {
            return .extractor
        }
    }

    // MARK: Правила ошибки

    @Test func botCheckHasNoRetriesAndStopsTheQueue() {
        let bot = StreamError(.botCheck, "LOGIN_REQUIRED Sign in to confirm you’re not a bot")
        #expect(bot.retries == 0)
        #expect(bot.stopsQueue)
        #expect(!bot.isFinal, "это не причина в видео: пропуска нет")
        // Остальные классы очередь не останавливают, а их повторы прежние
        let others: [(StreamError.Kind, Int)] = [(.network, 2), (.timeout, 1), (.extractor, 1), (.geo, 0), (.unavailable, 0), (.age, 0)]
        for (kind, retries) in others {
            let error = StreamError(kind, "")
            #expect(!error.stopsQueue, "\(kind)")
            #expect(error.retries == retries, "\(kind)")
        }
        #expect(PlaybackFailure(bot, videoId: "x").kind == .botCheck)
    }

    @Test func botCheckAndAgeAreToldApart() {
        #expect(StreamError.classify("LOGIN_REQUIRED Sign in to confirm you’re not a bot") == .botCheck)
        #expect(StreamError.classify("LOGIN_REQUIRED Sign in to confirm you're not a bot") == .botCheck)
        #expect(StreamError.classify("Sign in to confirm your age") == .age)
        #expect(StreamError.classify("LOGIN_REQUIRED Sign in to confirm your age") == .age)
        #expect(StreamError.classify("AGE_CHECK_REQUIRED Sign in to confirm your age") == .age)
    }

    // MARK: Резолвер

    @Test func botCheckFromTheFirstClientNeverAsksTheSecond() async {
        let (resolver, _) = await resolver { _ in .json(Self.loginRequired) }
        do {
            _ = try await resolver.resolve("dQw4w9WgXcQ")
            Issue.record("проверка на бота не должна давать поток")
        } catch let error as StreamError {
            #expect(error.kind == .botCheck && error.stopsQueue)
        } catch {
            Issue.record("не StreamError: \(error)")
        }
        // Один запрос, первому клиенту: ни ANDROID_VR, ни диагноза клиентом WEB
        #expect(YouTubeStub.requests == [.init(clientId: "101", videoId: "dQw4w9WgXcQ")])
    }

    /// 403 и 429 от самого `player` — тоже проверка на бота (`YouTubeError.blocked`): один запрос и стоп.
    @Test(arguments: [403, 429])
    func blockedStatusIsABotCheckToo(status: Int) async {
        let (resolver, _) = await resolver { _ in .json("", status: status) }
        do {
            _ = try await resolver.resolve("dQw4w9WgXcQ")
            Issue.record("HTTP \(status) не должен давать поток")
        } catch let error as StreamError {
            #expect(error.kind == .botCheck, "HTTP \(status)")
        } catch {
            Issue.record("не StreamError: \(error)")
        }
        #expect(YouTubeStub.requests.map(\.clientId) == ["101"], "HTTP \(status)")
    }

    /// Обратное: сбой самого клиента (не бот) по-прежнему переходит к следующему клиенту.
    @Test func otherFailuresStillFallBackToTheNextClient() async throws {
        let (resolver, _) = await resolver { seen in
            seen.clientId == "101" ? .json("", status: 500) : .json(Self.streamOK)
        }
        let info = try await resolver.resolve("dQw4w9WgXcQ")
        #expect(info.source == "ANDROID_VR" && info.itag == 140)
        #expect(YouTubeStub.requests.map(\.clientId) == ["101", "28"])
    }

    // MARK: Плеер

    /// Первый трек очереди получает проверку на бота: карточка с причиной сразу. Ни повтора (тот же трек не
    /// запрашивается снова), ни пропуска (индекс прежний, плашки «Пропущен…» нет), ни другого клиента и диагноза.
    @MainActor
    @Test func playerStopsAtOnceWithoutRetrySkipOrNotice() async throws {
        let (resolver, catalog) = await resolver { _ in .json(Self.loginRequired) }
        let engine = PlayerEngine(catalog: catalog, resolver: resolver, cache: nil)
        engine.volume = 0
        engine.autoplayEnabled = false
        let tracks = ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"].map { Track(videoId: $0, title: $0, durationMs: 200_000) }
        engine.play(tracks: tracks, startAt: 0)
        let started = Date()
        while engine.phase != .failed, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.phase == .failed)
        #expect(engine.failure?.kind == .botCheck)
        // С запасом на повтор или пропуск, если бы они были
        try await Task.sleep(for: .seconds(1.5))
        #expect(engine.phase == .failed, "повтор или пропуск вернули бы загрузку")
        #expect(engine.index == 0, "пропуска нет")
        #expect(engine.notice == nil, "плашки «Пропущен…» нет")
        let seen = YouTubeStub.requests
        #expect(seen.filter { $0.videoId == "aaaaaaaaaaa" }.count == 1, "повтора нет, второго клиента нет")
        #expect(seen.allSatisfy { $0.clientId == "101" }, "ни ANDROID_VR, ни диагноза WEB: \(seen)")
        // Заготовка двух следующих треков: второй трек мог уйти вместе с первым, третий — уже нет (адрес закрыт)
        #expect(seen.filter { $0.videoId == "ccccccccccc" }.isEmpty, "третий трек не заготавливается: \(seen)")
        #expect(seen.count <= 2, "\(seen)")
        engine.stop()
    }

    /// Действие пользователя пробует один запрос, фон — ни одного: «Повторить» и «Далее» стоят по запросу, а заготовка
    /// следующих треков при этом молчит.
    @MainActor
    @Test func userActionsTryOneRequestEachAndPrefetchStaysQuiet() async throws {
        let (resolver, catalog) = await resolver { _ in .json(Self.loginRequired) }
        let engine = PlayerEngine(catalog: catalog, resolver: resolver, cache: nil)
        engine.volume = 0
        engine.autoplayEnabled = false
        let tracks = ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc", "ddddddddddd"].map { Track(videoId: $0, title: $0, durationMs: 200_000) }
        engine.play(tracks: tracks, startAt: 0)
        try await waitForFailure(engine)
        try await Task.sleep(for: .seconds(0.5))
        func count(_ id: String) -> Int { YouTubeStub.requests.filter { $0.videoId == id }.count }
        let before = YouTubeStub.requests.count
        let (a0, b0, c0, d0) = (count("aaaaaaaaaaa"), count("bbbbbbbbbbb"), count("ccccccccccc"), count("ddddddddddd"))

        // «Повторить»: один запрос для этого трека; заготовка b и c — без запросов (адрес закрыт)
        engine.retryCurrent()
        try await waitForFailure(engine)
        try await Task.sleep(for: .seconds(0.5))
        #expect(engine.failure?.kind == .botCheck)
        #expect(count("aaaaaaaaaaa") == a0 + 1, "«Повторить» — ровно один запрос")
        #expect((count("bbbbbbbbbbb"), count("ccccccccccc"), count("ddddddddddd")) == (b0, c0, d0), "фон молчит: \(YouTubeStub.requests)")

        // «Далее»: один запрос для следующего трека
        engine.next()
        try await waitForFailure(engine)
        try await Task.sleep(for: .seconds(0.5))
        #expect(engine.index == 1)
        #expect(count("bbbbbbbbbbb") == b0 + 1, "«Далее» — ровно один запрос")
        #expect(count("aaaaaaaaaaa") == a0 + 1 && count("ccccccccccc") == c0 && count("ddddddddddd") == d0)
        #expect(YouTubeStub.requests.count == before + 2)
        engine.stop()
    }

    @MainActor
    private func waitForFailure(_ engine: PlayerEngine) async throws {
        let started = Date()
        while engine.phase != .failed, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.phase == .failed)
    }

    // MARK: Метка «адрес закрыт» в резолвере

    @Test func afterABotCheckPrefetchMakesNoRequestsAndAUserRetryMakesOne() async {
        let (resolver, _) = await resolver { _ in .json(Self.loginRequired) }
        #expect(await botCheck(resolver, "aaaaaaaaaaa", userInitiated: true) == .botCheck)
        #expect(YouTubeStub.requests.count == 1)
        #expect(await resolver.blockedError?.kind == .botCheck)
        // Заготовка двух следующих треков: ни одного запроса, та же ошибка
        #expect(await botCheck(resolver, "bbbbbbbbbbb") == .botCheck)
        #expect(await botCheck(resolver, "ccccccccccc") == .botCheck)
        #expect(YouTubeStub.requests.count == 1)
        // Пользователь: ровно один запрос
        #expect(await botCheck(resolver, "bbbbbbbbbbb", userInitiated: true) == .botCheck)
        #expect(YouTubeStub.requests == [.init(clientId: "101", videoId: "aaaaaaaaaaa"), .init(clientId: "101", videoId: "bbbbbbbbbbb")])
        // …и фон после него по-прежнему молчит
        #expect(await botCheck(resolver, "ccccccccccc") == .botCheck)
        #expect(YouTubeStub.requests.count == 2)
    }

    @Test func backgroundResolvesRunOneAtATimeSoABlockCostsOneRequest() async {
        let (resolver, _) = await resolver { _ in .json(Self.loginRequired) }
        await withTaskGroup(of: Void.self) { group in
            for id in ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"] {
                group.addTask { _ = try? await resolver.resolve(id) }
            }
        }
        #expect(YouTubeStub.requests.count == 1, "\(YouTubeStub.requests)")
    }

    @Test func successClearsTheBlock() async {
        let open = OpenSwitch()
        let (resolver, _) = await resolver { _ in open.value ? .json(Self.streamOK) : .json(Self.loginRequired) }
        #expect(await botCheck(resolver, "aaaaaaaaaaa", userInitiated: true) == .botCheck)
        #expect(await botCheck(resolver, "bbbbbbbbbbb") == .botCheck)
        #expect(YouTubeStub.requests.count == 1)
        // Адрес открылся: пользователь получает поток, метка снята, фон снова ходит в YouTube
        open.value = true
        #expect(await botCheck(resolver, "bbbbbbbbbbb", userInitiated: true) == nil)
        #expect(await resolver.blockedError == nil)
        #expect(await botCheck(resolver, "ccccccccccc") == nil)
        #expect(YouTubeStub.requests.map(\.videoId) == ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
    }

    @Test func networkChangeClearsTheBlock() async {
        let (resolver, _) = await resolver { _ in .json(Self.loginRequired) }
        #expect(await botCheck(resolver, "aaaaaaaaaaa", userInitiated: true) == .botCheck)
        #expect(await botCheck(resolver, "bbbbbbbbbbb") == .botCheck)
        #expect(YouTubeStub.requests.count == 1)
        await resolver.invalidateAll()
        #expect(await resolver.blockedError == nil)
        #expect(await botCheck(resolver, "bbbbbbbbbbb") == .botCheck)
        #expect(YouTubeStub.requests.count == 2, "после смены сети фон снова спрашивает YouTube")
    }

    @Test func theBlockIsRememberedForTenMinutes() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_790_000_000))
        let (resolver, _) = await resolver(now: { clock.now }) { _ in .json(Self.loginRequired) }
        #expect(await botCheck(resolver, "aaaaaaaaaaa", userInitiated: true) == .botCheck)
        clock.advance(9 * 60 + 59)
        #expect(await botCheck(resolver, "bbbbbbbbbbb") == .botCheck)
        #expect(YouTubeStub.requests.count == 1, "девять минут пятьдесят девять секунд — ещё без запросов")
        clock.advance(2)
        #expect(await resolver.blockedError == nil)
        #expect(await botCheck(resolver, "bbbbbbbbbbb") == .botCheck)
        #expect(YouTubeStub.requests.count == 2, "через десять минут фон пробует снова")
        // Новая проверка на бота снова закрывает адрес на десять минут
        #expect(await resolver.blockedError?.kind == .botCheck)
    }

    @Test func aCachedAddressNeedsNoRequestEvenWhenBlocked() async {
        let open = OpenSwitch()
        let (resolver, _) = await resolver { _ in open.value ? .json(Self.streamOK) : .json(Self.loginRequired) }
        open.value = true
        #expect(await botCheck(resolver, "aaaaaaaaaaa", userInitiated: true) == nil)
        open.value = false
        #expect(await botCheck(resolver, "bbbbbbbbbbb", userInitiated: true) == .botCheck)
        #expect(await resolver.blockedError != nil)
        #expect(await botCheck(resolver, "aaaaaaaaaaa") == nil, "адрес из кэша — без запроса")
        #expect(YouTubeStub.requests.count == 2)
    }
}
