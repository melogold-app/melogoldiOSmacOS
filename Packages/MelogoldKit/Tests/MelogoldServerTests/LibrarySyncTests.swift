import Foundation
import GRDB
import MelogoldCore
import MelogoldData
import Testing
@testable import MelogoldServer

/// Синк на сервере-заглушке (срез 5): ops из правок библиотеки, ответ сервера в порядке API §4.8, смена аккаунта,
/// 410, плейлист восстановления, история (задание 0002) и свои тексты (задание 0001).
@MainActor
@Suite("LibrarySync — синк библиотеки, истории и текстов")
struct LibrarySyncTests {
    // MARK: - Избранное и закладки

    @Test func likeGoesUpWithTrackMetadataAndBase() async throws {
        let h = try SyncHarness()
        try h.track("a1B2c3D4e5F", title: "Song", likedAt: 1_790_000_000_000)
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, rows: ["likes": #"[{"videoId":"a1B2c3D4e5F","liked":true,"likedAt":"2026-09-21T14:13:20.000Z"}]"#]))
        }

        await h.engine.sync()

        let request = try #require(h.syncRequests.first)
        #expect(request.headers["X-Sync-Protocol"] == "1")
        #expect(request.json["cursor"] as? String == "c.1.1")
        #expect(request.json["streams"] as? [String] == ["library", "history"])
        let op = try #require(h.ops(0).first)
        #expect(op["kind"] as? String == "like.set")
        #expect(op["base"] as? String == "c.1.1")
        #expect(op["liked"] as? Bool == true)
        #expect(op["likedAt"] as? String == "2026-09-21T14:13:20.000Z")
        #expect(op["at"] as? String == "2026-09-21T14:13:20.000Z")
        let track = try #require((op["tracks"] as? [[String: Any]])?.first)
        #expect(track["title"] as? String == "Song")
        #expect(track["durationMs"] as? Int == 254_000)
        #expect(track["videoType"] as? String == "ugc")
        #expect((track["artists"] as? [[String: Any]])?.first?["name"] as? String == "Channel")
        #expect(try h.strings("SELECT video_id FROM synced_likes") == ["a1B2c3D4e5F"])
        #expect(try h.state("cursor") == "c.2.2")
        guard case .idle(let last) = h.engine.status else {
            Issue.record("status \(h.engine.status)")
            return
        }
        #expect(last != nil)
    }

    @Test func unlikeSendsLikedFalse() async throws {
        let h = try SyncHarness()
        try h.track("a1B2c3D4e5F")
        try h.sql("INSERT INTO synced_likes (video_id) VALUES ('a1B2c3D4e5F')")
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, rows: ["likes": #"[{"videoId":"a1B2c3D4e5F","liked":false,"likedAt":null}]"#]))
        }

        await h.engine.sync()

        let op = try #require(h.ops(0).first)
        #expect(op["kind"] as? String == "like.set")
        #expect(op["liked"] as? Bool == false)
        #expect(op["likedAt"] == nil && op["tracks"] == nil)
        #expect(try h.strings("SELECT video_id FROM synced_likes").isEmpty)
    }

    @Test func bookmarksGoUp() async throws {
        let h = try SyncHarness()
        try h.sql("INSERT INTO albums (browse_id, title, artists_text, year, thumbnail_url, bookmarked_at) VALUES ('MPREb_1', 'Album', 'Artist', '2024', 'https://i.ytimg.com/a.jpg', 1790000000000)")
        try h.sql("INSERT INTO synced_bookmarks (type, browse_id) VALUES ('artist', 'UCgone')")
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }

        await h.engine.sync()

