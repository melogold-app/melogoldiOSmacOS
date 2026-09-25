import Foundation
import GRDB
import MelogoldCore
import Synchronization
import Testing
@testable import MelogoldData

/// Снимки синка и доступ к ним (срез 5): миграция, смена аккаунта, порядок по ключам сервера, история.
@Suite("SyncStore — снимки синка")
struct SyncStoreTests {
    let database: AppDatabase
    let store: SyncStore

    init() throws {
        database = try AppDatabase.inMemory()
        store = SyncStore(database: database)
    }

    private func execute(_ sql: String, _ arguments: StatementArguments = []) async throws {
        try await database.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    private func strings(_ sql: String, _ arguments: StatementArguments = []) async throws -> [String] {
        try await database.writer.read { db in try String.fetchAll(db, sql: sql, arguments: arguments) }
    }

    private func track(_ id: String) -> SyncTrackRecord {
        SyncTrackRecord(videoId: id, title: "Song \(id)", artistsText: "Artist", artists: [ArtistRef(id: "UC1", name: "Artist")], durationMs: 200_000)
    }

    @Test func syncMigrationCreatesSnapshotTables() async throws {
        let columns = try await database.writer.read { db in
            try ["sync_state", "synced_likes", "synced_bookmarks", "synced_playlists", "synced_lyrics", "history_ops"]
                .map { table in (table, try db.columns(in: table).map(\.name)) }
        }
        let byTable = Dictionary(uniqueKeysWithValues: columns)
        #expect(byTable["sync_state"] == ["key", "value"])
        #expect(byTable["synced_playlists"] == ["sync_id", "name", "thumbnail_url", "video_ids"])
        #expect(byTable["synced_lyrics"] == ["video_id", "rev", "hash"])
        #expect(byTable["history_ops"] == ["op_id", "kind", "video_id", "events_before"])
        #expect(byTable["synced_bookmarks"] == ["type", "browse_id"])
    }

    @Test func forgetBindingKeepsOwnPlaysAndDropsForeignOnes() async throws {
        try await store.write { tx in
            try tx.upsertTrack(self.track("aaaaaaaaaaa"))
            try tx.setState("binding", "s:u")
            try tx.setLike("aaaaaaaaaaa", likedAt: 1000)
            let id = try tx.insertPlaylist(name: "Дорога", browseId: nil, thumbnailUrl: nil, syncId: "p1", createdAt: 1)
            try tx.upsertItem(id, videoId: "aaaaaaaaaaa", sortKey: "a0", addedAt: 1)
            try tx.insertPlay(eventId: "e-own", videoId: "aaaaaaaaaaa", playedAt: 10, playTimeMs: 1000, deviceId: nil)
            try tx.insertPlay(eventId: "e-other", videoId: "aaaaaaaaaaa", playedAt: 20, playTimeMs: 1000, deviceId: "phone")
            try tx.setSyncedLyrics("aaaaaaaaaaa", rev: 2, hash: "h")
            try tx.enqueueHistoryOp(kind: "history.clear", videoId: nil, eventsBefore: 5)
        }
        #expect(try await store.read { try $0.unsentPlays() }.isEmpty)

        try await store.write { try $0.forgetBinding() }

        #expect(try await store.read { try $0.unsentPlays() }.map(\.eventId) == ["e-own"])
        #expect(try await strings("SELECT event_id FROM play_events") == ["e-own"])
        #expect(try await store.read { try $0.syncedLikes() }.isEmpty)
        #expect(try await store.read { try $0.syncedPlaylists() }.isEmpty)
        #expect(try await store.read { try $0.syncedLyrics() }.isEmpty)
        #expect(try await store.read { try $0.historyOps() }.isEmpty)
        #expect(try await store.state("binding") == nil)
        #expect(try await strings("SELECT COALESCE(sync_id, '-') FROM playlists") == ["-"])
        #expect(try await strings("SELECT COALESCE(sort_key, '-') FROM playlist_items") == ["-"])
        // Сама библиотека остаётся
        #expect(try await store.read { try $0.likes() }.map(\.track.videoId) == ["aaaaaaaaaaa"])
    }

    @Test func reorderPutsKeyedItemsInServerOrderThenLocalOnes() async throws {
        let ids = ["v1", "v2", "v3", "v4"]
        let snapshot = try await store.write { tx -> SyncedPlaylist? in
            for id in ids { try tx.upsertTrack(self.track(id)) }
            let playlist = try tx.insertPlaylist(name: "P", browseId: nil, thumbnailUrl: nil, syncId: "p1", createdAt: 1)
            // Локальный трек без ключа стоит первым; ключи сервера сравниваются побайтово: «A0» < «a1» < «b0»
            try tx.db.execute(sql: "INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (?, 'v4', 0, NULL, 1)", arguments: [playlist])
            try tx.upsertItem(playlist, videoId: "v1", sortKey: "b0", addedAt: 1)
            try tx.upsertItem(playlist, videoId: "v2", sortKey: "a1", addedAt: 1)
            try tx.upsertItem(playlist, videoId: "v3", sortKey: "A0", addedAt: 1)
            try tx.reorder(playlist)
            return try tx.syncedPlaylists()["p1"]
        }
        #expect(try await strings("SELECT video_id FROM playlist_items ORDER BY position") == ["v3", "v2", "v1", "v4"])
        // Снимок — только то, что знает сервер
        #expect(snapshot?.videoIds == ["v3", "v2", "v1"])
    }

    @Test func historyActionsQueueOpsForTheServer() async throws {
        let first = try await store.recordPlay(track("aaaaaaaaaaa"), playTimeMs: 120_000, playedAt: 1_000)
        try await store.recordPlay(track("bbbbbbbbbbb"), playTimeMs: 60_000, playedAt: 2_000)
        try await store.write { try $0.insertPlay(eventId: "e-phone", videoId: "bbbbbbbbbbb", playedAt: 1_500, playTimeMs: 1, deviceId: "phone") }
        #expect(first == first.lowercased())
        #expect(try await store.historyDeviceIds() == ["phone"])
        #expect(try await store.read { try $0.playTotals() }.map(\.totalMs) == [120_000, 60_000])

        try await store.forgetFromHistory(videoId: "aaaaaaaaaaa", at: 3_000)
        try await store.clearHistory(at: 4_000)

        #expect(try await strings("SELECT event_id FROM play_events").isEmpty)
        let ops = try await store.read { try $0.historyOps() }
        #expect(ops.map(\.kind) == ["history.forget", "history.clear"])
        #expect(ops.first?.videoId == "aaaaaaaaaaa")
        #expect(ops.map(\.eventsBefore) == [3_000, 4_000])
        // Общее время трека остаётся (resetTotal: false)
        #expect(try await store.read { try $0.playTotals() }.count == 2)
    }

    @Test func serverMetadataUpgradesOnlyStubs() async throws {
        try await store.write { tx in
            try tx.ensureTrack("aaaaaaaaaaa", metadata: nil)
            try tx.ensureTrack("aaaaaaaaaaa", metadata: self.track("aaaaaaaaaaa"))
            try tx.upsertTrack(SyncTrackRecord(videoId: "bbbbbbbbbbb", title: "Local title"))
            try tx.ensureTrack("bbbbbbbbbbb", metadata: SyncTrackRecord(videoId: "bbbbbbbbbbb", title: "Server title"))
        }
        let a = try await store.read { try $0.track("aaaaaaaaaaa") }
        #expect(a?.title == "Song aaaaaaaaaaa")
        #expect(a?.metadataStub == false)
        #expect(a?.artists == [ArtistRef(id: "UC1", name: "Artist")])
        #expect(a?.durationText == "3:20")
        #expect(try await store.read { try $0.track("bbbbbbbbbbb") }?.title == "Local title")
    }

    @Test func localChangesAreObserved() async throws {
        let counter = Counter()
        let observation = store.observeLocalChanges { counter.increment() }
        defer { observation.cancel() }
        try await store.write { try $0.upsertTrack(self.track("aaaaaaaaaaa")) }
        let afterInsert = counter.value
        // Метаданные и время прослушивания синк не отправляет — не наблюдаются
        try await execute("UPDATE tracks SET title = 'x', total_play_ms = 5 WHERE video_id = 'aaaaaaaaaaa'")
        #expect(counter.value == afterInsert)
        try await execute("UPDATE tracks SET liked_at = 1 WHERE video_id = 'aaaaaaaaaaa'")
        #expect(counter.value == afterInsert + 1)
        try await execute("INSERT INTO sync_state (key, value) VALUES ('cursor', 'c')")
        #expect(counter.value == afterInsert + 1)
    }
}

final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
