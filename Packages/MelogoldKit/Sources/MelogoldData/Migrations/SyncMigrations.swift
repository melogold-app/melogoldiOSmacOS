import Foundation
import GRDB

/// Снимки синка — срез 5 (вариант со снимком, REWRITE §4.12a Android). Имена и колонки — как у Windows
/// (`src/Melogold.Core/Data/LibraryDatabase.cs`, схемы 1–4). Миграции применяются после `LibraryMigrations`,
/// дописываются в конец списка.
enum SyncMigrations {
    static let all: [DatabaseMigration] = [
        DatabaseMigration("sync-v1") { db in
            try db.execute(sql: """
                -- Состояние синка: binding, cursor, needsMerge, historyMerge, historyRetryAt, lastSyncAt, lyricsRev.
                CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT);

                -- Что сервер знал после прошлой синхронизации: разница с библиотекой уходит ops.
                CREATE TABLE synced_likes (video_id TEXT PRIMARY KEY);
                CREATE TABLE synced_bookmarks (type TEXT NOT NULL, browse_id TEXT NOT NULL, PRIMARY KEY (type, browse_id));
                -- video_ids — треки плейлиста в порядке сервера, через перевод строки.
                CREATE TABLE synced_playlists (
                    sync_id TEXT PRIMARY KEY,
                    name TEXT,
                    thumbnail_url TEXT,
                    video_ids TEXT NOT NULL DEFAULT ''
                );
                -- Свои тексты на сервере (задание 0001): rev версии и SHA-256 содержимого; rev −1 — сервер отказал.
                CREATE TABLE synced_lyrics (video_id TEXT PRIMARY KEY, rev INTEGER NOT NULL, hash TEXT NOT NULL);

                -- «Убрать из истории» (history.forget) и «Очистить историю» (history.clear) для сервера (задание 0002).
                CREATE TABLE history_ops (op_id TEXT PRIMARY KEY, kind TEXT NOT NULL, video_id TEXT, events_before INTEGER NOT NULL);

                CREATE INDEX play_events_unsent ON play_events(played_at) WHERE synced = 0 AND device_id IS NULL;
                """)
        },
    ]
}
