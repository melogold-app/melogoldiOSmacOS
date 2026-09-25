import Foundation
import GRDB

/// Схема библиотеки и кэша (срезы 2 и 4). Имена — как у Windows (`src/Melogold.Core/Data/LibraryDatabase.cs`),
/// чего у Windows нет — по Android REWRITE §4.2 и §4.12a. Снимки синка (`sync_state`, `synced_*`) — в `SyncMigrations`.
enum LibraryMigrations {
    static let all: [DatabaseMigration] = [
        DatabaseMigration("library-v1") { db in
            try db.execute(sql: """
                CREATE TABLE tracks (
                    video_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    artists_text TEXT,
                    artists_json TEXT,
                    album_id TEXT,
                    album_title TEXT,
                    duration_ms INTEGER,
                    duration_text TEXT,
                    thumbnail_url TEXT,
                    explicit INTEGER NOT NULL DEFAULT 0,
                    video_type TEXT,
                    metadata_stub INTEGER NOT NULL DEFAULT 0,
                    liked_at INTEGER,
                    total_play_ms INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX tracks_liked ON tracks(liked_at) WHERE liked_at IS NOT NULL;

                CREATE TABLE albums (
                    browse_id TEXT PRIMARY KEY,
                    title TEXT,
                    artists_text TEXT,
                    year TEXT,
                    thumbnail_url TEXT,
                    playlist_id TEXT,
                    bookmarked_at INTEGER
                );

                CREATE TABLE artists (
                    browse_id TEXT PRIMARY KEY,
                    name TEXT,
                    thumbnail_url TEXT,
                    is_channel INTEGER NOT NULL DEFAULT 0,
                    bookmarked_at INTEGER
                );

                CREATE TABLE playlists (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sync_id TEXT UNIQUE,
                    name TEXT NOT NULL,
                    browse_id TEXT,
                    thumbnail_url TEXT,
                    created_at INTEGER NOT NULL
                );

                CREATE TABLE playlist_items (
                    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    video_id TEXT NOT NULL REFERENCES tracks(video_id),
                    position INTEGER NOT NULL,
                    sort_key TEXT,
                    added_at INTEGER NOT NULL,
                    PRIMARY KEY (playlist_id, video_id)
                );
                CREATE INDEX playlist_items_order ON playlist_items(playlist_id, position);

                -- Прослушивания. device_id — кто слушал (задание 0002); пусто — это устройство.
                CREATE TABLE play_events (
                    event_id TEXT PRIMARY KEY,
                    video_id TEXT NOT NULL,
                    played_at INTEGER NOT NULL,
                    play_time_ms INTEGER NOT NULL,
                    synced INTEGER NOT NULL DEFAULT 0,
                    device_id TEXT
                );
                CREATE INDEX play_events_time ON play_events(played_at);
                CREATE INDEX play_events_video ON play_events(video_id, played_at);

                CREATE TABLE search_history (
                    query TEXT PRIMARY KEY,
                    searched_at INTEGER NOT NULL
                );

                CREATE TABLE lyrics (
                    video_id TEXT PRIMARY KEY,
                    synced TEXT,
                    plain TEXT,
                    source TEXT,
                    fetched_at INTEGER NOT NULL,
                    plain_source TEXT,
                    offset_ms INTEGER NOT NULL DEFAULT 0,
                    language TEXT
                );

                CREATE TABLE content_blocks (
                    type TEXT NOT NULL,
                    key TEXT NOT NULL,
                    level TEXT NOT NULL,
                    title TEXT,
                    subtitle TEXT,
                    thumbnail_url TEXT,
                    blocked_at INTEGER NOT NULL,
                    PRIMARY KEY (type, key)
                );

                CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT);
                """)
        },
        DatabaseMigration("cache-v1") { db in
            // Кэш музыки (задание 0003): индекс того, что лежит в AudioCache/<videoId>.m4a. Ключ — videoId,
            // один формат на трек; диапазоны — «начало-конец,…» (конец не включается).
            try db.execute(sql: """
                CREATE TABLE audio_cache (
                    video_id TEXT PRIMARY KEY,
                    itag INTEGER NOT NULL,
                    mime_type TEXT NOT NULL,
                    content_length INTEGER,
                    duration_ms INTEGER,
                    loudness_db REAL,
                    ranges TEXT NOT NULL DEFAULT '',
                    cached_bytes INTEGER NOT NULL DEFAULT 0,
                    complete INTEGER NOT NULL DEFAULT 0,
                    last_read_at INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX audio_cache_lru ON audio_cache(last_read_at);
                """)
        },
    ]
}
