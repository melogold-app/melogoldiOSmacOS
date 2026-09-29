import Foundation
import GRDB
import Testing
@testable import MelogoldData

/// Миграция `lyrics-chosen-v1` (задание 0011): колонка `chosen`, тексты на месте, версии, которые сервер уже знает,
/// становятся выбранными.
@Suite("Миграция выбранных текстов")
struct LyricsMigrationTests {
    @Test func addsChosenColumnKeepsTextsAndFlagsKnownServerVersions() throws {
        let queue = try DatabaseQueue()
        // База до миграции: всё до `sync-v2`
        try AppDatabase.migrator.migrate(queue, upTo: "sync-v2")
        #expect(try queue.read { db in try !db.columns(in: "lyrics").map(\.name).contains("chosen") })
        try queue.write { db in
            let insert = "INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0)"
            // Версия с сервера, сохранённая прежней сборкой как найденная (`lrclib`), — сервер её знает
            try db.execute(sql: insert, arguments: ["known0000001", "[00:01.00]a", "", "lrclib", nil, 250, "ru"])
            // Найденное автоматически: сервер о нём не знает
            try db.execute(sql: insert, arguments: ["found000001", "[00:01.00]b", "b", "youtube_music", "youtube_music", 0, nil])
            // Свой набранный текст
            try db.execute(sql: insert, arguments: ["typed000001", "[00:01.00]c", nil, "user", nil, 0, nil])
            // Сервер отказал в тексте (rev −1): в свои он не переходит
            try db.execute(sql: insert, arguments: ["reject00001", "[00:01.00]d", nil, "lrclib", nil, 0, nil])
            try db.execute(sql: "INSERT INTO synced_lyrics (video_id, rev, hash) VALUES ('known0000001', 4, 'h'), ('reject00001', -1, 'h')")
        }

        try AppDatabase.migrator.migrate(queue)

        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, synced, plain, source, offset_ms, language, chosen FROM lyrics ORDER BY video_id")
        }
        #expect(rows.count == 4)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { (($0["video_id"] as String), $0) })
        // Тексты, источники, сдвиг и язык на месте
        #expect(byId["known0000001"]?["synced"] as String? == "[00:01.00]a")
        #expect(byId["known0000001"]?["offset_ms"] as Int64? == 250)
        #expect(byId["known0000001"]?["language"] as String? == "ru")
        #expect(byId["found000001"]?["plain"] as String? == "b")
        #expect(byId["typed000001"]?["source"] as String? == "user")
        // Флаг: только у версии, которую знает сервер
        #expect(byId["known0000001"]?["chosen"] as Int64? == 1)
        #expect(byId["found000001"]?["chosen"] as Int64? == 0)
        #expect(byId["typed000001"]?["chosen"] as Int64? == 0)
        #expect(byId["reject00001"]?["chosen"] as Int64? == 0)
    }
}
