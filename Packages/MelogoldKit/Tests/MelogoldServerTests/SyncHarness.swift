import Foundation
import GRDB
import MelogoldCore
import MelogoldData
@testable import MelogoldServer

/// Стенд синка: база в памяти, сервер-заглушка со своим хостом и вошедший аккаунт `maxim` (устройство `d1`).
@MainActor
final class SyncHarness {
    nonisolated static let binding = "\(AccountTests.serverId):u1"
    static let timing = SyncTiming(
        localChangeDelay: .milliseconds(50), retrySteps: [], liveFirstDelayMax: .milliseconds(10), liveSteps: [.milliseconds(20)]
    )

    let server = StubServer()
    let database: AppDatabase
    let store: SyncStore
    let account: Account
    let engine: LibrarySync

    /// `bound` — это устройство уже синхронизировалось с этим аккаунтом: курсор `c.1.1`, слияние позади.
    init(lyrics: Bool = true, bound: Bool = true) throws {
        database = try AppDatabase.inMemory()
        store = SyncStore(database: database)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "sync-\(UUID())")!)
        settings.serverURL = server.baseURL
        let secrets = MemorySecretStore()
        let session = StoredSession(
            serverURL: server.baseURL, serverId: AccountTests.serverId, userId: "u1", login: "maxim", deviceId: "d1",
            accessToken: "access", accessTokenExpiresAt: Date().addingTimeInterval(3600), refreshToken: "mgrt1.r.x"
        )
        secrets.set(try JSONEncoder().encode(session), for: Account.sessionAccount)
        account = Account(settings: settings, secrets: secrets, identity: AccountTests.identity, urlSession: StubServer.session())
        engine = LibrarySync(account: account, database: database, timing: Self.timing, liveEvents: false)
        server.on("GET", "/server/info") { _ in (200, SyncFixtures.serverInfo(lyrics: lyrics)) }
        server.on("POST", "/auth/me/lyrics/changes") { _ in (200, #"{"items":[],"rev":0,"more":false}"#) }
        if bound {
            try sql("INSERT INTO sync_state (key, value) VALUES ('binding', ?), ('cursor', 'c.1.1'), ('needsMerge', '0'), ('historyMerge', '0')",
                    [Self.binding])
        }
    }

    func sql(_ sql: String, _ arguments: StatementArguments = []) throws {
        try database.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    func strings(_ sql: String, _ arguments: StatementArguments = []) throws -> [String] {
        try database.writer.read { db in try String.fetchAll(db, sql: sql, arguments: arguments) }
    }

    func int(_ sql: String, _ arguments: StatementArguments = []) throws -> Int64? {
        try database.writer.read { db in try Int64.fetchOne(db, sql: sql, arguments: arguments) }
    }

    func state(_ key: String) throws -> String? {
        try strings("SELECT value FROM sync_state WHERE key = ?", [key]).first
    }

    /// Трек в библиотеке; `likedAt` — лайк этого устройства.
    func track(_ videoId: String, title: String? = nil, likedAt: Int64? = nil, totalMs: Int64 = 0) throws {
        try sql(
            """
            INSERT INTO tracks (video_id, title, artists_text, artists_json, duration_ms, video_type, liked_at, total_play_ms, created_at)
            VALUES (?, ?, 'Channel', '[{"id":"UC1","name":"Channel"}]', 254000, 'ugc', ?, ?, 0)
            """,
            [videoId, title ?? "Song \(videoId)", likedAt, totalMs]
        )
    }

    var syncRequests: [StubServer.Request] { server.requests("POST", "/sync") }

    func ops(_ index: Int) -> [[String: Any]] {
        let requests = syncRequests
        guard requests.indices.contains(index) else { return [] }
        return SyncFixtures.ops(requests[index])
    }
}

/// Ответы сервера синка. Вне `@MainActor`: их строят обработчики заглушки в потоках URLSession.
enum SyncFixtures {
    static func serverInfo(lyrics: Bool) -> String {
        let feature = lyrics ? #","lyrics":{"version":1}"# : ""
        return #"{"software":"melogold-server","version":"0.1.0","revision":"abc1234","apiVersion":1,"minApiVersion":1,"serverId":""#
            + AccountTests.serverId
            + #"","instanceName":"Melogold","publicUrl":null,"secureTransport":true,"registration":"open","features":{"sync":{"protocol":1,"minProtocol":1,"kinds":[],"streams":["library","history"]}"#
            + feature
            + #"},"limits":{"sync":{"maxOpsPerRequest":500},"history":{"retentionDays":400,"maxEvents":50000,"mergeUploadMax":20000}},"links":{"source":"x","privacy":null,"contact":null},"serverTime":"2026-09-25T10:00:00.000Z"}"#
    }

    static func ops(_ request: StubServer.Request) -> [[String: Any]] {
        request.json["ops"] as? [[String: Any]] ?? []
    }

    static func result(_ opId: String, _ status: String = "applied", code: String? = nil, playlistId: String? = nil, retryAfter: Int? = nil) -> String {
        func text(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return #"{"opId":"\#(opId)","status":"\#(status)","code":\#(text(code)),"seq":1,"playlistId":\#(text(playlistId)),"retryAfterSeconds":\#(retryAfter.map(String.init) ?? "null"),"replayed":false}"#
    }

    /// Ответ `/sync`: каждой op — `result(opId, kind)` (по умолчанию `applied`), строки — готовые JSON-массивы.
    static func response(
        _ request: StubServer.Request, cursor: String = "c.2.2", hasMore: Bool = false,
        result: (_ opId: String, _ kind: String) -> String = { opId, _ in SyncFixtures.result(opId) },
        rows: [String: String] = [:]
    ) -> String {
        let results = ops(request).map { result($0["opId"] as? String ?? "", $0["kind"] as? String ?? "") }.joined(separator: ",")
        let arrays = ["tracks", "playlists", "items", "likes", "bookmarks", "plays", "playStats", "playForgets"]
            .map { #""\#($0)":\#(rows[$0] ?? "[]")"# }.joined(separator: ",")
        return #"{"results":[\#(results)],"cursor":"\#(cursor)","hasMore":\#(hasMore),"serverTime":"2026-09-25T10:00:00.000Z",\#(arrays)}"#
    }

    /// Строки лайков на каждую `like.set` запроса — как ответ сервера на принятые ops.
    static func likeRows(_ request: StubServer.Request) -> [String] {
        ops(request).filter { $0["kind"] as? String == "like.set" }.map { op in
            let liked = op["liked"] as? Bool ?? false
            let at = liked ? "\"2026-09-25T09:00:00.000Z\"" : "null"
            return #"{"videoId":"\#(op["videoId"] as? String ?? "")","liked":\#(liked),"likedAt":\#(at)}"#
        }
    }

    static func echoLikes(_ request: StubServer.Request) -> String {
        "[" + likeRows(request).joined(separator: ",") + "]"
    }

    static func track(_ videoId: String, title: String) -> String {
        #"{"videoId":"\#(videoId)","title":"\#(title)","artistsText":"Artist","artists":[{"id":"UC1","name":"Artist"}],"albumId":null,"albumTitle":null,"durationMs":200000,"durationText":"3:20","thumbnailUrl":null,"explicit":false,"videoType":"song","metadataStub":false}"#
    }

    static func stub(_ videoId: String) -> String {
        #"{"videoId":"\#(videoId)","title":"\#(videoId)","artistsText":null,"artists":[],"albumId":null,"albumTitle":null,"durationMs":null,"durationText":null,"thumbnailUrl":null,"explicit":false,"videoType":null,"metadataStub":true}"#
    }

    static func playlist(_ id: String, name: String, createdAt: String = "2026-09-25T10:00:00.000Z", deleted: Bool = false) -> String {
        #"{"id":"\#(id)","name":"\#(name)","browseId":null,"thumbnailUrl":null,"createdAt":"\#(createdAt)","deleted":\#(deleted)}"#
    }

    static func item(_ playlistId: String, _ videoId: String, key: String, present: Bool = true) -> String {
        #"{"playlistId":"\#(playlistId)","videoId":"\#(videoId)","present":\#(present),"sortKey":"\#(key)","addedAt":"2026-09-25T10:00:00.000Z"}"#
    }

    static func myLyrics(_ videoId: String, rev: Int, deleted: Bool = false, synced: String? = nil) -> String {
        let text = synced.map { #"{"plain":null,"plainSource":null,"synced":"\#($0)","syncedFormat":"lrc","syncedSource":"user","startTimeMs":null,"language":null}"# } ?? "null"
        return #"{"id":"00000000-0000-4000-8000-00000000000\#(rev % 10)","videoId":"\#(videoId)","rev":\#(rev),"deleted":\#(deleted),"text":\#(text),"updatedAt":"2026-09-25T12:00:00.000Z"}"#
    }
}
