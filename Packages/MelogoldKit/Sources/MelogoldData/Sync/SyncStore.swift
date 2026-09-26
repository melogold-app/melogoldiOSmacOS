import Foundation
import GRDB
import MelogoldCore
import Synchronization

// Записи синка (вариант со снимком, REWRITE §4.12a Android; Windows `SyncStore.cs`). Время — epoch-мс UTC.

/// Трек, как он лежит в `tracks`: метаданные для `tracks[]` op (API §4.8).
public struct SyncTrackRecord: Equatable, Sendable {
    public var videoId: String
    public var title: String
    public var artistsText: String?
    public var artists: [ArtistRef]
    public var albumId: String?
    public var albumTitle: String?
    public var durationMs: Int64?
    public var durationText: String?
    public var thumbnailUrl: String?
    public var explicit: Bool
    public var videoType: String?
    /// Метаданных нет: название — это `videoId`.
    public var metadataStub: Bool

    public init(
        videoId: String, title: String, artistsText: String? = nil, artists: [ArtistRef] = [], albumId: String? = nil,
        albumTitle: String? = nil, durationMs: Int64? = nil, durationText: String? = nil, thumbnailUrl: String? = nil,
        explicit: Bool = false, videoType: String? = nil, metadataStub: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.artistsText = artistsText
        self.artists = artists
        self.albumId = albumId
        self.albumTitle = albumTitle
        self.durationMs = durationMs
        self.durationText = durationText
        self.thumbnailUrl = thumbnailUrl
        self.explicit = explicit
        self.videoType = videoType
        self.metadataStub = metadataStub
    }

    public init(_ track: Track) {
        self.init(
            videoId: track.videoId, title: track.title, artistsText: track.artistsText, artists: track.artists,
            albumId: track.albumId, albumTitle: track.albumTitle, durationMs: track.durationMs,
            thumbnailUrl: track.thumbnailUrl, explicit: track.explicit, videoType: track.videoType
        )
    }
}

/// Лайк этого устройства: трек с метаданными и время лайка.
public struct SyncLikeRecord: Equatable, Sendable {
    public let track: SyncTrackRecord
    public let likedAt: Int64
}

/// Свой плейлист для синхронизации.
public struct SyncPlaylistRecord: Equatable, Sendable {
    public let id: Int64
    public let syncId: String?
    public let name: String
    public let browseId: String?
    public let thumbnailUrl: String?
}

/// Плейлист, каким его знал сервер после прошлой синхронизации: треки в порядке сервера.
public struct SyncedPlaylist: Equatable, Sendable {
    public let syncId: String
    public let name: String?
    public let thumbnailUrl: String?
    public let videoIds: [String]

    public init(syncId: String, name: String?, thumbnailUrl: String?, videoIds: [String]) {
        self.syncId = syncId
        self.name = name
        self.thumbnailUrl = thumbnailUrl
        self.videoIds = videoIds
    }
}

/// Трек плейлиста этого устройства: ключ порядка сервера, если сервер этот трек уже знает.
public struct SyncItemRecord: Equatable, Sendable {
    public let videoId: String
    public let sortKey: String?

    public init(videoId: String, sortKey: String?) {
        self.videoId = videoId
        self.sortKey = sortKey
    }
}

/// Ключ закладки: `album` или `artist` (исполнитель и канал).
public struct SyncBookmarkKey: Hashable, Sendable {
    public let type: String
    public let browseId: String

    public init(type: String, browseId: String) {
        self.type = type
        self.browseId = browseId
    }
}

/// Закладка этого устройства.
public struct SyncBookmarkRecord: Equatable, Sendable {
    public let key: SyncBookmarkKey
    public let bookmarkedAt: Int64
    public let title: String?
    public let subtitle: String?
    public let thumbnailUrl: String?
    public let year: String?
}

/// Прослушивание этого устройства, ещё не отправленное на сервер.
public struct SyncPlayRecord: Equatable, Sendable {
    public let eventId: String
    public let videoId: String
    public let playedAt: Int64
    public let playTimeMs: Int64
}

/// «Убрать из истории» (`history.forget`) или «Очистить историю» (`history.clear`) для сервера.
public struct SyncHistoryOpRecord: Equatable, Sendable {
    public let opId: String
    public let kind: String
    public let videoId: String?
    public let eventsBefore: Int64
}

