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
        DatabaseMigration("sync-v2") { db in
            // Фильтр Истории по устройствам (задание 0002 §3.5): «Недавние», «Чаще всего» и число прослушиваний
            // устройства — по индексу без чтения строк таблицы, устройства прослушиваний — без полного прохода
            try db.execute(sql: """
                CREATE INDEX play_events_device ON play_events(device_id, video_id, played_at, play_time_ms);
                """)
        },
        DatabaseMigration("lyrics-chosen-v1") { db in
            // Выбранный текст (задание 0011): выбор в «Найти текст» и версия с сервера — свой текст с любым источником
            // (`lrclib`, `kugou`, `youtube_music`), он уходит на сервер и не стирается. Тексты в таблице сохраняются;
            // версии, которые сервер уже знает (снимок `synced_lyrics`), а здесь лежат как найденные, — прежние сборки
            // принимали такие с сервера несвоими и удаляли с него следующей отправкой — становятся выбранными.
            try db.execute(sql: """
                ALTER TABLE lyrics ADD COLUMN chosen INTEGER NOT NULL DEFAULT 0;

                UPDATE lyrics SET chosen = 1
                WHERE video_id IN (SELECT video_id FROM synced_lyrics WHERE rev >= 0)
                  AND (COALESCE(synced, '') <> '' OR COALESCE(plain, '') <> '')
                  AND COALESCE(source, '') NOT IN ('user', 'file')
                  AND COALESCE(plain_source, '') NOT IN ('user', 'file');
                """)
        },
        DatabaseMigration("overrides-pins-v1") { db in
            // Своё название трека (задание 0014) и закреплённый текст (задание 0015) и их снимки синка
            // (`track.override.set`, `lyrics.pin.set`, API §4.8). Время — epoch-мс.
            try db.execute(sql: """
                CREATE TABLE track_overrides (
                    video_id TEXT PRIMARY KEY,
                    title TEXT,
                    artists_text TEXT,
                    album_title TEXT,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE lyrics_pins (
                    video_id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    ref TEXT NOT NULL,
                    start_time_ms INTEGER,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE synced_overrides (video_id TEXT PRIMARY KEY, title TEXT, artists_text TEXT, album_title TEXT);
                CREATE TABLE synced_lyrics_pins (video_id TEXT PRIMARY KEY, source TEXT NOT NULL, ref TEXT NOT NULL, start_time_ms INTEGER);
                """)
        },
        DatabaseMigration("lyrics-refs-v1") { db in
            // Ссылка на найденный текст у поставщика (задание 0015): номер записи LrcLib, browseId текста YouTube Music
            // (`MPLYt…`), `<id>:<accesskey>` KuGou — отдельно у синхронной и обычной стороны. Из неё строится закрепление.
            try db.execute(sql: """
                ALTER TABLE lyrics ADD COLUMN synced_ref TEXT;
                ALTER TABLE lyrics ADD COLUMN plain_ref TEXT;
                """)
        },
    ]
}