        let ops = h.ops(0)
        #expect(ops.count == 2)
        #expect(ops.first?["type"] as? String == "album")
        #expect(ops.first?["bookmarked"] as? Bool == true)
        #expect(ops.first?["title"] as? String == "Album")
        #expect(ops.first?["subtitle"] as? String == "Artist")
        #expect(ops.first?["year"] as? String == "2024")
        #expect(ops.last?["type"] as? String == "artist")
        #expect(ops.last?["browseId"] as? String == "UCgone")
        #expect(ops.last?["bookmarked"] as? Bool == false)
    }

    // MARK: - Плейлисты

    @Test func playlistCreateRenameReorderDelete() async throws {
        let h = try SyncHarness()
        for id in ["t1", "t2", "t3"] { try h.track(id) }
        try h.sql("INSERT INTO playlists (name, created_at) VALUES ('Дорога', 1)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, 't1', 0, 1), (1, 't2', 1, 1), (1, 't3', 2, 1)")

        // Новый плейлист: create со всеми треками и метаданными, sync_id — сразу
        h.server.on("POST", "/sync") { request in
            let id = SyncFixtures.ops(request).first?["playlistId"] as? String ?? ""
            return (200, SyncFixtures.response(request, rows: [
                "playlists": "[\(SyncFixtures.playlist(id, name: "Дорога"))]",
                "items": "[\(SyncFixtures.item(id, "t3", key: "a2")),\(SyncFixtures.item(id, "t1", key: "a0")),\(SyncFixtures.item(id, "t2", key: "a1"))]",
            ]))
        }
        await h.engine.sync()
        let create = try #require(h.ops(0).first)
        #expect(create["kind"] as? String == "playlist.create")
        #expect(create["videoIds"] as? [String] == ["t1", "t2", "t3"])
        #expect((create["tracks"] as? [[String: Any]])?.count == 3)
        let syncId = try #require(create["playlistId"] as? String)
        #expect(try h.strings("SELECT sync_id FROM playlists") == [syncId])
        #expect(try h.strings("SELECT video_ids FROM synced_playlists") == ["t1\nt2\nt3"])

        // Переименование и перенос одного трека: update и одна move
        try h.sql("UPDATE playlists SET name = 'Дорога домой'")
        try h.sql("UPDATE playlist_items SET position = CASE video_id WHEN 't2' THEN 0 WHEN 't3' THEN 1 ELSE 2 END")
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, cursor: "c.3.3", rows: [
                "playlists": "[\(SyncFixtures.playlist(syncId, name: "Дорога домой"))]",
                "items": "[\(SyncFixtures.item(syncId, "t1", key: "a3"))]",
            ]))
        }
        await h.engine.sync()
        let edits = h.ops(1)
        #expect(edits.map { $0["kind"] as? String } == ["playlist.update", "playlist.item.move"])
        #expect(edits.first?["name"] as? String == "Дорога домой")
        #expect(edits.first?["base"] as? String == "c.2.2")
        #expect(edits.last?["videoId"] as? String == "t1")
        #expect(edits.last?["after"] as? String == "t3")
        #expect(try h.strings("SELECT video_ids FROM synced_playlists") == ["t2\nt3\nt1"])
        #expect(try h.strings("SELECT video_id FROM playlist_items ORDER BY position") == ["t2", "t3", "t1"])

        // Удаление
        try h.sql("DELETE FROM playlists")
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, cursor: "c.4.4", rows: ["playlists": "[\(SyncFixtures.playlist(syncId, name: "Дорога домой", deleted: true))]"]))
        }
        await h.engine.sync()
        #expect(h.ops(2).map { $0["kind"] as? String } == ["playlist.delete"])
        #expect(h.ops(2).first?["playlistId"] as? String == syncId)
        #expect(try h.strings("SELECT sync_id FROM synced_playlists").isEmpty)
    }

    @Test func serverRowsApplyInApiOrder() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, rows: [
                "tracks": "[\(SyncFixtures.track("t1", title: "First")),\(SyncFixtures.stub("t2"))]",
                // Новее — первым в массиве: вставляются по createdAt
                "playlists": "[\(SyncFixtures.playlist("P2", name: "Второй", createdAt: "2026-09-25T11:00:00.000Z")),\(SyncFixtures.playlist("P1", name: "Первый", createdAt: "2026-09-25T10:00:00.000Z"))]",
                "items": "[\(SyncFixtures.item("P1", "t2", key: "a1")),\(SyncFixtures.item("P1", "t1", key: "a0")),\(SyncFixtures.item("P2", "t1", key: "Zz")),\(SyncFixtures.item("P2", "t3", key: "Zz"))]",
                "likes": #"[{"videoId":"t1","liked":true,"likedAt":"2026-09-25T09:00:00.000Z"}]"#,
                "bookmarks": #"[{"type":"album","browseId":"MPREb_1","bookmarked":true,"bookmarkedAt":"2026-09-25T09:00:00.000Z","title":"Album","subtitle":"Artist","thumbnailUrl":null,"year":"2024"},{"type":"song","browseId":"x","bookmarked":true,"bookmarkedAt":null,"title":null,"subtitle":null,"thumbnailUrl":null,"year":null}]"#,
                "playStats": #"[{"videoId":"t1","totalPlayTimeMs":1484000,"lastPlayedAt":"2026-09-23T09:58:10.000Z"}]"#,
                "plays": #"[{"eventId":"e1","videoId":"t1","playedAt":"2026-09-23T09:58:10.000Z","playTimeMs":212000,"deviceId":"phone"},{"eventId":"e2","videoId":"t2","playedAt":"2026-09-23T08:00:00.000Z","playTimeMs":1000,"deviceId":"phone"}]"#,
                "playForgets": #"[{"videoId":"t2","eventsBefore":"2026-09-23T09:00:00.000Z","totalBefore":null}]"#,
            ]))
        }

        await h.engine.sync()

        #expect(try h.strings("SELECT sync_id FROM playlists ORDER BY id") == ["P1", "P2"])
        #expect(try h.strings("SELECT video_id FROM playlist_items WHERE playlist_id = 1 ORDER BY position") == ["t1", "t2"])
        // Равные ключи — по videoId
        #expect(try h.strings("SELECT video_id FROM playlist_items WHERE playlist_id = 2 ORDER BY position") == ["t1", "t3"])
        #expect(try h.strings("SELECT video_ids FROM synced_playlists ORDER BY sync_id") == ["t1\nt2", "t1\nt3"])
        #expect(try h.strings("SELECT title FROM tracks ORDER BY video_id") == ["First", "t2", "t3"])
        #expect(try h.int("SELECT metadata_stub FROM tracks WHERE video_id = 't2'") == 1)
        #expect(try h.int("SELECT liked_at FROM tracks WHERE video_id = 't1'") == 1_790_326_800_000)
        #expect(try h.strings("SELECT video_id FROM synced_likes") == ["t1"])
        #expect(try h.strings("SELECT browse_id FROM albums WHERE bookmarked_at IS NOT NULL") == ["MPREb_1"])
        #expect(try h.strings("SELECT type || ':' || browse_id FROM synced_bookmarks") == ["album:MPREb_1"])
        #expect(try h.int("SELECT total_play_ms FROM tracks WHERE video_id = 't1'") == 1_484_000)
        // Забытое событие t2 удалено, событие телефона — отправленное и чужое
        #expect(try h.strings("SELECT event_id || ':' || device_id || ':' || synced FROM play_events") == ["e1:phone:1"])
    }

    @Test func redirectedPlaylistMovesToTheRecoveryCopy() async throws {
        let h = try SyncHarness()
        for id in ["t1", "t2"] { try h.track(id) }
        try h.sql("INSERT INTO playlists (sync_id, name, created_at) VALUES ('P1', 'Дорога', 1)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (1, 't1', 0, 'a0', 1), (1, 't2', 1, NULL, 1)")
        try h.sql("INSERT INTO synced_playlists (sync_id, name, video_ids) VALUES ('P1', 'Дорога', 't1')")
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(
                request,
                result: { opId, kind in kind == "playlist.items.add" ? SyncFixtures.result(opId, "redirected", playlistId: "P2") : SyncFixtures.result(opId) },
                rows: [
                    "playlists": "[\(SyncFixtures.playlist("P1", name: "Дорога", createdAt: "2026-09-24T10:00:00.000Z", deleted: true)),\(SyncFixtures.playlist("P2", name: "Дорога (восстановлено)"))]",
                    "items": "[\(SyncFixtures.item("P2", "t2", key: "a0"))]",
                ]
            ))
        }

        await h.engine.sync()

        let add = try #require(h.ops(0).first)
        #expect(add["kind"] as? String == "playlist.items.add")
        #expect(add["videoIds"] as? [String] == ["t2"])
        #expect(add["after"] as? String == "t1")
        #expect(try h.strings("SELECT sync_id || ':' || name FROM playlists") == ["P2:Дорога (восстановлено)"])
        #expect(try h.strings("SELECT sync_id FROM synced_playlists") == ["P2"])

        // Трек, которого нет в копии, уходит туда следующей синхронизацией
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request, cursor: "c.3.3")) }
        await h.engine.sync()
        let next = try #require(h.ops(1).first)
        #expect(next["kind"] as? String == "playlist.items.add")
        #expect(next["playlistId"] as? String == "P2")
        #expect(next["videoIds"] as? [String] == ["t1"])
    }

    // MARK: - Аккаунт и курсор

    @Test func anotherAccountResetsTheSnapshotAndMerges() async throws {
        let h = try SyncHarness(bound: false)
        try h.sql("INSERT INTO sync_state (key, value) VALUES ('binding', 'other:x'), ('cursor', 'old.1.1'), ('needsMerge', '0')")
        try h.track("t1", likedAt: 1_790_000_000_000)
        try h.sql("INSERT INTO synced_likes (video_id) VALUES ('t1')")
        try h.sql("INSERT INTO playlists (sync_id, name, created_at) VALUES ('old-p', 'Дорога', 1)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (1, 't1', 0, 'a0', 1)")
        try h.sql("INSERT INTO synced_playlists (sync_id, name, video_ids) VALUES ('old-p', 'Дорога', 't1')")
        try h.sql("INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES ('e-own', 't1', 1790000000000, 60000, 1, NULL), ('e-foreign', 't1', 1790000001000, 60000, 1, 'phone')")
        h.server.on("POST", "/sync/merge-plan") { _ in (200, #"{"plan":[{"localKey":"1","action":"create","playlistId":"new-p","serverName":null}]}"#) }
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }

        await h.engine.sync()

        let merge = try #require(h.server.requests("POST", "/sync/merge-plan").first)
        let input = try #require((merge.json["playlists"] as? [[String: Any]])?.first)
        #expect(input["localKey"] as? String == "1")
        #expect(input["name"] as? String == "Дорога")
        let request = try #require(h.syncRequests.first)
        #expect(request.json["cursor"] as? String == "")
        let ops = h.ops(0)
        #expect(ops.map { $0["kind"] as? String } == ["like.set", "playlist.import", "play.add"])
        #expect(ops.allSatisfy { $0["base"] == nil })
        #expect(ops[1]["playlistId"] as? String == "new-p")
        #expect(ops[2]["opId"] as? String == "e-own")
        #expect(try h.strings("SELECT event_id FROM play_events") == ["e-own"])
        #expect(try h.state("binding") == SyncHarness.binding)
        #expect(try h.state("needsMerge") == "0")
    }

    @Test func expiredCursorRestartsFromTheBeginningOnce() async throws {
        let h = try SyncHarness()
        try h.sql("UPDATE sync_state SET value = 'stale.1.1' WHERE key = 'cursor'")
        try h.track("t1", likedAt: 1_790_000_000_000)
        h.server.on("POST", "/sync") { request in
            request.json["cursor"] as? String == "stale.1.1"
                ? (410, Fixtures.error("cursor_expired", 410))
                : (200, SyncFixtures.response(request, cursor: "e.5.5", rows: ["likes": SyncFixtures.echoLikes(request)]))
        }

        await h.engine.sync()

        let requests = h.syncRequests
        #expect(requests.map { $0.json["cursor"] as? String } == ["stale.1.1", ""])
        #expect(h.ops(0).first?["opId"] as? String == h.ops(1).first?["opId"] as? String)
        #expect(try h.state("cursor") == "e.5.5")
        #expect(try h.strings("SELECT video_id FROM synced_likes") == ["t1"])
    }

    /// Сервер восстановлен из копии (`410 cursor_invalid`, DESIGN §3.15 п. 6): то, что было в снимке, уходит заново —
    /// сервер мог это потерять. Прослушивания — только в историю, время — `play.baseline atLeast`.
    @Test func restoredServerGetsEverythingAgain() async throws {
        let h = try SyncHarness()
        try h.track("t1", likedAt: 1_790_000_000_000, totalMs: 500_000)
        try h.sql("INSERT INTO synced_likes (video_id) VALUES ('t1')")
        try h.sql("INSERT INTO playlists (sync_id, name, created_at) VALUES ('P1', 'Дорога', 1)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (1, 't1', 0, 'a0', 1)")
        try h.sql("INSERT INTO synced_playlists (sync_id, name, video_ids) VALUES ('P1', 'Дорога', 't1')")
        try h.sql("INSERT INTO albums (browse_id, title, artists_text, year, thumbnail_url, bookmarked_at) VALUES ('MPREb_1', 'Album', 'Artist', '2024', NULL, 1790000000000)")
        try h.sql("INSERT INTO synced_bookmarks (type, browse_id) VALUES ('album', 'MPREb_1')")
        try h.sql("INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES ('e-own', 't1', 1790000000000, 60000, 1, NULL), ('e-phone', 't1', 1790000001000, 60000, 1, 'phone')")
        try h.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES ('t1', '[00:01.00]Hi', NULL, 'user', NULL, 0, NULL, 0)")
        let own = StoredLyrics(synced: "[00:01.00]Hi", plain: nil, syncedSource: "user", plainSource: nil)
        try await h.store.write { tx in
            try tx.setSyncedLyrics("t1", rev: 5, hash: LyricsSyncRules.hash(LyricsSyncRules.payload(own)))
            try tx.setState("lyricsRev", "5")
        }
        h.server.on("POST", "/sync/merge-plan") { _ in (200, #"{"plan":[{"localKey":"1","action":"merge","playlistId":"P1","serverName":"Дорога"}]}"#) }
        h.server.on("POST", "/sync") { request in
            if request.json["cursor"] as? String == "c.1.1" { return (410, Fixtures.error("cursor_invalid", 410)) }
            let plays = SyncFixtures.ops(request).contains { $0["kind"] as? String == "play.add" }
            return (200, SyncFixtures.response(request, cursor: "r.2.2", rows: [
                "likes": SyncFixtures.echoLikes(request),
                "items": plays ? "[\(SyncFixtures.item("P1", "t1", key: "b0"))]" : "[]",
                "bookmarks": plays ? #"[{"type":"album","browseId":"MPREb_1","bookmarked":true,"bookmarkedAt":"2026-09-21T14:13:20.000Z","title":"Album","subtitle":"Artist","thumbnailUrl":null,"year":"2024"}]"# : "[]",
                // На восстановленном сервере времени меньше: здешнее не уменьшается, пока не ушёл baseline
                "playStats": plays ? #"[{"videoId":"t1","totalPlayTimeMs":100000,"lastPlayedAt":null}]"# : "[]",
            ]))
        }
        h.server.on("PUT", "/lyrics/t1") { _ in (200, SyncFixtures.myLyrics("t1", rev: 1, synced: "[00:01.00]Hi")) }

        await h.engine.sync()

        #expect(h.syncRequests.map { $0.json["cursor"] as? String } == ["c.1.1", "", "r.2.2"])
        let merge = try #require(h.server.requests("POST", "/sync/merge-plan").first)
        #expect((merge.json["playlists"] as? [[String: Any]])?.first?["syncId"] as? String == "P1")
        let ops = h.ops(1)
        #expect(ops.map { $0["kind"] as? String } == ["like.set", "playlist.import", "bookmark.set", "play.add"])
        #expect(ops.allSatisfy { $0["base"] == nil })
        #expect(ops[0]["liked"] as? Bool == true)
        #expect(ops[1]["playlistId"] as? String == "P1" && ops[1]["videoIds"] as? [String] == ["t1"])
        #expect(ops[3]["opId"] as? String == "e-own")
        #expect(ops[3]["history"] as? Bool == true && ops[3]["playtime"] as? Bool == false)
        #expect(h.ops(2).map { $0["kind"] as? String } == ["play.baseline"])
        let baseline = try #require(h.ops(2).first)
        #expect(baseline["mode"] as? String == "atLeast")
        #expect((baseline["entries"] as? [[String: Any]])?.first?["totalMs"] as? Int == 500_000)
        #expect(try h.int("SELECT total_play_ms FROM tracks WHERE video_id = 't1'") == 500_000)
        #expect(try h.strings("SELECT event_id FROM play_events ORDER BY event_id") == ["e-own", "e-phone"])
        #expect(try h.strings("SELECT video_ids FROM synced_playlists") == ["t1"])
        #expect(try h.strings("SELECT video_id FROM synced_likes") == ["t1"])
        #expect(try h.state("cursor") == "r.2.2")
        #expect(try h.state("needsMerge") == "0")
        #expect(try h.state("historyMerge") == "0")
        #expect(try h.state("historyReplay") == nil)
        // Свой текст — ещё раз (то же содержимое rev не меняет), тексты с сервера — с начала
        #expect(h.server.requests("PUT", "/lyrics/t1").count == 1)
        #expect(h.server.requests("POST", "/auth/me/lyrics/changes").first?.json["after"] as? Int == 0)
    }

    @Test func invalidCursorAfterTheMergeIsAnError() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { _ in (410, Fixtures.error("cursor_invalid", 410)) }

        await h.engine.sync()

        #expect(h.syncRequests.map { $0.json["cursor"] as? String } == ["c.1.1", ""])
        #expect(h.engine.status == .failed(offline: false, lastSyncAt: nil))
    }

    /// План слияния: плейлист удалён на другом устройстве — удаляется и здесь, а не возвращается копией (API §4.7 п. 2).
    @Test func mergePlanDeletedRemovesThePlaylistHere() async throws {
        let h = try SyncHarness()
        try h.sql("UPDATE sync_state SET value = '1' WHERE key = 'needsMerge'")
        try h.track("t1")
        try h.sql("INSERT INTO playlists (sync_id, name, created_at) VALUES ('dead', 'Старый', 1), (NULL, 'Новый', 2)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, 't1', 0, 1)")
        h.server.on("POST", "/sync/merge-plan") { _ in
            (200, #"{"plan":[{"localKey":"1","action":"deleted","playlistId":"dead","serverName":null},{"localKey":"2","action":"create","playlistId":"new-p","serverName":null}]}"#)
        }
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }

        await h.engine.sync()

        let merge = try #require(h.server.requests("POST", "/sync/merge-plan").first)
        #expect((merge.json["playlists"] as? [[String: Any]])?.first?["syncId"] as? String == "dead")
        #expect(try h.strings("SELECT name FROM playlists") == ["Новый"])
        #expect(try h.int("SELECT COUNT(*) FROM playlist_items") == 0)
        #expect(h.ops(0).map { $0["kind"] as? String } == ["playlist.import"])
        #expect(h.ops(0).first?["playlistId"] as? String == "new-p")
    }

    @Test func offlineAndIncompatibleStatus() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { _ in (StubServer.offline, "") }
        await h.engine.sync()
        #expect(h.engine.status == .failed(offline: true, lastSyncAt: nil))

        h.server.on("POST", "/sync") { _ in (409, Fixtures.error("protocol_unsupported", 409)) }
        await h.engine.sync()
        #expect(h.engine.status == .incompatible)
    }

    // MARK: - Пакет, который сервер не принимает

    /// Одна op, которую сервер не принимает и одну (413), не останавливает синк: остальные ops, pull и тексты идут.
    @Test func opTooLargeEvenAloneDoesNotStopTheSync() async throws {
        let h = try SyncHarness()
        for id in ["t1", "t2", "t3"] { try h.track(id, likedAt: 1_790_000_000_000) }
        // t1 не проходит никак, t2 — только без метаданных треков
        h.server.on("POST", "/sync") { request in
            let ops = SyncFixtures.ops(request)
            if ops.contains(where: { $0["videoId"] as? String == "t1" || ($0["videoId"] as? String == "t2" && $0["tracks"] != nil) }) {
                return (413, Fixtures.error("payload_too_large", 413))
            }
            return (200, SyncFixtures.response(request, cursor: "c.3.3", rows: ["likes": SyncFixtures.echoLikes(request)]))
        }

        await h.engine.sync()

        let sent = h.syncRequests.indices.map { h.ops($0).map { ($0["videoId"] as? String ?? "") + ($0["tracks"] == nil ? "-" : "") } }
        #expect(sent == [["t1", "t2", "t3"], ["t1"], ["t1-"], ["t2", "t3"], ["t2"], ["t2-"], ["t3"]])
        #expect(try h.strings("SELECT video_id FROM synced_likes ORDER BY video_id") == ["t2", "t3"])
        #expect(try h.state("cursor") == "c.3.3")
        #expect(!h.server.requests("POST", "/auth/me/lyrics/changes").isEmpty)
        guard case .idle = h.engine.status else {
            Issue.record("status \(h.engine.status)")
            return
        }

        // Дальше она не отправляется, пока лайк здесь не изменится; pull идёт
        let before = h.syncRequests.count
        await h.engine.sync()
        #expect(h.syncRequests.count == before + 1)
        #expect(h.ops(before).isEmpty)
        try h.sql("UPDATE tracks SET liked_at = 1790000005000 WHERE video_id = 't1'")
        await h.engine.sync()
        #expect(h.ops(before + 1).map { $0["videoId"] as? String } == ["t1"])
    }

    /// `400 invalid_request` — бисекция пакета, пока виновник не останется один (DESIGN §3.9); остальные уходят.
    @Test func invalidRequestIsBisected() async throws {
        let h = try SyncHarness()
        for id in ["t1", "t2", "t3", "t4"] { try h.track(id, likedAt: 1_790_000_000_000) }
        h.server.on("POST", "/sync") { request in
            SyncFixtures.ops(request).contains { $0["videoId"] as? String == "t3" }
                ? (400, Fixtures.error("invalid_request", 400))
                : (200, SyncFixtures.response(request, rows: ["likes": SyncFixtures.echoLikes(request)]))
        }

        await h.engine.sync()

        let sent = h.syncRequests.indices.map { h.ops($0).compactMap { $0["videoId"] as? String } }
        #expect(sent == [["t1", "t2", "t3", "t4"], ["t1", "t2"], ["t3", "t4"], ["t3"], ["t4"]])
        #expect(try h.strings("SELECT video_id FROM synced_likes ORDER BY video_id") == ["t1", "t2", "t4"])
    }

    @Test func opOverTheWorkBudgetGoesWithoutTrackMetadata() {
        var op = SyncOp(opId: "x", kind: "playlist.create", at: "", base: nil)
        op.videoIds = (0 ..< 12_000).map { "v\($0)" }
        op.tracks = op.videoIds?.map { TrackInput(videoId: $0) }
        let fitted = LibrarySync.fitted(PendingOp(key: "pl:x", op: op))
        #expect(fitted.op.tracks == nil)
        #expect(fitted.work == 12_000)

        op.videoIds = ["v1"]
        op.tracks = [TrackInput(videoId: "v1")]
        #expect(LibrarySync.fitted(PendingOp(key: "pl:x", op: op)).op.tracks?.count == 1)
    }

    // MARK: - Правки во время запроса

    /// Ответ не затирает то, что человек изменил, пока шёл запрос: снимок — от сервера, правка уходит следующим проходом.
    @Test func editsMadeDuringTheRequestSurviveTheResponse() async throws {
        let h = try SyncHarness()
        for id in ["t1", "t2", "t3", "t4", "t5"] { try h.track(id) }
        try h.sql("UPDATE tracks SET liked_at = 1790000000000 WHERE video_id = 't1'")
        // P1 на сервере — t1, t2, t3, здесь добавлен t4; P2 здесь переименован
        try h.sql("INSERT INTO playlists (sync_id, name, created_at) VALUES ('P1', 'Дорога', 1), ('P2', 'Вечер', 2)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (1, 't1', 0, 'a0', 1), (1, 't2', 1, 'a1', 1), (1, 't3', 2, 'a2', 1), (1, 't4', 3, NULL, 1), (2, 't1', 0, 'a0', 1)")
        try h.sql("INSERT INTO synced_playlists (sync_id, name, video_ids) VALUES ('P1', 'Дорога', 't1\nt2\nt3'), ('P2', 'Вечер', 't1')")
        try h.sql("UPDATE playlists SET name = 'Вечер!' WHERE sync_id = 'P2'")
        let database = h.database
        h.server.on("POST", "/sync") { request in
            guard request.json["cursor"] as? String == "c.1.1" else { return (200, SyncFixtures.response(request, cursor: "c.3.3")) }
            // Пока запрос идёт, здесь снимают лайк, удаляют P2 и переносят t1 в конец P1
            try? database.writer.write { db in
                try db.execute(sql: "UPDATE tracks SET liked_at = NULL WHERE video_id = 't1'")
                try db.execute(sql: "DELETE FROM playlists WHERE sync_id = 'P2'")
                try db.execute(sql: "UPDATE playlist_items SET position = 9 WHERE playlist_id = 1 AND video_id = 't1'")
            }
            return (200, SyncFixtures.response(request, rows: [
                "playlists": "[\(SyncFixtures.playlist("P1", name: "Дорога")),\(SyncFixtures.playlist("P2", name: "Вечер!"))]",
                // t4 принят; t5 добавило другое устройство между t2 и t3
                "items": "[\(SyncFixtures.item("P1", "t4", key: "a3")),\(SyncFixtures.item("P1", "t5", key: "a1V"))]",
                "likes": SyncFixtures.echoLikes(request),
            ]))
        }

        await h.engine.sync()

        #expect(h.ops(0).map { $0["kind"] as? String } == ["like.set", "playlist.items.add", "playlist.update"])
        // Лайк снят здесь и остаётся снятым; в снимке — лайк сервера
        #expect(try h.int("SELECT liked_at FROM tracks WHERE video_id = 't1'") == nil)
        #expect(try h.strings("SELECT video_id FROM synced_likes") == ["t1"])
        // P2 удалён здесь и не вернулся
        #expect(try h.strings("SELECT sync_id FROM playlists") == ["P1"])
        #expect(try h.strings("SELECT sync_id FROM synced_playlists ORDER BY sync_id") == ["P1", "P2"])
        // В P1 перенос остался, t5 встал за t2; снимок — порядок сервера
        #expect(try h.strings("SELECT video_id FROM playlist_items WHERE playlist_id = 1 ORDER BY position") == ["t2", "t5", "t3", "t4", "t1"])
        #expect(try h.strings("SELECT video_id || ':' || sort_key FROM playlist_items WHERE playlist_id = 1 AND video_id IN ('t4', 't5') ORDER BY video_id") == ["t4:a3", "t5:a1V"])
        #expect(try h.strings("SELECT video_ids FROM synced_playlists WHERE sync_id = 'P1'") == ["t1\nt2\nt5\nt3\nt4"])

        await h.engine.sync()

        let next = h.ops(1)
        #expect(next.map { $0["kind"] as? String } == ["like.set", "playlist.item.move", "playlist.delete"])
        #expect(next[0]["liked"] as? Bool == false)
        #expect(next[1]["videoId"] as? String == "t1" && next[1]["after"] as? String == "t4")
        #expect(next[2]["playlistId"] as? String == "P2")
    }

    @Test func heldPlaylistKeepsLocalOrderAndTakesServerChanges() throws {
        func row(_ videoId: String, _ key: String, present: Bool = true) -> PlaylistItemRow {
            PlaylistItemRow(playlistId: "P1", videoId: videoId, present: present, sortKey: key, addedAt: "2026-09-25T10:00:00.000Z")
        }
        // Здесь во время запроса t3 перенесли в начало и добавили t9; t4 убрали ещё до запроса
        let held = SyncApply.heldItems(
            local: [SyncItemRecord(videoId: "t3", sortKey: "a2"), SyncItemRecord(videoId: "t1", sortKey: "a0"),
                    SyncItemRecord(videoId: "t9", sortKey: nil), SyncItemRecord(videoId: "t2", sortKey: "a1")],
            expected: ["t1", "t2", "t3"],
            // Сервер убрал t2, t4 ещё жив, другое устройство добавило t6 за t1
            rows: [row("t2", "a1", present: false), row("t4", "a3"), row("t6", "a0V")],
            previous: ["t1", "t2", "t3", "t4"]
        )
        #expect(held.items == [SyncItemRecord(videoId: "t3", sortKey: "a2"), SyncItemRecord(videoId: "t1", sortKey: "a0"),
                               SyncItemRecord(videoId: "t6", sortKey: "a0V"), SyncItemRecord(videoId: "t9", sortKey: nil)])
        #expect(held.inserted == ["t6"])
        #expect(held.removed == ["t2"])
        #expect(held.snapshot == ["t1", "t6", "t3", "t4"])
    }

    // MARK: - История (задание 0002)

    @Test func deferredPlaysWaitForRetryAt() async throws {
        let h = try SyncHarness()
        try h.track("t1")
        try await h.store.recordPlay(SyncTrackRecord(videoId: "t1", title: "Song t1"), playTimeMs: 60_000, playedAt: 1_790_000_000_000)
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, result: { opId, _ in SyncFixtures.result(opId, "deferred", code: "op_rate_limited", retryAfter: 120) }))
        }

        await h.engine.sync()

        let play = try #require(h.ops(0).first)
        #expect(play["kind"] as? String == "play.add")
        #expect(play["playedAt"] as? String == "2026-09-21T14:13:20.000Z")
        #expect(play["playTimeMs"] as? Int == 60_000)
        #expect(play["history"] as? Bool == true && play["playtime"] as? Bool == true)
        #expect((play["tracks"] as? [[String: Any]])?.first?["videoId"] as? String == "t1")
        #expect(try h.int("SELECT synced FROM play_events") == 0)
        let retryAt = try #require(try h.state("historyRetryAt").flatMap { Int64($0) })
        #expect(abs(retryAt - (EpochMs.now() + 120_000)) < 10_000)

        // До retryAt прослушивания не отправляются
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }
        await h.engine.sync()
        #expect(h.ops(1).isEmpty)
        h.engine.stop()
    }

    @Test func baselineGoesOnlyAfterAllPlays() async throws {
        let h = try SyncHarness()
        try h.sql("UPDATE sync_state SET value = '1' WHERE key = 'historyMerge'")
        try h.track("t1", totalMs: 500_000)
        try h.track("t2", totalMs: 1_000)
        try h.sql("INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES ('e1', 't1', 1790000000000, 60000, 0, NULL)")
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }

        await h.engine.sync()

        #expect(h.ops(0).map { $0["kind"] as? String } == ["play.add"])
        let baseline = try #require(h.ops(1).first)
        #expect(baseline["kind"] as? String == "play.baseline")
        #expect(baseline["mode"] as? String == "atLeast")
        let entries = baseline["entries"] as? [[String: Any]] ?? []
        #expect(entries.map { $0["videoId"] as? String } == ["t1", "t2"])
        #expect(entries.map { $0["totalMs"] as? Int } == [500_000, 1_000])
        #expect(try h.state("historyMerge") == "0")
        #expect(try h.int("SELECT synced FROM play_events") == 1)
    }

    @Test func historyForgetAndClearGoUp() async throws {
        let h = try SyncHarness()
        try await h.store.forgetFromHistory(videoId: "t1", at: 1_790_000_000_000)
        try await h.store.clearHistory(at: 1_790_000_001_000)
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }

        await h.engine.sync()

        let ops = h.ops(0)
        #expect(ops.map { $0["kind"] as? String } == ["history.forget", "history.clear"])
        #expect(ops[0]["videoId"] as? String == "t1")
        #expect(ops[0]["resetTotal"] as? Bool == false)
        #expect(ops[0]["eventsBefore"] as? String == "2026-09-21T14:13:20.000Z")
        #expect(ops[1]["videoId"] == nil)
        #expect(try h.strings("SELECT op_id FROM history_ops").isEmpty)
    }

    // MARK: - Тексты (задание 0001)

    @Test func ownLyricsGoUpAndRemoteTombstoneRemovesThem() async throws {
        let h = try SyncHarness()
        try h.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES ('t1', '[00:01.00]Hi', NULL, 'user', NULL, 0, 'ru', 0)")
        // Найденный провайдером текст своим не считается и на сервер не уходит
        try h.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES ('t2', '[00:01.00]Yo', NULL, 'lrclib', NULL, 0, NULL, 0)")
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }
        h.server.on("PUT", "/lyrics/t1") { _ in (200, SyncFixtures.myLyrics("t1", rev: 5, synced: "[00:01.00]Hi")) }
        h.server.on("POST", "/auth/me/lyrics/changes") { request in
            (request.json["after"] as? Int) == 0
                ? (200, #"{"items":[\#(SyncFixtures.myLyrics("t1", rev: 5, synced: "[00:01.00]Hi"))],"rev":5,"more":false}"#)
                : (200, #"{"items":[],"rev":5,"more":false}"#)
        }

        await h.engine.sync()

        let put = try #require(h.server.requests("PUT", "/lyrics/t1").first)
        #expect(put.json["synced"] as? String == "[00:01.00]Hi")
        #expect(put.json["syncedFormat"] as? String == "lrc")
        #expect(put.json["syncedSource"] as? String == "user")
        #expect(put.json["language"] as? String == "ru")
        #expect(put.json["plain"] == nil)
        #expect(h.server.requests("PUT", "/lyrics/t2").isEmpty)
        #expect(try h.strings("SELECT video_id || ':' || rev FROM synced_lyrics") == ["t1:5"])
        #expect(try h.state("lyricsRev") == "5")

        // Надгробие с другого устройства: неизменённый свой текст удаляется
        h.server.on("POST", "/auth/me/lyrics/changes") { request in
            (request.json["after"] as? Int) == 5
                ? (200, #"{"items":[\#(SyncFixtures.myLyrics("t1", rev: 6, deleted: true))],"rev":6,"more":false}"#)
                : (200, #"{"items":[],"rev":6,"more":false}"#)
        }
        await h.engine.sync()
        #expect(try h.strings("SELECT video_id FROM lyrics") == ["t2"])
        #expect(try h.strings("SELECT video_id FROM synced_lyrics").isEmpty)
        #expect(try h.state("lyricsRev") == "6")
        #expect(h.server.requests("PUT", "/lyrics/t1").count == 1)
    }

    @Test func tombstoneKeepsTextChangedHere() async throws {
        let h = try SyncHarness()
        let edited = StoredLyrics(synced: "[00:01.00]Hi\n[00:02.00]New", plain: nil, syncedSource: "user", plainSource: nil)
        let old = StoredLyrics(synced: "[00:01.00]Hi", plain: nil, syncedSource: "user", plainSource: nil)
        try await h.store.write { tx in
            try tx.saveLyrics("t1", edited)
            try tx.setSyncedLyrics("t1", rev: 5, hash: LyricsSyncRules.hash(LyricsSyncRules.payload(old)))
        }
        let tombstone = try JSONDecoder().decode(MyLyrics.self, from: Data(SyncFixtures.myLyrics("t1", rev: 6, deleted: true).utf8))

        try await h.store.write { tx in try LibrarySync.applyLyrics(tx, tombstone) }

        #expect(try h.strings("SELECT synced FROM lyrics") == [edited.synced ?? ""])
        #expect(try h.strings("SELECT video_id FROM synced_lyrics").isEmpty)
        // Следующая синхронизация отправляет его снова
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }
        h.server.on("PUT", "/lyrics/t1") { _ in (200, SyncFixtures.myLyrics("t1", rev: 7, synced: "x")) }
        await h.engine.sync()
        #expect(h.server.requests("PUT", "/lyrics/t1").count == 1)
    }

    @Test func lyricsRoutesNeedTheFeature() async throws {
        let h = try SyncHarness(lyrics: false)
        try h.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES ('t1', '[00:01.00]Hi', NULL, 'user', NULL, 0, NULL, 0)")
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }

        await h.engine.sync()

        #expect(h.server.requests("PUT", "/lyrics/t1").isEmpty)
        #expect(h.server.requests("POST", "/auth/me/lyrics/changes").isEmpty)
    }

    // MARK: - Поводы

    @Test func ownWritesDoNotLoopTheLocalChangeObserver() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { request in
            // Сервер отвечает строками всех ключей, которых коснулись ops, и тем, что изменили другие устройства
            let likes = SyncFixtures.likeRows(request) + [#"{"videoId":"t9","liked":true,"likedAt":"2026-09-25T09:00:00.000Z"}"#]
            return (200, SyncFixtures.response(request, rows: [
                "tracks": "[\(SyncFixtures.track("t9", title: "From phone"))]",
                "likes": "[" + likes.joined(separator: ",") + "]",
                "plays": #"[{"eventId":"e9","videoId":"t9","playedAt":"2026-09-23T09:58:10.000Z","playTimeMs":212000,"deviceId":"phone"}]"#,
            ]))
        }
        h.engine.start()
        await h.engine.sync()
        #expect(h.syncRequests.count == 1)

        // Свои записи синка заметил наблюдатель, но ops по снимку нет — в сеть никто не идёт
        try await Task.sleep(for: .milliseconds(400))
        #expect(h.syncRequests.count == 1)

        // Правка человека уходит сама через паузу
        try h.track("t8", likedAt: 1_790_000_000_000)
        try await Task.sleep(for: .milliseconds(600))
        #expect(h.syncRequests.count == 2)
        #expect(h.ops(1).map { $0["videoId"] as? String } == ["t8"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(h.syncRequests.count == 2)
        h.engine.stop()
        #expect(h.engine.status == .off)
    }

    /// Сеть вернулась — синхронизация сразу, а не после паузы повтора; без аккаунта — ничего.
    @Test func networkReturnSyncsAtOnce() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { _ in (StubServer.offline, "") }
        h.engine.start()
        await h.engine.sync()
        #expect(h.engine.status == .failed(offline: true, lastSyncAt: nil))

        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }
        let before = h.syncRequests.count
        h.engine.networkReturned()
        var waited = 0
        while (h.syncRequests.count == before || h.engine.status == .syncing) && waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(h.syncRequests.count == before + 1)
        guard case .idle(let last) = h.engine.status else {
            Issue.record("status \(h.engine.status)")
            return
        }
        #expect(last != nil)

        h.engine.stop()
        h.engine.networkReturned()
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.syncRequests.count == before + 1)
    }

    @Test func signOutTurnsSyncOff() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }
        h.server.on("POST", "/auth/logout") { _ in (204, "") }
        h.engine.start()
        await h.engine.sync()
        #expect(h.engine.status != .off)

        await h.account.signOut()
        try await Task.sleep(for: .milliseconds(100))

        #expect(h.engine.status == .off)
        h.engine.stop()
    }

    // MARK: - Живые события (API §6)

    @Test func liveEventsDriveTheEngine() async throws {
        let h = try SyncHarness()
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request, cursor: "c.9.9")) }
        await h.engine.sync()
        let before = h.syncRequests.count

        h.engine.handle(LiveEvent(id: "1", type: "devices.updated", at: "", kind: .devicesUpdated(reason: "device_added", deviceId: "d2")))
        #expect(h.engine.devicesRevision == 1)

        h.engine.handle(LiveEvent(id: "2", type: "account.updated", at: "", kind: .accountUpdated(reason: "password_changed_without_old", byDeviceId: "d2", byDeviceName: "MacBook Air")))
        #expect(h.engine.accountWarning?.byDeviceName == "MacBook Air")
        h.engine.dismissAccountWarning()
        #expect(h.engine.accountWarning == nil)

        // Свой же курсор — не повод; другой — синхронизация
        h.engine.handle(LiveEvent(id: "3", type: "sync.changed", at: "", kind: .syncChanged(cursor: "c.9.9")))
        h.engine.handle(LiveEvent(id: "4", type: "sync.changed", at: "", kind: .syncChanged(cursor: "c.10.10")))
        await h.engine.sync()
        #expect(h.syncRequests.count == before + 1)

        h.engine.handle(LiveEvent(id: "5", type: "session.invalidated", at: "", kind: .sessionInvalidated(reason: "device_revoked")))
        #expect(h.account.state == .authRequired(login: "maxim"))
        #expect(h.account.endedReason == "device_revoked")
    }

    @Test func eventStreamFramesAreParsed() async throws {
        let server = StubServer()
        let frames = [
            "retry: 5000", "",
            "id: 1", #"data: {"id":"1","type":"system.connected","at":"2026-09-25T10:00:00.000Z","payload":{"heartbeatMs":25000,"retryMs":5000}}"#, "",
            ": heartbeat 1790157625000", "",
            "id: 2\r", #"data: {"id":"2","type":"sync.changed","at":"2026-09-25T10:00:01.000Z","payload":{"cursor":"c.2.2"}}"# + "\r", "\r",
            "id: 3", #"data: {"id":"3","type":"lyrics.changed","at":"x","payload":{"videoId":"t1","rev":7}}"#, "",
            "id: 4", #"data: {"id":"4","type":"future.event","at":"x","payload":null}"#, "",
            "id: 5", #"data: {"id":"5","type":"sync.changed","#,
        ]
        server.on("GET", "/auth/me/events") { _ in (200, frames.joined(separator: "\n")) }
        let api = ServerAPI(baseURL: try #require(URL(string: server.baseURL)), userAgent: "test", session: StubServer.session())

        var events: [LiveEvent] = []
        for try await event in api.events(token: "access") { events.append(event) }

        #expect(events.map(\.kind) == [
            .connected(heartbeatMs: 25_000, retryMs: 5_000), .syncChanged(cursor: "c.2.2"), .lyricsChanged(videoId: "t1", rev: 7), .other,
        ])
        #expect(server.requests("GET", "/auth/me/events").first?.headers["Authorization"] == "Bearer access")
    }

    @Test func historyDevicesAreNamedFromTheAccount() async throws {
        let h = try SyncHarness()
        try h.sql("INSERT INTO tracks (video_id, title, created_at) VALUES ('t1', 't1', 0)")
        try h.sql("INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES ('e1', 't1', 1, 1, 1, 'd1'), ('e2', 't1', 2, 1, 1, 'phone'), ('e3', 't1', 3, 1, 1, 'gone'), ('e4', 't1', 4, 1, 0, NULL)")
        let phone = Fixtures.device.replacingOccurrences(of: #""id":"d1""#, with: #""id":"phone""#)
            .replacingOccurrences(of: #""name":"Test iPhone""#, with: #""name":"Pixel""#)
            .replacingOccurrences(of: #""isCurrent":true"#, with: #""isCurrent":false"#)
        h.server.on("GET", "/auth/me/devices") { _ in (200, #"{"devices":[\#(Fixtures.device),\#(phone)],"maxDevices":20}"#) }

        let devices = await h.engine.historyDevices()

        // Текущее устройство — «Это устройство», в списке других его нет
        #expect(devices.map(\.id) == ["phone", "gone"])
        #expect(devices.map(\.name) == ["Pixel", nil])
        #expect(h.engine.currentDeviceId == "d1")
    }
}
