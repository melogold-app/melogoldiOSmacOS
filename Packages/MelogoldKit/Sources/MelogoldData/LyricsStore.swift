import Foundation
import GRDB
import MelogoldCore

/// Тексты треков на устройстве (таблица `lyrics`, колонки как у Windows): найденные в сети — кэш, свои (источник
/// `user` или `file`) — библиотека, их синк отправляет на сервер (задание 0001). Об изменении своего текста синк узнаёт
/// через `setOwnLyricsRecorder` — в той же транзакции, что и запись.
public final class LyricsStore: Sendable {
    public let database: AppDatabase
    private let recorderBox = OwnLyricsRecorderBox()

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Синк ставит сюда отметку «свой текст трека изменился или удалён» (`videoId`).
    public func setOwnLyricsRecorder(_ recorder: (@Sendable (Database, String) throws -> Void)?) {
        recorderBox.set(recorder)
    }

    /// Текст из кэша: `nil` у стороны — ещё не искали, пустая строка — искали и не нашли.
    public func lyrics(_ videoId: String) -> StoredLyrics? {
        (try? database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT synced, plain, source, plain_source, offset_ms, language FROM lyrics WHERE video_id = ?",
                             arguments: [videoId]).map { row in
                StoredLyrics(synced: row["synced"], plain: row["plain"], syncedSource: row["source"], plainSource: row["plain_source"],
                             offsetMs: row["offset_ms"] ?? 0, language: row["language"])
            }
        }) ?? nil
    }

    /// Записать текст. Свой текст (или бывший свой) отмечается для синка.
    public func save(_ videoId: String, _ lyrics: StoredLyrics) {
        let recorder = recorderBox
        _ = try? database.writer.write { db in
            let wasOwn = try Self.isOwn(db, videoId)
            try db.execute(sql: """
                INSERT OR REPLACE INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [videoId, lyrics.synced, lyrics.plain, lyrics.syncedSource, lyrics.plainSource, lyrics.offsetMs,
                                 lyrics.language, EpochMs.now()])
            if lyrics.isOwn || wasOwn { try recorder.record(db, videoId) }
        }
    }

    /// Удалить текст трека (свой — отмечается для синка: сервер получит надгробие).
    public func delete(_ videoId: String) {
        let recorder = recorderBox
        _ = try? database.writer.write { db in
            let wasOwn = try Self.isOwn(db, videoId)
            try db.execute(sql: "DELETE FROM lyrics WHERE video_id = ?", arguments: [videoId])
            if wasOwn { try recorder.record(db, videoId) }
        }
    }

    /// Сдвиг синхронного текста трека (±0,1 и ±0,5 с в меню текста).
    public func setOffset(_ videoId: String, _ offsetMs: Int64) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE lyrics SET offset_ms = ? WHERE video_id = ?", arguments: [offsetMs, videoId])
        }
    }

    private static let fetchedOnly = "COALESCE(source, '') NOT IN ('file', 'user') AND COALESCE(plain_source, '') NOT IN ('file', 'user')"

    /// Размер найденных в сети текстов, байт (кэш: их можно найти снова).
    public func fetchedSize() -> Int64 {
        ((try? database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(COALESCE(synced, '')) + LENGTH(COALESCE(plain, ''))), 0) FROM lyrics WHERE \(Self.fetchedOnly)")
        }) ?? nil) ?? 0
    }

    /// Очистка кэша: найденные в сети тексты забываются, свои и импортированные остаются.
    public func clearFetched() {
        _ = try? database.writer.write { db in try db.execute(sql: "DELETE FROM lyrics WHERE \(Self.fetchedOnly)") }
    }

    private static func isOwn(_ db: Database, _ videoId: String) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT source, plain_source FROM lyrics WHERE video_id = ?", arguments: [videoId]) else {
            return false
        }
        return LyricsSources.isOwn(row["source"]) || LyricsSources.isOwn(row["plain_source"])
    }
}

private final class OwnLyricsRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: (@Sendable (Database, String) throws -> Void)?

    func set(_ value: (@Sendable (Database, String) throws -> Void)?) {
        lock.withLock { recorder = value }
    }

    func record(_ db: Database, _ videoId: String) throws {
        let current = lock.withLock { recorder }
        try current?(db, videoId)
    }
}
