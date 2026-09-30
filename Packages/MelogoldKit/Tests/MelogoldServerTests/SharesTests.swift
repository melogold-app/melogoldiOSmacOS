import Foundation
import MelogoldCore
import MelogoldData
import Testing
@testable import MelogoldServer

/// Ссылки на плейлисты (API §4.11, задание 0019): снимок своего плейлиста, запасной путь через YouTube, снимок по
/// ссылке без входа.
@MainActor
@Suite("Ссылки — снимки плейлистов")
struct SharesTests {
    let server = StubServer()

    private func account(signedIn: Bool = true) -> Account {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "shares-\(UUID())")!)
        settings.serverURL = server.baseURL
        let secrets = MemorySecretStore()
        if signedIn {
            let session = StoredSession(
                serverURL: server.baseURL, serverId: AccountTests.serverId, userId: "u1", login: "maxim", deviceId: "d1",
                accessToken: "access", accessTokenExpiresAt: Date().addingTimeInterval(3600), refreshToken: "mgrt1.r.x"
            )
            secrets.set(try! JSONEncoder().encode(session), for: Account.sessionAccount)
        }
        return Account(settings: settings, secrets: secrets, identity: AccountTests.identity, urlSession: StubServer.session())
    }

    nonisolated static func info(share: Bool) -> String {
        let feature = share ? #","share":{"version":1}"# : ""
        return #"{"software":"melogold-server","version":"0.1.2","revision":"abc1234","apiVersion":1,"minApiVersion":1,"serverId":""#
            + AccountTests.serverId + #"","instanceName":"Melogold","publicUrl":null,"secureTransport":true,"registration":"open","features":{"sync":{"protocol":1,"minProtocol":1,"kinds":[],"streams":["library","history"]}"#
            + feature + #"},"limits":null,"links":{"source":"x","privacy":null,"contact":null},"serverTime":"2026-09-30T10:00:00.000Z"}"#
    }

    private func tracks(_ count: Int, album: String? = nil) -> [Track] {
        (0 ..< count).map { Track(videoId: String(format: "abcdefgh%03d", $0), title: "Песня \($0)", artistsText: "Группа", albumTitle: album, durationMs: 200_000) }
    }

    /// Снимок уходит на сервер: название, треки по порядку со своими названиями поверх YouTube, ссылка — `…/s/<код>`.
    @Test func ownPlaylistIsSnapshottedWithTheNamesTheUserGave() async throws {
        server.on("GET", "/server/info") { _ in (200, Self.info(share: true)) }
        server.on("POST", "/shares") { _ in
            (201, #"{"shareId":"Ab3dE6gH9j","url":"https://x.test/s/Ab3dE6gH9j","createdAt":"2026-09-30T10:00:00.000Z"}"#)
        }
        let fan = Track(videoId: "abcdefgh000", title: "Кино — Звезда (live)", artistsText: "Fan", durationMs: 200_000)
        let shown = TrackOverride(title: "Звезда", artistsText: "Кино", albumTitle: "Концерт").apply(to: fan)

        let result = await account().sharePlaylist(name: "  Концерт  ", tracks: [shown, Track(videoId: "local-file", title: "Файл")] + tracks(2).dropFirst())

        guard case .onServer(let url, let id) = result else { Issue.record("\(result)"); return }
        #expect(url.absoluteString == "https://x.test/s/Ab3dE6gH9j" && id == "Ab3dE6gH9j")
        let body = try #require(server.requests("POST", "/shares").first).json
        #expect(body["kind"] as? String == "playlist" && body["name"] as? String == "Концерт")
        let sent = try #require(body["tracks"] as? [[String: Any]])
        #expect(sent.count == 2, "не-YouTube треки не уходят")
        #expect(sent[0]["videoId"] as? String == "abcdefgh000" && sent[0]["title"] as? String == "Звезда")
        #expect(sent[0]["artistsText"] as? String == "Кино" && sent[0]["albumTitle"] as? String == "Концерт")
    }

    /// Без входа, без функции на сервере или при сбое — список первых 50 видео на YouTube и подпись об этом.
    @Test func withoutTheServerItFallsBackToWatchVideos() async throws {
        let signedOut = await account(signedIn: false).sharePlaylist(name: "P", tracks: tracks(60))
        guard case .onYouTube(let url, let shown, let total) = signedOut else { Issue.record("\(signedOut)"); return }
        #expect(shown == 50 && total == 60)
        #expect(url.absoluteString.hasPrefix("https://www.youtube.com/watch_videos?video_ids=abcdefgh000,abcdefgh001"))

        server.on("GET", "/server/info") { _ in (200, Self.info(share: false)) }
        let oldServer = await account().sharePlaylist(name: "P", tracks: tracks(3))
        guard case .onYouTube(_, 3, 3) = oldServer else { Issue.record("\(oldServer)"); return }
        #expect(server.requests("POST", "/shares").isEmpty, "сервер не знает ссылок — снимок не просят")

        let other = StubServer()
        other.on("GET", "/server/info") { _ in (200, Self.info(share: true)) }
        other.on("POST", "/shares") { _ in (500, "") }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "shares-\(UUID())")!)
        settings.serverURL = other.baseURL
        let secrets = MemorySecretStore()
        let session = StoredSession(serverURL: other.baseURL, serverId: AccountTests.serverId, userId: "u1", login: "m", deviceId: "d1",
                                    accessToken: "a", accessTokenExpiresAt: Date().addingTimeInterval(3600), refreshToken: "mgrt1.r.x")
        secrets.set(try JSONEncoder().encode(session), for: Account.sessionAccount)
        let broken = Account(settings: settings, secrets: secrets, identity: AccountTests.identity, urlSession: StubServer.session())
        guard case .onYouTube = await broken.sharePlaylist(name: "P", tracks: tracks(2)) else { Issue.record("сбой сервера"); return }
    }

    @Test func limitAndEmptyPlaylists() async throws {
        server.on("GET", "/server/info") { _ in (200, Self.info(share: true)) }
        server.on("POST", "/shares") { _ in (409, Fixtures.error("share_limit_reached", 409)) }
        guard case .limitReached(200) = await account().sharePlaylist(name: "P", tracks: tracks(2)) else { Issue.record("лимит"); return }
        guard case .noTracks = await account().sharePlaylist(name: "P", tracks: []) else { Issue.record("пусто"); return }
        guard case .noTracks = await account().sharePlaylist(name: "P", tracks: [Track(videoId: "local", title: "x")]) else { Issue.record("не видео"); return }
    }

    /// Снимок по ссылке читается без входа и с сервера из ссылки; 404 — «Ссылка удалена или неверна».
    @Test func publicShareIsReadWithoutSigningIn() async throws {
        server.on("GET", "/shares/Ab3dE6gH9j") { request in
            #expect(request.headers["Authorization"] == nil)
            return (200, #"""
                {"shareId":"Ab3dE6gH9j","kind":"playlist","name":"Концерт","url":"https://x.test/s/Ab3dE6gH9j","createdAt":"2026-09-30T10:00:00.000Z",
                 "tracks":[{"videoId":"abcdefgh000","title":"Звезда","artistsText":"Кино","artists":[{"id":null,"name":"Кино"}],"albumTitle":"Концерт","durationMs":200000,"explicit":false,"metadataStub":false},
                           {"videoId":"abcdefgh001","title":"abcdefgh001","artists":[],"explicit":false,"metadataStub":true},
                           {"videoId":"abcdefgh000","title":"Звезда","artists":[],"explicit":false,"metadataStub":false}]}
                """#)
        }
        let share = try await account(signedIn: false).publicShare(server: server.baseURL, id: "Ab3dE6gH9j")
        #expect(share.name == "Концерт")
        let list = share.playlistTracks
        #expect(list.map(\.videoId) == ["abcdefgh000", "abcdefgh001"], "повторы убраны")
        #expect(list[0].albumTitle == "Концерт" && list[0].artistsText == "Кино" && list[0].durationMs == 200_000)
        #expect(list[1].title == "abcdefgh001", "заглушка называется своим id")

        do {
            _ = try await account(signedIn: false).publicShare(server: server.baseURL, id: "zzzzzzzzzz")
            Issue.record("404 должен быть ошибкой")
        } catch let error as APIError {
            #expect(error.code == "not_found" || error.status == 404)
        }
    }

    @Test func myLinksAreListedAndDeleted() async throws {
        server.on("GET", "/shares") { _ in
            (200, #"{"shares":[{"shareId":"Ab3dE6gH9j","kind":"playlist","name":"Концерт","url":"https://x.test/s/Ab3dE6gH9j","createdAt":"2026-09-30T10:00:00.000Z","tracks":[]}]}"#)
        }
        server.on("DELETE", "/shares/Ab3dE6gH9j") { _ in (204, "") }
        let account = account()
        let list = try await account.shares()
        #expect(list.shares.map(\.shareId) == ["Ab3dE6gH9j"])
        try await account.deleteShare("Ab3dE6gH9j")
        #expect(server.requests("DELETE", "/shares/Ab3dE6gH9j").count == 1)
    }
}