/// Доступ синка к базе: состояние (`sync_state`), снимок сервера (`synced_*`), `sync_id` плейлистов и `sort_key` их
/// треков, история и свои тексты. Чтение-изменение-запись — одной транзакцией `write`; сети внутри транзакций нет.
/// Прослушивания и действия с историей пишет `Library` (задание 0002): отсюда — очередь её операций истории
/// (`queueHistoryOps(of:)`) и устройства прослушиваний для фильтра Истории.
public struct SyncStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Одна транзакция записи на очереди записи GRDB.
    public func write<T: Sendable>(_ work: @Sendable (SyncTx) throws -> T) async throws -> T {
        try await database.writer.write { db in try work(SyncTx(db: db)) }
    }

    /// Только чтение (записи в `work` падают).
    public func read<T: Sendable>(_ work: @Sendable (SyncTx) throws -> T) async throws -> T {
        try await database.writer.read { db in try work(SyncTx(db: db)) }
    }

    public func state(_ key: String) async throws -> String? {
        try await read { try $0.state(key) }
    }

    // MARK: - История (задание 0002)

    /// «Убрать из истории» и «Очистить историю» этой библиотеки ставят `history.forget` и `history.clear` в очередь
    /// `history_ops` той же транзакцией, что удаляет события (задание 0002 §3.4). Зовёт `LibrarySync`: его цикл их и
    /// отправляет. Очередь пишется и без аккаунта, как на Android и Windows: после выхода и входа в тот же аккаунт действие
    /// уходит. Первый вход или другой аккаунт (сервер) очередь сбрасывают (`SyncTx.forgetBinding`) — действие, сделанное
    /// до входа, историю нового аккаунта на других устройствах не трогает.
    public func queueHistoryOps(of library: Library) {
        assert(library.database === database, "Библиотека и синк — на одной базе")
        library.setHistoryOpRecorder { db, op in
            try SyncTx(db: db).enqueueHistoryOp(kind: op.kind, videoId: op.videoId, eventsBefore: op.eventsBefore)
        }
    }

    /// Устройства, чьи прослушивания лежат здесь (`play_events.device_id`); своих событий (`NULL`) среди них нет.
    /// Фильтр Истории виден, только когда список не пуст (задание 0002 §3.5).
    public func historyDeviceIds() async throws -> Set<String> {
        try await read { tx in
            Set(try String.fetchAll(tx.db, sql: "SELECT DISTINCT device_id FROM play_events WHERE device_id IS NOT NULL"))
        }
    }

    // MARK: - Правки библиотеки

    /// Таблицы и колонки, правка которых уходит на сервер: Избранное, плейлисты и их треки, закладки, свои тексты,
    /// новые прослушивания и действия с историей. Метаданные треков и снимки синка сюда не входят.
    static var observedRegion: [any DatabaseRegionConvertible] {
        [
            SQLRequest<Row>(sql: "SELECT video_id, liked_at FROM tracks"),
            SQLRequest<Row>(sql: "SELECT browse_id, bookmarked_at FROM albums"),
            SQLRequest<Row>(sql: "SELECT browse_id, bookmarked_at FROM artists"),
            SQLRequest<Row>(sql: "SELECT id, name, thumbnail_url, browse_id FROM playlists"),
            Table("playlist_items"),
            Table("lyrics"),
            Table("play_events"),
            Table("history_ops"),
        ]
    }

    /// Правки библиотеки, которые могут уйти на сервер (после commit, на очереди записи). Свои записи синка сюда тоже
    /// попадают: синк после них строит ops по снимку, находит ноль и в сеть не идёт, поэтому цикла нет.
    public func observeLocalChanges(_ onChange: @escaping @Sendable () -> Void) -> SyncObservation {
        let cancellable = DatabaseRegionObservation(tracking: Self.observedRegion).start(
            in: database.writer,
            onError: { error in Log.warning("sync", "Наблюдение за библиотекой: \(error)") },
            onChange: { _ in onChange() }
        )
        return SyncObservation(cancellable)
    }
}

/// Наблюдение за правками библиотеки; `cancel()` останавливает его.
public final class SyncObservation: Sendable {
    private let cancellable: Mutex<AnyDatabaseCancellable?>

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = Mutex(cancellable)
    }

    public func cancel() {
        cancellable.withLock { $0?.cancel(); $0 = nil }
    }

    deinit { cancel() }
}

/// Операции синка внутри одной транзакции.
public struct SyncTx {
    let db: Database

