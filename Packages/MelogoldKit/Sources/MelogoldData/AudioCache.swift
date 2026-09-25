import Foundation
import GRDB
import MelogoldCore

/// Что известно о треке в кэше музыки.
public struct AudioCacheEntry: Hashable, Sendable {
    public var videoId: String
    public var itag: Int
    public var mimeType: String
    public var contentLength: Int64?
    public var durationMs: Int64?
    public var loudnessDb: Double?
    public var cachedBytes: Int64
    public var complete: Bool
    public var lastReadAt: Int64
}

/// Диапазоны байтов `[start, end)`, отсортированные и слитые.
public struct ByteRanges: Hashable, Sendable {
    public private(set) var ranges: [Range<Int64>]

    public init(_ ranges: [Range<Int64>] = []) {
        self.ranges = []
        for range in ranges { insert(range) }
    }

    /// «0-524288,1048576-1572864».
    public init(serialized: String) {
        self.init(serialized.split(separator: ",").compactMap { part -> Range<Int64>? in
            let bounds = part.split(separator: "-")
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start < end else { return nil }
            return start..<end
        })
    }

    public var serialized: String {
        ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
    }

    public var totalBytes: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    public mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged: [Range<Int64>] = []
        var current = range
        for existing in ranges {
            if existing.upperBound < current.lowerBound || existing.lowerBound > current.upperBound {
                merged.append(existing)
            } else {
                current = min(existing.lowerBound, current.lowerBound)..<max(existing.upperBound, current.upperBound)
            }
        }
        merged.append(current)
        ranges = merged.sorted { $0.lowerBound < $1.lowerBound }
    }

    public func contains(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        return ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// Сколько байт подряд есть на диске, начиная с `offset`.
    public func available(from offset: Int64) -> Int64 {
        guard let range = ranges.first(where: { $0.contains(offset) }) else { return 0 }
        return range.upperBound - offset
    }

    /// Все байты от 0 до `length` — трек целиком в кэше (задание 0003 §3), в том числе при неполном последнем куске.
    public func covers(length: Int64) -> Bool {
        length > 0 && contains(0..<length)
    }
}

/// Кэш музыки (задание 0003): проигранное остаётся на диске, повторное прослушивание не тратит трафик.
///
/// - файлы — `AudioCache/<videoId>.m4a` в `Application Support` с `isExcludedFromBackup`, байты по своим смещениям;
/// - индекс — таблица `audio_cache`: формат, длина, диапазоны, время последнего чтения. Вытеснение — по индексу,
///   без обхода диска: сначала то, что дольше всех не слушали; играющий и следующий треки защищены;
/// - один формат на трек: смена itag или длины удаляет старые байты;
/// - на старте индекс сверяется с папкой: лишние файлы удаляются, пропавшие забываются.
///
/// Методы синхронные и потокобезопасные: их зовёт загрузчик ресурсов AVFoundation со своей очереди.
public final class AudioCache: @unchecked Sendable {
    public let directory: URL
    private let database: AppDatabase
    private let limit: @Sendable () -> Int64
    private let lock = NSLock()
    private var protected: Set<String> = []

    /// `limit` — размер кэша в байтах, `0` — без ограничений (`AppSettings.cacheLimit`).
    public init(database: AppDatabase, directory: URL, limit: @escaping @Sendable () -> Int64) {
        self.database = database
        self.directory = directory
        self.limit = limit
    }

    public func fileURL(_ videoId: String) -> URL {
        directory.appendingPathComponent("\(videoId).m4a")
    }

    // MARK: - Индекс

    public func entry(_ videoId: String) -> AudioCacheEntry? {
        try? database.writer.read { db in try Self.fetchEntry(db, videoId) }
    }

    /// Трек, который можно играть без сети и без запроса потока.
    public func completeEntry(_ videoId: String) -> AudioCacheEntry? {
        guard let entry = entry(videoId), entry.complete else { return nil }
        return entry
    }

