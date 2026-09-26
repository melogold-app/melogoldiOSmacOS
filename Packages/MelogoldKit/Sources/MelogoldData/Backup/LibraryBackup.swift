import Foundation
import GRDB
import MelogoldCore

/// «Сохранить копию» (spec/backup-format.md §4, как Windows `LibraryBackup`): своя схема переводится в формат копии
/// Melogold — те же таблицы, что у ViTune и ViMusic, плюс колонки Melogold и метка `MelogoldBackup`. Копию открывает
/// Melogold на Android, Windows и Apple. В копию не входят настройки, вход в аккаунт, состояние синка, кэш и загрузки;
/// из текстов — только свои (`user`, `file`).
public enum LibraryBackup {
    /// `user_version` копии Windows и Apple (Android пишет версию своей базы Room).
    public static let formatUserVersion = 31

    /// `Melogold_backup_ггггММддЧЧммсс.db`, как у Android и Windows.
    public static func suggestedName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Melogold_backup_\(formatter.string(from: now)).db"
    }

    /// Таблицы копии (§2): имена и колонки с учётом регистра.
    static let schema = """
        CREATE TABLE Song (id TEXT PRIMARY KEY, title TEXT NOT NULL, artistsText TEXT, durationText TEXT, thumbnailUrl TEXT,
            likedAt INTEGER, totalPlayTimeMs INTEGER NOT NULL DEFAULT 0, blacklisted INTEGER NOT NULL DEFAULT 0, explicit INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE Event (id INTEGER PRIMARY KEY, songId TEXT NOT NULL, timestamp INTEGER NOT NULL, playTime INTEGER NOT NULL,
            syncId TEXT, deviceId TEXT);
        CREATE TABLE Lyrics (songId TEXT PRIMARY KEY, fixed TEXT, synced TEXT, startTime INTEGER, fixedSource TEXT, syncedSource TEXT);
        CREATE TABLE Album (id TEXT PRIMARY KEY, title TEXT, thumbnailUrl TEXT, year TEXT, authorsText TEXT, shareUrl TEXT,
            timestamp INTEGER, bookmarkedAt INTEGER);
        CREATE TABLE Artist (id TEXT PRIMARY KEY, name TEXT, thumbnailUrl TEXT, timestamp INTEGER, bookmarkedAt INTEGER);
        CREATE TABLE SongAlbumMap (songId TEXT NOT NULL, albumId TEXT NOT NULL, position INTEGER, PRIMARY KEY (songId, albumId));
        CREATE TABLE SongArtistMap (songId TEXT NOT NULL, artistId TEXT NOT NULL, PRIMARY KEY (songId, artistId));
        CREATE TABLE Playlist (id INTEGER PRIMARY KEY, name TEXT NOT NULL, browseId TEXT, thumbnail TEXT, syncId TEXT);
        CREATE TABLE SongPlaylistMap (songId TEXT NOT NULL, playlistId INTEGER NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (songId, playlistId));
        CREATE TABLE SearchQuery (id INTEGER PRIMARY KEY, query TEXT NOT NULL);
        CREATE TABLE MelogoldBackup (key TEXT PRIMARY KEY, value TEXT);
        """

    /// Источник текста словом API §4.10 → словом копии (как у ViTune и Android).
    private static func sourceToBackup(_ column: String) -> String {
        "CASE \(column) WHEN 'user' THEN 'User' WHEN 'file' THEN 'File' WHEN 'youtube_music' THEN 'YouTubeMusic' "
            + "WHEN 'lrclib' THEN 'LrcLib' WHEN 'kugou' THEN 'KuGou' ELSE NULL END"
    }

    /// Копия базы `source` (своя схема) в `target`. Все таблицы читаются в одной транзакции — снимок цельный, даже если
    /// библиотека в это время пишется; файл сначала пишется рядом под временным именем и потом переименовывается.
    public static func export(databaseAt source: URL, to target: URL, platform: String, appVersion: String, now: Date = Date()) throws {
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).tmp")
        try? fm.removeItem(at: temp)
        defer { try? fm.removeItem(at: temp) }
        do {
            let copy = try DatabaseQueue(path: temp.path)
            try copy.writeWithoutTransaction { db in
                try db.execute(sql: schema)
                try db.execute(sql: "ATTACH DATABASE ? AS src", arguments: [source.path])
                try db.inTransaction {
                    try fill(db)
                    let marks: [(String, String)] = [
                        ("format", "1"), ("platform", platform), ("appVersion", appVersion),
                        ("createdAt", createdAt(now)),
                    ]
                    for (key, value) in marks {
                        try db.execute(sql: "INSERT INTO MelogoldBackup (key, value) VALUES (?, ?)", arguments: [key, value])
                    }
                    return .commit
                }
                try db.execute(sql: "DETACH DATABASE src")
                try db.execute(sql: "PRAGMA user_version = \(formatUserVersion)")
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            try copy.close()
        }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
    }

    /// ISO 8601 UTC с миллисекундами: `2026-09-26T06:40:00.000Z`.
    static func createdAt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Перевод таблиц по §4. Колонки, которых нет в старой схеме, читаются как NULL.
    private static func fill(_ db: Database) throws {
        func has(_ table: String, _ column: String) throws -> Bool {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info(?, 'src') WHERE name = ?", arguments: [table, column]) ?? 0 > 0
        }
        func tableExists(_ table: String) throws -> Bool {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM src.sqlite_master WHERE type = 'table' AND name = ?", arguments: [table]) ?? 0 > 0
        }
        let device = try has("play_events", "device_id") ? "device_id" : "NULL"
        let offset = try has("lyrics", "offset_ms") ? "offset_ms" : "NULL"
        let plainSource = try has("lyrics", "plain_source") ? "plain_source" : "NULL"
        let blocks = try tableExists("content_blocks")
            ? "EXISTS (SELECT 1 FROM src.content_blocks b WHERE b.type = 'track' AND b.key = t.video_id)" : "0"
        let searches = try tableExists("search_history")
        try db.execute(sql: """
            INSERT INTO Song (id, title, artistsText, durationText, thumbnailUrl, likedAt, totalPlayTimeMs, blacklisted, explicit)
            SELECT t.video_id, t.title, t.artists_text,
                   COALESCE(t.duration_text, CASE WHEN t.duration_ms IS NOT NULL THEN (t.duration_ms / 60000) || ':' || printf('%02d', (t.duration_ms / 1000) % 60) END),
                   t.thumbnail_url, t.liked_at, t.total_play_ms, \(blocks), t.explicit
            FROM src.tracks t;
            INSERT INTO Event (songId, timestamp, playTime, syncId, deviceId)
            SELECT video_id, played_at, play_time_ms, event_id, \(device) FROM src.play_events ORDER BY played_at;
            INSERT INTO Lyrics (songId, fixed, synced, startTime, fixedSource, syncedSource)
            SELECT video_id, NULLIF(plain, ''), NULLIF(synced, ''),
                   CASE WHEN COALESCE(\(offset), 0) = 0 THEN NULL ELSE -\(offset) END,
                   CASE WHEN NULLIF(plain, '') IS NULL THEN NULL ELSE \(sourceToBackup(plainSource)) END,
                   CASE WHEN NULLIF(synced, '') IS NULL THEN NULL ELSE \(sourceToBackup("source")) END
            FROM src.lyrics
            WHERE (COALESCE(source, '') IN ('user', 'file') AND NULLIF(synced, '') IS NOT NULL)
               OR (COALESCE(\(plainSource), '') IN ('user', 'file') AND NULLIF(plain, '') IS NOT NULL);
            INSERT INTO Album (id, title, thumbnailUrl, year, authorsText, timestamp, bookmarkedAt)
            SELECT browse_id, title, thumbnail_url, year, artists_text, bookmarked_at, bookmarked_at FROM src.albums;
            INSERT INTO Artist (id, name, thumbnailUrl, timestamp, bookmarkedAt)
            SELECT browse_id, name, thumbnail_url, bookmarked_at, bookmarked_at FROM src.artists;
            INSERT OR IGNORE INTO SongAlbumMap (songId, albumId, position)
            SELECT video_id, album_id, NULL FROM src.tracks WHERE album_id IN (SELECT id FROM Album);
            INSERT OR IGNORE INTO SongArtistMap (songId, artistId)
            SELECT t.video_id, json_extract(j.value, '$.id') FROM src.tracks t, json_each(t.artists_json) j
            WHERE t.artists_json IS NOT NULL AND json_valid(t.artists_json) AND json_extract(j.value, '$.id') IN (SELECT id FROM Artist);
            INSERT INTO Playlist (id, name, browseId, thumbnail, syncId)
            SELECT id, name, browse_id, thumbnail_url, sync_id FROM src.playlists;
            INSERT INTO SongPlaylistMap (songId, playlistId, position)
            SELECT video_id, playlist_id, position FROM src.playlist_items;
            """)
        if searches {
            try db.execute(sql: "INSERT INTO SearchQuery (query) SELECT query FROM src.search_history ORDER BY searched_at")
        }
    }
}
