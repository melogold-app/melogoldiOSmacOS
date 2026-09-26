import Foundation
import GRDB
import MelogoldCore

/// Состояние загрузки трека (REWRITE §4.7.4).
public enum DownloadState: String, Sendable {
    case queued, downloading, completed, failed, paused, waiting
}

/// Почему загрузка ждёт.
public enum DownloadWait: String, Sendable {
    case network, wifi, storage
}

public struct DownloadEntry: Hashable, Sendable, Identifiable {
    public var videoId: String
    public var state: DownloadState
    public var wait: DownloadWait?
    /// Класс ошибки потока (`StreamError.Kind`) у `failed`.
    public var failure: String?
    public var manual: Bool
    public var contentLength: Int64?
    public var downloadedBytes: Int64
    public var attempts: Int
    public var createdAt: Int64
    public var completedAt: Int64?
    public var track: Track?

    public var id: String { videoId }

    public var progress: Double {
        guard let contentLength, contentLength > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(contentLength))
    }
}

/// Скачиваемая коллекция: плейлист, альбом или всё Избранное (REWRITE §4.7.3).
public struct DownloadCollection: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case playlist, album, liked
    }

    public var kind: Kind
    /// id своего плейлиста, browseId альбома, пусто у Избранного.
    public var key: String
    public var title: String?
    public var total: Int
    public var done: Int

    public var id: String { kind.rawValue + ":" + key }
}

/// Загрузки на устройстве (REWRITE §4.7): файлы `Downloads/<videoId>.m4a` (не входят в резервную копию) и строки
/// `downloads`. Что должно быть скачано, считает план (§4.7.3): ручные загрузки и треки скачиваемых коллекций; `reconcile`
/// ставит недостающее в очередь и удаляет ненужное. Файл пишется диапазонами — оборванная загрузка продолжается с того
/// же места. Потокобезопасно: загрузчик пишет со своих задач.
public final class DownloadStore: @unchecked Sendable {
    public let directory: URL
    private let database: AppDatabase
    private let lock = NSLock()

    public init(database: AppDatabase, directory: URL) {
        self.database = database
        self.directory = directory
    }