    public func isComplete(_ videoId: String) -> Bool {
        (try? database.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT complete FROM audio_cache WHERE video_id = ?", arguments: [videoId])
        }) ?? false
    }

    /// Все треки, лежащие целиком: группа «В кэше» в «Скачанном».
    public func completeVideoIds() -> [String] {
        (try? database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT video_id FROM audio_cache WHERE complete = 1 ORDER BY last_read_at DESC")
        }) ?? []
    }

    /// Запись для потока: прочитанное раньше остаётся, если формат и длина те же; иначе байты удаляются.
    @discardableResult
    public func prepare(videoId: String, itag: Int, mimeType: String, contentLength: Int64?,
                        durationMs: Int64?, loudnessDb: Double?) -> AudioCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        let now = EpochMs.now()
        do {
            return try database.writer.write { db -> AudioCacheEntry? in
                if let existing = try Self.fetchEntry(db, videoId) {
                    let sameFormat = existing.itag == itag
                        && (existing.contentLength == nil || contentLength == nil || existing.contentLength == contentLength)
                    if sameFormat {
                        try db.execute(sql: """
                            UPDATE audio_cache SET content_length = COALESCE(content_length, ?), duration_ms = COALESCE(?, duration_ms),
                                loudness_db = COALESCE(?, loudness_db), last_read_at = ? WHERE video_id = ?
                            """, arguments: [contentLength, durationMs, loudnessDb, now, videoId])
                        return try Self.fetchEntry(db, videoId)
                    }
                    Log.info("cache", "\(videoId): формат сменился (itag \(existing.itag) → \(itag)), старые байты удалены")
                    try? FileManager.default.removeItem(at: fileURL(videoId))
                    try db.execute(sql: "DELETE FROM audio_cache WHERE video_id = ?", arguments: [videoId])
                }
                try db.execute(sql: """
                    INSERT INTO audio_cache (video_id, itag, mime_type, content_length, duration_ms, loudness_db, ranges,
                        cached_bytes, complete, last_read_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, '', 0, 0, ?, ?)
                    """, arguments: [videoId, itag, mimeType, contentLength, durationMs, loudnessDb, now, now])
                return try Self.fetchEntry(db, videoId)
            }
        } catch {
            Log.error("cache", "Индекс кэша: \(error.localizedDescription)")
            return nil
        }
    }

    /// Трек начал играть: он дольше всех не будет вытеснен.
    public func touch(_ videoId: String) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE audio_cache SET last_read_at = ? WHERE video_id = ?", arguments: [EpochMs.now(), videoId])
        }
    }

    public func setContentLength(_ videoId: String, _ length: Int64) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE audio_cache SET content_length = ? WHERE video_id = ? AND content_length IS NULL",
                           arguments: [length, videoId])
        }
    }

    public func setDuration(_ videoId: String, ms: Int64) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE audio_cache SET duration_ms = ? WHERE video_id = ?", arguments: [ms, videoId])
        }
    }

    // MARK: - Байты

    /// Диапазон целиком на диске — прочитать его; иначе `nil`.
    public func read(_ videoId: String, offset: Int64, length: Int) -> Data? {
        guard length > 0 else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        guard let row = try? database.writer.read({ db in
            try Row.fetchOne(db, sql: "SELECT ranges FROM audio_cache WHERE video_id = ?", arguments: [videoId])
        }), let serialized = row["ranges"] as String? else { return nil }
        guard ByteRanges(serialized: serialized).contains(offset..<(offset + Int64(length))) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL(videoId))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: length), data.count == length else { return nil }
            return data
        } catch {
            Log.warning("cache", "\(videoId): не прочитать кэш — забываю диапазоны (\(error.localizedDescription))")
            _ = try? database.writer.write { db in
                try db.execute(sql: "UPDATE audio_cache SET ranges = '', cached_bytes = 0, complete = 0 WHERE video_id = ?",
                               arguments: [videoId])
            }
            return nil
        }
    }

    /// Сколько байт подряд есть в кэше с `offset` (для ответа загрузчику без сети).
    public func available(_ videoId: String, from offset: Int64) -> Int64 {
        guard let entry = try? database.writer.read({ db in
            try String.fetchOne(db, sql: "SELECT ranges FROM audio_cache WHERE video_id = ?", arguments: [videoId])
        }) else { return 0 }
        return ByteRanges(serialized: entry).available(from: offset)
    }

    /// Прочитанное из сети — на диск; `total` — полная длина файла, если стала известна.
    public func write(_ videoId: String, offset: Int64, data: Data, total: Int64? = nil) {
        guard !data.isEmpty else { return }
        lock.lock()
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
            try database.writer.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT ranges, content_length FROM audio_cache WHERE video_id = ?",
                                                 arguments: [videoId]) else { return }
                var ranges = ByteRanges(serialized: row["ranges"] ?? "")
                ranges.insert(offset..<(offset + Int64(data.count)))
                let length: Int64? = total ?? row["content_length"]
                let complete = length.map { ranges.covers(length: $0) } ?? false
                try db.execute(sql: """
                    UPDATE audio_cache SET ranges = ?, cached_bytes = ?, complete = ?, content_length = COALESCE(content_length, ?),
                        last_read_at = ? WHERE video_id = ?
                    """, arguments: [ranges.serialized, ranges.totalBytes, complete, total, EpochMs.now(), videoId])
            }
        } catch {
            Log.error("cache", "\(videoId): запись в кэш не удалась: \(error.localizedDescription)")
        }
        lock.unlock()
        trim()
    }

    // MARK: - Место

    /// Эти треки не вытесняются: играющий и следующий.
    public func setProtected(_ videoIds: Set<String>) {
        lock.lock()
        protected = videoIds
        lock.unlock()
    }

    /// Сверх лимита — удалить треки, которые дольше всех не слушали (кроме защищённых).
    public func trim() {
        let max = limit()
        guard max > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let rows = try database.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT video_id, cached_bytes FROM audio_cache ORDER BY last_read_at ASC")
            }
            var total = rows.reduce(Int64(0)) { $0 + ($1["cached_bytes"] as Int64? ?? 0) }
            guard total > max else { return }
            for row in rows where total > max {
                let videoId: String = row["video_id"]
                if protected.contains(videoId) { continue }
                total -= row["cached_bytes"] as Int64? ?? 0
                removeLocked(videoId)
            }
        } catch {
            Log.error("cache", "Вытеснение не удалось: \(error.localizedDescription)")
        }
    }

    public func remove(_ videoId: String) {
        lock.lock()
        removeLocked(videoId)
        lock.unlock()
    }

    private func removeLocked(_ videoId: String) {
        try? FileManager.default.removeItem(at: fileURL(videoId))
        _ = try? database.writer.write { db in
            try db.execute(sql: "DELETE FROM audio_cache WHERE video_id = ?", arguments: [videoId])
        }
    }

    /// «Очистить кэш»: всё, кроме защищённых.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        let ids = (try? database.writer.read { db in try String.fetchAll(db, sql: "SELECT video_id FROM audio_cache") }) ?? []
        for videoId in ids where !protected.contains(videoId) { removeLocked(videoId) }
    }

    /// Занято кэшем, байт (по индексу).
    public func totalBytes() -> Int64 {
        (try? database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(cached_bytes), 0) FROM audio_cache")
        }) ?? 0
    }

    /// Сверка индекса с папкой при старте: лишние файлы удаляются, пропавшие забываются.
    public func reconcile() {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let ids = Set((try? database.writer.read { db in try String.fetchAll(db, sql: "SELECT video_id FROM audio_cache") }) ?? [])
        var onDisk = Set<String>()
        for file in files {
            let videoId = file.deletingPathExtension().lastPathComponent
            if file.pathExtension == "m4a", ids.contains(videoId) {
                onDisk.insert(videoId)
            } else {
                try? fm.removeItem(at: file)
            }
        }
        let missing = ids.subtracting(onDisk)
        if !missing.isEmpty {
            _ = try? database.writer.write { db in
                for videoId in missing {
                    try db.execute(sql: "DELETE FROM audio_cache WHERE video_id = ?", arguments: [videoId])
                }
            }
            Log.info("cache", "Сверка кэша: забыто \(missing.count) пропавших файлов")
        }
    }

    private static func fetchEntry(_ db: Database, _ videoId: String) throws -> AudioCacheEntry? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM audio_cache WHERE video_id = ?", arguments: [videoId]) else {
            return nil
        }
        return AudioCacheEntry(
            videoId: row["video_id"], itag: row["itag"], mimeType: row["mime_type"], contentLength: row["content_length"],
            durationMs: row["duration_ms"], loudnessDb: row["loudness_db"], cachedBytes: row["cached_bytes"],
            complete: row["complete"], lastReadAt: row["last_read_at"]
        )
    }
}