    private static let trackColumns = "video_id, title, artists_text, artists_json, album_id, album_title, duration_ms, duration_text, thumbnail_url, explicit, video_type, metadata_stub"
    private static let lyricsColumns = "synced, plain, source, plain_source, offset_ms, language"

    // MARK: - Состояние

    public func state(_ key: String) throws -> String? {
        try String.fetchOne(db.cachedStatement(sql: "SELECT value FROM sync_state WHERE key = ?"), arguments: [key])
    }

    public func setState(_ key: String, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key])
        }
    }

    /// Другой аккаунт или сервер (и первый вход): снимок, `sync_id`, `sort_key` и состояние забываются. Свои прослушивания
    /// примет новый аккаунт, чужие от прошлого удаляются (задание 0002 §3.7); «Убрать из истории» и «Очистить историю»,
    /// ещё не отправленные, — тоже: они про прошлый аккаунт или про историю до входа.
    public func forgetBinding() throws {
        try db.execute(sql: """
            DELETE FROM synced_likes;
            DELETE FROM synced_playlists;
            DELETE FROM synced_bookmarks;
            DELETE FROM synced_lyrics;
            UPDATE playlists SET sync_id = NULL WHERE sync_id IS NOT NULL;
            UPDATE playlist_items SET sort_key = NULL WHERE sort_key IS NOT NULL;
            UPDATE play_events SET synced = 0 WHERE device_id IS NULL AND synced <> 0;
            DELETE FROM play_events WHERE device_id IS NOT NULL;
            DELETE FROM history_ops;
            DELETE FROM sync_state;
            """)
    }

    /// Сервер восстановлен из копии (`410 cursor_invalid`, DESIGN §3.14 «Тихое слияние», §3.15 п. 6): снимок забыт,
    /// `sync_id` остаются. Библиотека уходит заново `import`/`set` без `base`, свои прослушивания — ещё раз (сервер узнаёт
    /// их по `eventId`), свои тексты — `PUT` (то же содержимое `rev` не меняет), тексты с сервера — с начала. Тексты,
    /// которые сервер отверг, остаются отвергнутыми.
    public func forgetServerCopy() throws {
        try db.execute(sql: """
            DELETE FROM synced_likes;
            DELETE FROM synced_playlists;
            DELETE FROM synced_bookmarks;
            DELETE FROM synced_lyrics WHERE rev <> ?;
            UPDATE playlist_items SET sort_key = NULL WHERE sort_key IS NOT NULL;
            UPDATE play_events SET synced = 0 WHERE device_id IS NULL AND synced <> 0;
            """, arguments: [LyricsSnapshot.rejected])
    }

    // MARK: - Треки

    public func track(_ videoId: String) throws -> SyncTrackRecord? {
        try Row.fetchOne(db.cachedStatement(sql: "SELECT \(Self.trackColumns) FROM tracks WHERE video_id = ?"), arguments: [videoId])
            .map(Self.readTrack)
    }

    private static func readTrack(_ row: Row) -> SyncTrackRecord {
        let json: String? = row["artists_json"]
        let artists = json.flatMap { try? JSONDecoder().decode([ArtistRef].self, from: Data($0.utf8)) } ?? []
        return SyncTrackRecord(
            videoId: row["video_id"], title: row["title"], artistsText: row["artists_text"], artists: artists,
            albumId: row["album_id"], albumTitle: row["album_title"], durationMs: row["duration_ms"],
            durationText: row["duration_text"], thumbnailUrl: row["thumbnail_url"], explicit: row["explicit"] ?? false,
            videoType: row["video_type"], metadataStub: row["metadata_stub"] ?? false
        )
    }

    /// Вставляет трек или дополняет метаданные: пустые поля новой версии не затирают известные, заглушка не затирает
    /// название (как `Library.UpsertTrack` Windows).
    public func upsertTrack(_ track: SyncTrackRecord) throws {
        let artistsJSON = track.artists.isEmpty ? nil : (try? JSONEncoder().encode(track.artists)).map { String(decoding: $0, as: UTF8.self) }
        try db.execute(
            sql: """
                INSERT INTO tracks (video_id, title, artists_text, artists_json, album_id, album_title, duration_ms, duration_text,
                                    thumbnail_url, explicit, video_type, metadata_stub, created_at)
                VALUES (:id, :title, :artists, :artistsJson, :albumId, :albumTitle, :durationMs, :durationText, :thumb, :explicit, :type, :stub, :now)
                ON CONFLICT(video_id) DO UPDATE SET
                    title = CASE WHEN :stub = 0 THEN excluded.title ELSE tracks.title END,
                    artists_text = COALESCE(excluded.artists_text, tracks.artists_text),
                    artists_json = COALESCE(excluded.artists_json, tracks.artists_json),
                    album_id = COALESCE(excluded.album_id, tracks.album_id),
                    album_title = COALESCE(excluded.album_title, tracks.album_title),
                    duration_ms = COALESCE(excluded.duration_ms, tracks.duration_ms),
                    duration_text = COALESCE(excluded.duration_text, tracks.duration_text),
                    thumbnail_url = COALESCE(excluded.thumbnail_url, tracks.thumbnail_url),
                    explicit = MAX(excluded.explicit, tracks.explicit),
                    video_type = COALESCE(tracks.video_type, excluded.video_type),
                    metadata_stub = CASE WHEN :stub = 0 THEN 0 ELSE tracks.metadata_stub END
                """,
            arguments: [
                "id": track.videoId, "title": track.title, "artists": track.artistsText, "artistsJson": artistsJSON,
                "albumId": track.albumId, "albumTitle": track.albumTitle,
                "durationMs": track.durationMs ?? Durations.parse(track.durationText),
                "durationText": track.durationText ?? track.durationMs.map { Durations.format($0) },
                "thumb": track.thumbnailUrl, "explicit": track.explicit, "type": track.videoType,
                "stub": track.metadataStub, "now": EpochMs.now(),
            ]
        )
    }

    /// Трек, о котором говорит сервер: новый — с его метаданными, без них — заглушка с названием `videoId`. Заглушка
    /// прошлой синхронизации узнаёт настоящее название; известные метаданные сервер не перезаписывает.
    public func ensureTrack(_ videoId: String, metadata: SyncTrackRecord?) throws {
        let existing = try Row.fetchOne(db.cachedStatement(sql: "SELECT title, metadata_stub FROM tracks WHERE video_id = ?"), arguments: [videoId])
        if let existing {
            let title: String = existing["title"]
            let stub: Bool = existing["metadata_stub"] ?? false
            if let metadata, stub || title == videoId, !metadata.title.isEmpty, metadata.title != videoId {
                try upsertTrack(metadata)
            }
            return
        }
        try upsertTrack(metadata ?? SyncTrackRecord(videoId: videoId, title: videoId, metadataStub: true))
    }

    // MARK: - Библиотека этого устройства

    public func likes() throws -> [SyncLikeRecord] {
        try Row.fetchAll(db, sql: "SELECT \(Self.trackColumns), liked_at FROM tracks WHERE liked_at IS NOT NULL ORDER BY liked_at, video_id")
            .map { SyncLikeRecord(track: Self.readTrack($0), likedAt: $0["liked_at"]) }
    }

    public func playlists() throws -> [SyncPlaylistRecord] {
        try Row.fetchAll(db, sql: "SELECT id, sync_id, name, browse_id, thumbnail_url FROM playlists ORDER BY created_at, id").map(Self.readPlaylist)
    }

    public func playlist(syncId: String) throws -> SyncPlaylistRecord? {
        try Row.fetchOne(db, sql: "SELECT id, sync_id, name, browse_id, thumbnail_url FROM playlists WHERE sync_id = ?", arguments: [syncId])
            .map(Self.readPlaylist)
    }

    private static func readPlaylist(_ row: Row) -> SyncPlaylistRecord {
        SyncPlaylistRecord(id: row["id"], syncId: row["sync_id"], name: row["name"], browseId: row["browse_id"], thumbnailUrl: row["thumbnail_url"])
    }

    /// Треки плейлиста в порядке этого устройства.
    public func playlistVideoIds(_ playlistId: Int64) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT video_id FROM playlist_items WHERE playlist_id = ? ORDER BY position, rowid", arguments: [playlistId])
    }

    /// Треки плейлиста в порядке этого устройства с ключами сервера.
    public func playlistItems(_ playlistId: Int64) throws -> [SyncItemRecord] {
        try Row.fetchAll(db, sql: "SELECT video_id, sort_key FROM playlist_items WHERE playlist_id = ? ORDER BY position, rowid", arguments: [playlistId])
            .map { SyncItemRecord(videoId: $0["video_id"], sortKey: $0["sort_key"]) }
    }

    public func playlist(id: Int64) throws -> SyncPlaylistRecord? {
        try Row.fetchOne(db, sql: "SELECT id, sync_id, name, browse_id, thumbnail_url FROM playlists WHERE id = ?", arguments: [id])
            .map(Self.readPlaylist)
    }

    public func playlistExists(_ playlistId: Int64) throws -> Bool {
        try playlist(id: playlistId) != nil
    }

    /// Время лайка этого устройства; `nil` — не лайкнут (или трека нет).
    public func likedAt(_ videoId: String) throws -> Int64? {
        try Int64.fetchOne(db.cachedStatement(sql: "SELECT liked_at FROM tracks WHERE video_id = ?"), arguments: [videoId])
    }

    /// Время закладки этого устройства; `nil` — закладки нет.
    public func bookmarkedAt(_ key: SyncBookmarkKey) throws -> Int64? {
        let table = key.type == "album" ? "albums" : "artists"
        return try Int64.fetchOne(db, sql: "SELECT bookmarked_at FROM \(table) WHERE browse_id = ?", arguments: [key.browseId])
    }

    public func bookmarks() throws -> [SyncBookmarkRecord] {
        let albums = try Row.fetchAll(db, sql: "SELECT browse_id, bookmarked_at, title, artists_text, thumbnail_url, year FROM albums WHERE bookmarked_at IS NOT NULL ORDER BY bookmarked_at")
            .map {
                SyncBookmarkRecord(key: SyncBookmarkKey(type: "album", browseId: $0["browse_id"]), bookmarkedAt: $0["bookmarked_at"],
                                   title: $0["title"], subtitle: $0["artists_text"], thumbnailUrl: $0["thumbnail_url"], year: $0["year"])
            }
        let artists = try Row.fetchAll(db, sql: "SELECT browse_id, bookmarked_at, name, thumbnail_url FROM artists WHERE bookmarked_at IS NOT NULL ORDER BY bookmarked_at")
            .map {
                SyncBookmarkRecord(key: SyncBookmarkKey(type: "artist", browseId: $0["browse_id"]), bookmarkedAt: $0["bookmarked_at"],
                                   title: $0["name"], subtitle: nil, thumbnailUrl: $0["thumbnail_url"], year: nil)
            }
        return albums + artists
    }

    public func setPlaylistSyncId(_ playlistId: Int64, _ syncId: String?) throws {
        try db.execute(sql: "UPDATE playlists SET sync_id = ? WHERE id = ?", arguments: [syncId, playlistId])
    }

    /// Треки плейлиста без ключа сервера: уйдут на сервер как новые (плейлист восстановления).
    public func clearSortKeys(_ playlistId: Int64) throws {
        try db.execute(sql: "UPDATE playlist_items SET sort_key = NULL WHERE playlist_id = ?", arguments: [playlistId])
    }

    // MARK: - Снимок

    public func syncedLikes() throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT video_id FROM synced_likes"))
    }

    public func syncedBookmarks() throws -> Set<SyncBookmarkKey> {
        Set(try Row.fetchAll(db, sql: "SELECT type, browse_id FROM synced_bookmarks").map { SyncBookmarkKey(type: $0["type"], browseId: $0["browse_id"]) })
    }

    public func syncedPlaylists() throws -> [String: SyncedPlaylist] {
        var result: [String: SyncedPlaylist] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT sync_id, name, thumbnail_url, video_ids FROM synced_playlists") {
            let playlist = Self.readSyncedPlaylist(row)
            result[playlist.syncId] = playlist
        }
        return result
    }

    public func syncedPlaylist(_ syncId: String) throws -> SyncedPlaylist? {
        try Row.fetchOne(db, sql: "SELECT sync_id, name, thumbnail_url, video_ids FROM synced_playlists WHERE sync_id = ?", arguments: [syncId])
            .map(Self.readSyncedPlaylist)
    }

    private static func readSyncedPlaylist(_ row: Row) -> SyncedPlaylist {
        let text: String = row["video_ids"] ?? ""
        return SyncedPlaylist(
            syncId: row["sync_id"], name: row["name"], thumbnailUrl: row["thumbnail_url"],
            videoIds: text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        )
    }

    public func upsertSyncedPlaylist(_ playlist: SyncedPlaylist) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO synced_playlists (sync_id, name, thumbnail_url, video_ids) VALUES (?, ?, ?, ?)",
            arguments: [playlist.syncId, playlist.name, playlist.thumbnailUrl, playlist.videoIds.joined(separator: "\n")]
        )
    }

    public func deleteSyncedPlaylist(_ syncId: String) throws {
        try db.execute(sql: "DELETE FROM synced_playlists WHERE sync_id = ?", arguments: [syncId])
    }

    // MARK: - Применение ответа сервера (API §4.8)

    @discardableResult
    public func insertPlaylist(name: String, browseId: String?, thumbnailUrl: String?, syncId: String, createdAt: Int64) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO playlists (sync_id, name, browse_id, thumbnail_url, created_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [syncId, name, browseId, thumbnailUrl, createdAt]
        )
        return db.lastInsertedRowID
    }

    public func updatePlaylist(_ id: Int64, name: String, thumbnailUrl: String?) throws {
        try db.execute(sql: "UPDATE playlists SET name = ?, thumbnail_url = ? WHERE id = ?", arguments: [name, thumbnailUrl, id])
    }

    public func deletePlaylist(_ id: Int64) throws {
        try db.execute(sql: "DELETE FROM playlist_items WHERE playlist_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
    }

    /// Трек плейлиста с ключом сервера; место выставит `reorder`. Трек должен уже быть в `tracks` (`ensureTrack`).
    public func upsertItem(_ playlistId: Int64, videoId: String, sortKey: String, addedAt: Int64) throws {
        try db.execute(
            sql: """
                INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (?, ?, 2147483647, ?, ?)
                ON CONFLICT(playlist_id, video_id) DO UPDATE SET sort_key = excluded.sort_key
                """,
            arguments: [playlistId, videoId, sortKey, addedAt]
        )
    }

    public func deleteItem(_ playlistId: Int64, videoId: String) throws {
        try db.execute(sql: "DELETE FROM playlist_items WHERE playlist_id = ? AND video_id = ?", arguments: [playlistId, videoId])
    }

    /// Треки с ключом сервера — в его порядке (ключ, затем `videoId`, побайтово), за ними треки без ключа, как стояли.
    /// В снимок попадают только треки с ключом: добавленное здесь и ещё не отправленное сервер не знает.
    public func reorder(_ playlistId: Int64) throws {
        let items = try Row.fetchAll(db, sql: "SELECT video_id, sort_key, position FROM playlist_items WHERE playlist_id = ? ORDER BY position, rowid", arguments: [playlistId])
            .map { (videoId: $0["video_id"] as String, sortKey: $0["sort_key"] as String?, position: $0["position"] as Int64) }
        let keyed = items.filter { $0.sortKey != nil }.sorted { lhs, rhs in
            let order = SortKeys.compare(lhs.sortKey ?? "", rhs.sortKey ?? "")
            return order != 0 ? order < 0 : SortKeys.precedes(lhs.videoId, rhs.videoId)
        }
        let ordered = keyed + items.filter { $0.sortKey == nil }
        let statement = try db.cachedStatement(sql: "UPDATE playlist_items SET position = ? WHERE playlist_id = ? AND video_id = ?")
        for (index, item) in ordered.enumerated() where item.position != Int64(index) {
            try statement.execute(arguments: [index, playlistId, item.videoId])
        }
        guard let playlist = try Row.fetchOne(db, sql: "SELECT sync_id, name, thumbnail_url FROM playlists WHERE id = ?", arguments: [playlistId]),
              let syncId: String = playlist["sync_id"] else { return }
        try upsertSyncedPlaylist(SyncedPlaylist(syncId: syncId, name: playlist["name"], thumbnailUrl: playlist["thumbnail_url"], videoIds: keyed.map(\.videoId)))
    }

    /// Места и ключи треков плейлиста — по порядку `items`; треки уже в плейлисте.
    public func placeItems(_ playlistId: Int64, _ items: [SyncItemRecord]) throws {
        let statement = try db.cachedStatement(sql: "UPDATE playlist_items SET position = ?, sort_key = ? WHERE playlist_id = ? AND video_id = ?")
        for (index, item) in items.enumerated() {
            try statement.execute(arguments: [index, item.sortKey, playlistId, item.videoId])
        }
    }

    /// Лайк с сервера: время лайка — серверное, снятый лайк — снятие. Трек должен уже быть в `tracks`.
    public func setLike(_ videoId: String, likedAt: Int64?) throws {
        try db.execute(sql: "UPDATE tracks SET liked_at = ? WHERE video_id = ?", arguments: [likedAt, videoId])
        try setSyncedLike(videoId, liked: likedAt != nil)
    }

    /// Только снимок: лайк на сервере, а здесь его правили, пока шёл запрос.
    public func setSyncedLike(_ videoId: String, liked: Bool) throws {
        if liked {
            try db.execute(sql: "INSERT OR IGNORE INTO synced_likes (video_id) VALUES (?)", arguments: [videoId])
        } else {
            try db.execute(sql: "DELETE FROM synced_likes WHERE video_id = ?", arguments: [videoId])
        }
    }

    /// Закладка с сервера: у новой — снимок названия и обложки.
    public func setBookmark(_ key: SyncBookmarkKey, bookmarkedAt: Int64?, title: String?, subtitle: String?, thumbnailUrl: String?, year: String?) throws {
        if key.type == "album" {
            if bookmarkedAt != nil {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO albums (browse_id, title, artists_text, year, thumbnail_url) VALUES (?, ?, ?, ?, ?)",
                    arguments: [key.browseId, title, subtitle, year, thumbnailUrl]
                )
            }
            try db.execute(sql: "UPDATE albums SET bookmarked_at = ? WHERE browse_id = ?", arguments: [bookmarkedAt, key.browseId])
        } else {
            if bookmarkedAt != nil {
                try db.execute(sql: "INSERT OR IGNORE INTO artists (browse_id, name, thumbnail_url) VALUES (?, ?, ?)", arguments: [key.browseId, title, thumbnailUrl])
            }
            try db.execute(sql: "UPDATE artists SET bookmarked_at = ? WHERE browse_id = ?", arguments: [bookmarkedAt, key.browseId])
        }
        try setSyncedBookmark(key, bookmarked: bookmarkedAt != nil)
    }

    /// Только снимок: закладка на сервере, а здесь её правили, пока шёл запрос.
    public func setSyncedBookmark(_ key: SyncBookmarkKey, bookmarked: Bool) throws {
        if bookmarked {
            try db.execute(sql: "INSERT OR IGNORE INTO synced_bookmarks (type, browse_id) VALUES (?, ?)", arguments: [key.type, key.browseId])
        } else {
            try db.execute(sql: "DELETE FROM synced_bookmarks WHERE type = ? AND browse_id = ?", arguments: [key.type, key.browseId])
        }
    }

    // MARK: - История (задание 0002)

    /// Свои прослушивания, которых сервер ещё не видел, по времени.
    public func unsentPlays() throws -> [SyncPlayRecord] {
        try Row.fetchAll(db, sql: "SELECT event_id, video_id, played_at, play_time_ms FROM play_events WHERE synced = 0 AND device_id IS NULL ORDER BY played_at, event_id")
            .map { SyncPlayRecord(eventId: $0["event_id"], videoId: $0["video_id"], playedAt: $0["played_at"], playTimeMs: $0["play_time_ms"]) }
    }

    public func markPlaySent(_ eventId: String) throws {
        try db.execute(sql: "UPDATE play_events SET synced = 1 WHERE event_id = ?", arguments: [eventId])
    }

    public func historyOps() throws -> [SyncHistoryOpRecord] {
        try Row.fetchAll(db, sql: "SELECT op_id, kind, video_id, events_before FROM history_ops ORDER BY events_before, rowid")
            .map { SyncHistoryOpRecord(opId: $0["op_id"], kind: $0["kind"], videoId: $0["video_id"], eventsBefore: $0["events_before"]) }
    }

    public func enqueueHistoryOp(kind: String, videoId: String?, eventsBefore: Int64) throws {
        try db.execute(
            sql: "INSERT INTO history_ops (op_id, kind, video_id, events_before) VALUES (?, ?, ?, ?)",
            arguments: [UUID().uuidString.lowercased(), kind, videoId, eventsBefore]
        )
    }

    public func deleteHistoryOp(_ opId: String) throws {
        try db.execute(sql: "DELETE FROM history_ops WHERE op_id = ?", arguments: [opId])
    }

    /// Накопленное время треков (для `play.baseline atLeast` при первой синхронизации).
    public func playTotals() throws -> [(videoId: String, totalMs: Int64)] {
        try Row.fetchAll(db, sql: "SELECT video_id, total_play_ms FROM tracks WHERE total_play_ms > 0 ORDER BY video_id")
            .map { (videoId: $0["video_id"], totalMs: $0["total_play_ms"]) }
    }

    /// Общее время трека с сервера (`playStats`): уже по всем устройствам. `atLeast` — не меньше здешнего: пока
    /// накопленное время не ушло `play.baseline atLeast`, здешнее — его источник.
    public func setPlayTotal(_ videoId: String, totalMs: Int64, atLeast: Bool = false) throws {
        let sql = atLeast
            ? "UPDATE tracks SET total_play_ms = MAX(total_play_ms, ?) WHERE video_id = ?"
            : "UPDATE tracks SET total_play_ms = ? WHERE video_id = ?"
        try db.execute(sql: sql, arguments: [totalMs, videoId])
    }

    /// Прослушивание с сервера: новое вставляется отправленным, своё вернувшееся (тот же `eventId`) не задваивается.
    public func insertPlay(eventId: String, videoId: String, playedAt: Int64, playTimeMs: Int64, deviceId: String?) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES (?, ?, ?, ?, 1, ?)",
            arguments: [eventId, videoId, playedAt, playTimeMs, deviceId]
        )
    }

    /// `playForgets`: события трека (или все при `*`) по `eventsBefore` включительно удалены.
    public func forgetPlays(_ videoId: String, eventsBefore: Int64) throws {
        if videoId == "*" {
            try db.execute(sql: "DELETE FROM play_events WHERE played_at <= ?", arguments: [eventsBefore])
        } else {
            try db.execute(sql: "DELETE FROM play_events WHERE video_id = ? AND played_at <= ?", arguments: [videoId, eventsBefore])
        }
    }

    // MARK: - Тексты (задание 0001)

    /// Свои тексты: хотя бы одна сторона из источника `user` или `file`.
    public func ownLyrics() throws -> [String: StoredLyrics] {
        var result: [String: StoredLyrics] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT video_id, \(Self.lyricsColumns) FROM lyrics
            WHERE (source IN ('user', 'file') AND COALESCE(synced, '') <> '') OR (plain_source IN ('user', 'file') AND COALESCE(plain, '') <> '')
            """) {
            result[row["video_id"]] = Self.readLyrics(row)
        }
        return result
    }

    public func lyrics(_ videoId: String) throws -> StoredLyrics? {
        try Row.fetchOne(db, sql: "SELECT \(Self.lyricsColumns) FROM lyrics WHERE video_id = ?", arguments: [videoId]).map(Self.readLyrics)
    }

    private static func readLyrics(_ row: Row) -> StoredLyrics {
        StoredLyrics(synced: row["synced"], plain: row["plain"], syncedSource: row["source"], plainSource: row["plain_source"],
                     offsetMs: row["offset_ms"] ?? 0, language: row["language"])
    }

    public func saveLyrics(_ videoId: String, _ lyrics: StoredLyrics) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [videoId, lyrics.synced, lyrics.plain, lyrics.syncedSource, lyrics.plainSource, lyrics.offsetMs, lyrics.language, EpochMs.now()]
        )
    }

    public func deleteLyrics(_ videoId: String) throws {
        try db.execute(sql: "DELETE FROM lyrics WHERE video_id = ?", arguments: [videoId])
    }

    /// Снимок своих версий на сервере.
    public func syncedLyrics() throws -> [String: LyricsSnapshot] {
        var result: [String: LyricsSnapshot] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT video_id, rev, hash FROM synced_lyrics") {
            result[row["video_id"]] = LyricsSnapshot(rev: row["rev"], hash: row["hash"])
        }
        return result
    }

    public func syncedLyrics(_ videoId: String) throws -> LyricsSnapshot? {
        try Row.fetchOne(db, sql: "SELECT rev, hash FROM synced_lyrics WHERE video_id = ?", arguments: [videoId])
            .map { LyricsSnapshot(rev: $0["rev"], hash: $0["hash"]) }
    }

    public func setSyncedLyrics(_ videoId: String, rev: Int64, hash: String) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO synced_lyrics (video_id, rev, hash) VALUES (?, ?, ?)", arguments: [videoId, rev, hash])
    }

    public func forgetSyncedLyrics(_ videoId: String) throws {
        try db.execute(sql: "DELETE FROM synced_lyrics WHERE video_id = ?", arguments: [videoId])
    }
}