    public func fileURL(_ videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).m4a")
    }

    // MARK: - Чтение

    static func entry(_ row: Row) -> DownloadEntry {
        DownloadEntry(
            videoId: row["video_id"], state: DownloadState(rawValue: row["state"]) ?? .queued,
            wait: (row["wait_reason"] as String?).flatMap(DownloadWait.init(rawValue:)), failure: row["failure"],
            manual: row["manual"] ?? false, contentLength: row["content_length"], downloadedBytes: row["downloaded_bytes"] ?? 0,
            attempts: row["attempts"] ?? 0, createdAt: row["created_at"] ?? 0, completedAt: row["completed_at"],
            track: row["title"] == nil ? nil : Library.track(row)
        )
    }

    private static let select = """
        SELECT d.*, \(Library.columns("t")) FROM downloads d LEFT JOIN tracks t ON t.video_id = d.video_id
        """

    public func entry(_ videoId: String) -> DownloadEntry? {
        (try? database.writer.read { db in
            try Row.fetchOne(db, sql: Self.select + " WHERE d.video_id = ?", arguments: [videoId]).map(Self.entry)
        }) ?? nil
    }

    public func entries() -> [DownloadEntry] {
        (try? database.writer.read { db in
            try Row.fetchAll(db, sql: Self.select + " ORDER BY COALESCE(d.completed_at, d.created_at) DESC").map(Self.entry)
        }) ?? []
    }

    public func states() -> [String: DownloadState] {
        let rows = (try? database.writer.read { db in try Row.fetchAll(db, sql: "SELECT video_id, state FROM downloads") }) ?? []
        var result: [String: DownloadState] = [:]
        for row in rows { result[row["video_id"]] = DownloadState(rawValue: row["state"]) }
        return result
    }

    public func isComplete(_ videoId: String) -> Bool {
        entry(videoId)?.state == .completed
    }

    /// Скачанный трек для плеера: длина, тип, длительность, громкость.
    public func completeInfo(_ videoId: String) -> (length: Int64, mimeType: String, durationMs: Int64?, loudnessDb: Double?)? {
        guard let row = try? database.writer.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT content_length, mime_type, duration_ms, loudness_db FROM downloads WHERE video_id = ? AND state = 'completed'
                """, arguments: [videoId])
        }), let length: Int64 = row["content_length"] else { return nil }
        return (length, row["mime_type"] ?? "audio/mp4", row["duration_ms"], row["loudness_db"])
    }

    /// Байты скачанного трека.
    public func read(_ videoId: String, offset: Int64, length: Int) -> Data? {
        guard length > 0 else { return Data() }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL(videoId))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    /// Сколько места занимают загрузки.
    public func totalBytes() -> Int64 {
        ((try? database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(downloaded_bytes), 0) FROM downloads") }) ?? nil) ?? 0
    }

    // MARK: - План (REWRITE §4.7.3)

    /// Что должно быть скачано: ручные загрузки и треки скачиваемых коллекций, кроме трансляций.
    public func desiredIds() -> Set<String> {
        let ids = (try? database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT video_id FROM downloads WHERE manual = 1
                UNION SELECT i.video_id FROM playlist_items i
                    JOIN download_collections c ON c.kind = 'playlist' AND c.key = CAST(i.playlist_id AS TEXT)
                UNION SELECT a.video_id FROM album_tracks a JOIN download_collections c ON c.kind = 'album' AND c.key = a.album_id
                UNION SELECT video_id FROM tracks WHERE liked_at IS NOT NULL
                    AND EXISTS (SELECT 1 FROM download_collections WHERE kind = 'liked')
                """)
        }) ?? []
        let live = Set((try? database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT video_id FROM tracks WHERE video_type = 'live'")
        }) ?? [])
        return Set(ids).subtracting(live)
    }

    /// Сверка с планом: недостающее — в очередь, ненужное — удалить с файлом. Возвращает, изменилось ли что-то.
    @discardableResult
    public func reconcile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let desired = desiredIds()
        let present = Set((try? database.writer.read { db in try String.fetchAll(db, sql: "SELECT video_id FROM downloads") }) ?? [])
        let add = desired.subtracting(present)
        let remove = present.subtracting(desired)
        guard !add.isEmpty || !remove.isEmpty else { return false }
        let now = EpochMs.now()
        _ = try? database.writer.write { db in
            for videoId in add {
                try db.execute(sql: "INSERT OR IGNORE INTO downloads (video_id, state, created_at) VALUES (?, 'queued', ?)", arguments: [videoId, now])
            }
            for videoId in remove {
                try db.execute(sql: "DELETE FROM downloads WHERE video_id = ?", arguments: [videoId])
            }
        }
        for videoId in remove { try? FileManager.default.removeItem(at: fileURL(videoId)) }
        if !add.isEmpty || !remove.isEmpty {
            Log.info("downloads", "План загрузок: +\(add.count), −\(remove.count)")
        }
        return true
    }

    /// «Скачать» трек.
    public func requestTrack(_ track: Track) {
        let now = EpochMs.now()
        _ = try? database.writer.write { db in
            try Library.upsert(db, track)
            try db.execute(sql: """
                INSERT INTO downloads (video_id, state, manual, created_at) VALUES (?, 'queued', 1, ?)
                ON CONFLICT(video_id) DO UPDATE SET manual = 1,
                    state = CASE WHEN downloads.state = 'failed' THEN 'queued' ELSE downloads.state END, attempts = 0
                """, arguments: [track.videoId, now])
        }
    }

    /// «Удалить загрузку» трека (если он не нужен коллекции, сверка удалит и файл).
    public func removeTrack(_ videoId: String) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE downloads SET manual = 0 WHERE video_id = ?", arguments: [videoId])
        }
        reconcile()
    }

    public func setCollection(_ kind: DownloadCollection.Kind, key: String, title: String?, downloading: Bool) {
        _ = try? database.writer.write { db in
            if downloading {
                try db.execute(sql: "INSERT OR REPLACE INTO download_collections (kind, key, title, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [kind.rawValue, key, title, EpochMs.now()])
            } else {
                try db.execute(sql: "DELETE FROM download_collections WHERE kind = ? AND key = ?", arguments: [kind.rawValue, key])
            }
        }
        reconcile()
    }

    public func isCollection(_ kind: DownloadCollection.Kind, key: String) -> Bool {
        ((try? database.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM download_collections WHERE kind = ? AND key = ?", arguments: [kind.rawValue, key])
        }) ?? nil) ?? false
    }

    /// Скачиваемые коллекции с числом «k из n».
    public func collections() -> [DownloadCollection] {
        (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, key, title FROM download_collections ORDER BY created_at DESC").compactMap { row in
                guard let kind = DownloadCollection.Kind(rawValue: row["kind"]) else { return nil }
                let key: String = row["key"]
                let members: String = switch kind {
                case .playlist: "SELECT video_id FROM playlist_items WHERE playlist_id = CAST(? AS INTEGER)"
                case .album: "SELECT video_id FROM album_tracks WHERE album_id = ?"
                case .liked: "SELECT video_id FROM tracks WHERE liked_at IS NOT NULL AND ? = ''"
                }
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(members))", arguments: [key]) ?? 0
                let done = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM downloads WHERE state = 'completed' AND video_id IN (\(members))
                    """, arguments: [key]) ?? 0
                return DownloadCollection(kind: kind, key: key, title: row["title"], total: total, done: done)
            }
        }) ?? []
    }

    // MARK: - Загрузчик

    /// Следующие треки в очереди (и ожидающие — их загрузчик проверит снова).
    public func pending(limit: Int) -> [String] {
        (try? database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT video_id FROM downloads WHERE state IN ('queued', 'waiting') ORDER BY created_at LIMIT ?
                """, arguments: [limit])
        }) ?? []
    }

    public func setState(_ videoId: String, _ state: DownloadState, wait: DownloadWait? = nil, failure: String? = nil) {
        _ = try? database.writer.write { db in
            try db.execute(sql: """
                UPDATE downloads SET state = ?, wait_reason = ?, failure = ?,
                    completed_at = CASE WHEN ? = 'completed' THEN ? ELSE completed_at END WHERE video_id = ?
                """, arguments: [state.rawValue, wait?.rawValue, failure, state.rawValue, EpochMs.now(), videoId])
        }
    }

    public func incrementAttempts(_ videoId: String) -> Int {
        ((try? database.writer.write { db -> Int? in
            try db.execute(sql: "UPDATE downloads SET attempts = attempts + 1 WHERE video_id = ?", arguments: [videoId])
            return try Int.fetchOne(db, sql: "SELECT attempts FROM downloads WHERE video_id = ?", arguments: [videoId])
        }) ?? nil) ?? 0
    }

    /// Формат и длина; смена формата стирает скачанные байты.
    public func prepare(_ videoId: String, itag: Int, mimeType: String, contentLength: Int64, durationMs: Int64?, loudnessDb: Double?) {
        lock.lock()
        defer { lock.unlock() }
        _ = try? database.writer.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT itag, content_length FROM downloads WHERE video_id = ?", arguments: [videoId])
            let sameFormat = (row?["itag"] as Int?) == itag && (row?["content_length"] as Int64?) == contentLength
            if !sameFormat {
                try? FileManager.default.removeItem(at: fileURL(videoId))
                try db.execute(sql: "UPDATE downloads SET ranges = '', downloaded_bytes = 0 WHERE video_id = ?", arguments: [videoId])
            }
            try db.execute(sql: """
                UPDATE downloads SET itag = ?, mime_type = ?, content_length = ?, duration_ms = COALESCE(?, duration_ms),
                    loudness_db = COALESCE(?, loudness_db) WHERE video_id = ?
                """, arguments: [itag, mimeType, contentLength, durationMs, loudnessDb, videoId])
        }
    }

    /// Первый недостающий диапазон с `from`: откуда продолжать.
    public func missing(_ videoId: String) -> Range<Int64>? {
        guard let row = try? database.writer.read({ db in
            try Row.fetchOne(db, sql: "SELECT ranges, content_length FROM downloads WHERE video_id = ?", arguments: [videoId])
        }), let length: Int64 = row["content_length"] else { return nil }
        let ranges = ByteRanges(serialized: row["ranges"] ?? "")
        var cursor: Int64 = 0
        for range in ranges.ranges {
            if range.lowerBound > cursor { return cursor..<range.lowerBound }
            cursor = max(cursor, range.upperBound)
        }
        return cursor < length ? cursor..<length : nil
    }

    /// Записать кусок; когда файл собран целиком — `completed`. Возвращает, завершён ли трек.
    @discardableResult
    public func write(_ videoId: String, offset: Int64, data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = fileURL(videoId)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            try handle.close()
            return try database.writer.write { db -> Bool in
                guard let row = try Row.fetchOne(db, sql: "SELECT ranges, content_length FROM downloads WHERE video_id = ?",
                                                 arguments: [videoId]) else { return false }
                var ranges = ByteRanges(serialized: row["ranges"] ?? "")
                ranges.insert(offset..<(offset + Int64(data.count)))
                let complete = (row["content_length"] as Int64?).map { ranges.covers(length: $0) } ?? false
                try db.execute(sql: """
                    UPDATE downloads SET ranges = ?, downloaded_bytes = ?, state = CASE WHEN ? THEN 'completed' ELSE state END,
                        completed_at = CASE WHEN ? THEN ? ELSE completed_at END, wait_reason = NULL, failure = NULL WHERE video_id = ?
                    """, arguments: [ranges.serialized, ranges.totalBytes, complete, complete, EpochMs.now(), videoId])
                return complete
            }
        } catch {
            Log.error("downloads", "\(videoId): запись не удалась: \(error.localizedDescription)")
            return false
        }
    }

    /// Сверка с папкой на старте: у скачанных без файла — снова в очередь, загрузки в работе — в очередь.
    public func reconcileFiles() {
        let rows = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, state FROM downloads")
        }) ?? []
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE downloads SET state = 'queued' WHERE state = 'downloading'")
            for row in rows where row["state"] as String == DownloadState.completed.rawValue {
                let videoId: String = row["video_id"]
                if !FileManager.default.fileExists(atPath: fileURL(videoId).path) {
                    try db.execute(sql: "UPDATE downloads SET state = 'queued', ranges = '', downloaded_bytes = 0 WHERE video_id = ?",
                                   arguments: [videoId])
                }
            }
        }
        reconcile()
    }

    /// «Удалить все загрузки».
    public func removeAll() {
        lock.lock()
        _ = try? database.writer.write { db in
            try db.execute(sql: "DELETE FROM download_collections")
            try db.execute(sql: "DELETE FROM downloads")
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? AppPaths.excludeFromBackup(directory)
    }

    /// «Повторить все» у ошибок.
    public func retryFailed() {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE downloads SET state = 'queued', failure = NULL, attempts = 0 WHERE state = 'failed'")
        }
    }

    public func retry(_ videoId: String) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE downloads SET state = 'queued', failure = NULL, attempts = 0 WHERE video_id = ?", arguments: [videoId])
        }
    }

    /// «Пауза» и «Продолжить» у всех активных.
    public func setPaused(_ paused: Bool) {
        _ = try? database.writer.write { db in
            if paused {
                try db.execute(sql: "UPDATE downloads SET state = 'paused' WHERE state IN ('queued', 'downloading', 'waiting')")
            } else {
                try db.execute(sql: "UPDATE downloads SET state = 'queued' WHERE state = 'paused'")
            }
        }
    }
}
