import Foundation
import MelogoldCore
import Testing
@testable import MelogoldInnerTube

/// Ответы «ничего нет» для всех провайдеров: LRCLIB — пустой список, остальные — пустой объект. Цепочка доходит до
/// текста с сервера Melogold (`community`) без единого обращения в сеть.
final class EmptyProvidersProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmptyProvidersProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.url?.host == "lrclib.net" ? "[]" : "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Общий текст сервера в цепочке поиска (задание 0001 §3.5, 0011 §2.3): своя версия — выбранная, общая — «сообщество».
@Suite("Цепочка поиска текста — сервер Melogold")
struct LyricsChainTests {
    static let lrc = "[00:01.00]Один\n[00:02.00]Два"

    let track = Track(videoId: "a1aaaaaaaaa", title: "Song", artists: [], artistsText: "Artist", durationMs: 200_000)

    private func fetcher(community: (@Sendable (String) async throws -> (payload: LyricsPayload, mine: Bool)?)?) -> LyricsFetcher {
        let session = EmptyProvidersProtocol.session()
        let fetcher = LyricsFetcher(
            music: YouTubeMusic(client: InnerTubeClient(session: session)), lrcLib: LrcLib(userAgent: "test", session: session), kuGou: KuGou(session: session)
        )
        fetcher.community = community
        return fetcher
    }

    private func payload(synced: String? = nil, plain: String? = nil, source: String? = "lrclib") -> LyricsPayload {
        LyricsPayload(
            plain: plain, plainSource: plain == nil ? nil : source, synced: synced, syncedFormat: synced == nil ? nil : "lrc",
            syncedSource: synced == nil ? nil : source, startTimeMs: synced == nil ? nil : 300, language: "ru"
        )
    }

    @Test func withoutCommunityNothingIsFound() async {
        let result = await fetcher(community: nil).fetch(track, durationMs: 200_000, current: nil)
        #expect(result.synced == nil && result.plain == nil)
        #expect(!result.anyFailure)
        #expect(result.found == FoundLyrics(synced: "", plain: ""))
    }

    /// Общий текст без синхронной стороны — только обычный — показывается, подписан «сообщество» и своим не становится.
    @Test func sharedPlainOnlyTextIsShown() async {
        let result = await fetcher(community: { _ in (self.payload(plain: "Общий обычный", source: "user"), false) })
            .fetch(track, durationMs: 200_000, current: nil)
        #expect(result.plain == "Общий обычный")
        #expect(result.plainSource == LyricsSources.melogold)
        #expect(result.synced == nil)
        #expect(!result.chosen)
        #expect(result.language == "ru")
        let stored = LyricsRules.mergeFetched(baseline: nil, current: nil, found: result.found)
        #expect(stored == StoredLyrics(synced: "", plain: "Общий обычный", syncedSource: nil, plainSource: "melogold", language: "ru"))
        #expect(stored?.isOwn == false)
    }

    /// Своя версия пользователя (`mine`), только обычная, тоже показывается — и остаётся своей, выбранной.
    @Test func ownPlainOnlyVersionIsShownAndChosen() async {
        let result = await fetcher(community: { _ in (self.payload(plain: "Мой обычный", source: "user"), true) })
            .fetch(track, durationMs: 200_000, current: nil)
        #expect(result.plain == "Мой обычный")
        #expect(result.plainSource == "user")
        #expect(result.chosen)
    }

    @Test func sharedSyncedTextIsCommunityAndOwnOneIsChosenWithItsSource() async {
        let shared = await fetcher(community: { _ in (self.payload(synced: Self.lrc, plain: "Обычный"), false) })
            .fetch(track, durationMs: 200_000, current: nil)
        #expect(shared.synced == Self.lrc)
        #expect(shared.syncedSource == LyricsSources.melogold)
        #expect(shared.plainSource == LyricsSources.melogold)
        #expect(shared.offsetMs == -300)
        #expect(!shared.chosen)

        let mine = await fetcher(community: { _ in (self.payload(synced: Self.lrc), true) })
            .fetch(track, durationMs: 200_000, current: nil)
        #expect(mine.syncedSource == "lrclib")
        #expect(mine.chosen)
        let stored = LyricsRules.mergeFetched(baseline: nil, current: nil, found: mine.found)
        #expect(stored?.isOwn == true)
    }

    /// Обычная сторона, найденная провайдерами, общим текстом не заменяется.
    @Test func communityPlainDoesNotReplaceWhatWasAlreadyThere() async {
        let current = StoredLyrics(synced: nil, plain: "Найденный раньше", syncedSource: nil, plainSource: LyricsSources.youtubeMusic)
        let result = await fetcher(community: { _ in (self.payload(plain: "Общий"), false) })
            .fetch(track, durationMs: 200_000, current: current)
        #expect(result.plain == "Найденный раньше")
        #expect(result.plainSource == "youtube_music")
    }

    @Test func serverFailureIsNotRememberedAsNoText() async {
        struct Down: Error {}
        let result = await fetcher(community: { _ in throw Down() }).fetch(track, durationMs: 200_000, current: nil)
        #expect(result.anyFailure)
        #expect(result.found == FoundLyrics(synced: nil, plain: nil))
    }
}
