import Foundation
import GRDB
import Testing
import MelogoldCore
import MelogoldData
@testable import MelogoldServer

/// Импорт копии (задание 0006 §2) и синк: `LibraryImport` пишет ключ `historyMerge` строкой (MelogoldData не видит
/// `SyncStateKey`). Если ключ здесь переименуют, импорт перестанет заново отправлять накопленное время — этот тест упадёт.
@Suite("Импорт копии и синк истории")
struct ImportSyncTests {
    @Test func importSendsPlaysThenBaselineAtLeast() async throws {
        #expect(SyncStateKey.historyMerge == "historyMerge", "LibraryImport пишет этот ключ строкой")
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('historyMerge', '0')")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("vitune.db")
        let queue = try DatabaseQueue(path: backup.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE Song (id TEXT PRIMARY KEY, title TEXT NOT NULL, likedAt INTEGER, totalPlayTimeMs INTEGER NOT NULL);
                CREATE TABLE Event (id INTEGER PRIMARY KEY, songId TEXT NOT NULL, timestamp INTEGER NOT NULL, playTime INTEGER NOT NULL);
                INSERT INTO Song VALUES ('dQw4w9WgXcQ', 'Never Gonna Give You Up', NULL, 600000);
                INSERT INTO Event (songId, timestamp, playTime) VALUES ('dQw4w9WgXcQ', 1726000100000, 215000);
                """)
        }
        try queue.close()

        let summary = try LibraryImport.run(backup, into: database)
        #expect(summary.plays == 1)
        let store = SyncStore(database: database)
        #expect(try await store.state(SyncStateKey.historyMerge) == "1")
        #expect(try await store.state(SyncStateKey.historyReplay) == nil)

        // Сначала — прослушивания как свои play.add, накопленное время — только когда все они на сервере
        let builder = SyncOpBuilder(mergeUploadMax: nil)
        let first = try await store.write { tx in try builder.build(tx) }
        #expect(first.ops.map(\.kind) == ["play.add"])
        #expect(first.ops.first?.op.opId == ImportIds.eventId(videoId: "dQw4w9WgXcQ", timestampMs: 1_726_000_100_000, playTimeMs: 215_000))

        try await database.writer.write { db in try db.execute(sql: "UPDATE play_events SET synced = 1") }
        let second = try await store.write { tx in try builder.build(tx) }
        let baseline = try #require(second.ops.first { $0.kind == "play.baseline" })
        #expect(baseline.op.mode == "atLeast")
        #expect(baseline.op.entries?.first?.videoId == "dQw4w9WgXcQ")
        #expect(baseline.op.entries?.first?.totalMs == 600_000)
    }
}
