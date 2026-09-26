import Foundation
import GRDB
import MelogoldCore

/// Свой плейлист: `syncId` — UUID сервера, если плейлист синхронизирован; `browseId` — плейлист YouTube, с которым он
/// связан (REWRITE §3.8.1).
public struct LibraryPlaylist: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var syncId: String?
    public var name: String
    public var browseId: String?
    public var thumbnailUrl: String?
    public var createdAt: Int64
    public var trackCount: Int
    /// До четырёх обложек первых треков — мозаика.
    public var mosaic: [String]
    public var link: YouTubeLink
    public var linkSyncedAt: Int64?

    /// Связь с плейлистом YouTube: «Зеркало», «Только добавлять», отвязан; `unknown` — связь есть (`browseId`), а режим
    /// ведёт другое устройство.
    public enum YouTubeLink: String, Sendable {
        case none, mirror, append, off, unknown
    }
}

public struct HistoryEntry: Hashable, Sendable {
    public var track: Track
    public var playedAt: Int64
}

public struct TopEntry: Hashable, Sendable {
    public var track: Track
    public var playTimeMs: Int64
}

/// Трек «Всех треков»: когда слушали последний раз (`nil` — не слушали), сколько всего и когда лайкнули.
public struct AllTracksEntry: Hashable, Sendable {
    public var track: Track
    public var lastPlayedAt: Int64?
    public var playTimeMs: Int64
    public var likedAt: Int64?
}

/// Сортировка «Всех треков» (задание 0007, `sort.allTracks`).
public enum AllTracksSort: String, CaseIterable, Sendable {
    case recentlyPlayed, playTime, title, artist, duration
}

/// Сортировка Избранного (`sort.favorites`).
public enum FavoritesSort: String, CaseIterable, Sendable {
    case dateAdded, title, artist, duration
}

/// Что изменилось в библиотеке — экраны перечитывают своё.
public struct LibraryCounts: Hashable, Sendable {
    public var likes = 0
    public var playlists = 0
    public var albums = 0
    public var artists = 0
    public var allTracks = 0
    public var downloads = 0

    public init() {}
}

/// Библиотека на устройстве (порт `Library.cs` Windows): Избранное, закладки альбомов и исполнителей, свои плейлисты,
/// история, «Все треки», скрытые треки. Правки пишутся прямо в таблицы `library-v1` — синк замечает их сам
/// (наблюдение GRDB); «Очистить историю» и «Убрать из истории» дополнительно зовут `historyOp` в той же транзакции.
public final class Library: Sendable {
    public let database: AppDatabase

    /// Операция истории для сервера (`history.clear`, `history.forget`) — пишется синком в той же транзакции.
    public struct HistoryOp: Sendable {
        public var kind: String
        public var videoId: String?
        public var eventsBefore: Int64
    }

    private let historyOpBox = HistoryOpBox()

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Синк ставит сюда запись операции истории в свою очередь.
    public func setHistoryOpRecorder(_ recorder: (@Sendable (Database, HistoryOp) throws -> Void)?) {
        historyOpBox.set(recorder)
    }

    // MARK: - Треки

    static let trackColumns = "video_id, title, artists_text, artists_json, album_id, album_title, duration_ms, duration_text, thumbnail_url, explicit, video_type"

    static func columns(_ alias: String) -> String {
        trackColumns.split(separator: ",").map { "\(alias)." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
    }

    static func track(_ row: Row) -> Track {
        var artists: [ArtistRef] = []
        if let json: String = row["artists_json"], let data = json.data(using: .utf8) {
            artists = (try? JSONDecoder().decode([ArtistRef].self, from: data)) ?? []
        }
        let durationText: String? = row["duration_text"]
        return Track(
            videoId: row["video_id"], title: row["title"], artists: artists, artistsText: row["artists_text"],
            albumId: row["album_id"], albumTitle: row["album_title"],
            durationMs: row["duration_ms"] ?? Durations.parse(durationText), thumbnailUrl: row["thumbnail_url"],
            explicit: row["explicit"] ?? false, videoType: row["video_type"]
        )
    }

    /// Вставить трек или обновить метаданные: пустые поля новой версии не затирают известные.
    public static func upsert(_ db: Database, _ track: Track) throws {
        let artistsJSON = track.artists.isEmpty ? nil : (try? JSONEncoder().encode(track.artists)).flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(sql: """
            INSERT INTO tracks (video_id, title, artists_text, artists_json, album_id, album_title, duration_ms, duration_text,
                                thumbnail_url, explicit, video_type, metadata_stub, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(video_id) DO UPDATE SET
                title = CASE WHEN excluded.title <> excluded.video_id THEN excluded.title ELSE tracks.title END,
                artists_text = COALESCE(excluded.artists_text, tracks.artists_text),
                artists_json = COALESCE(excluded.artists_json, tracks.artists_json),
                album_id = COALESCE(excluded.album_id, tracks.album_id),
                album_title = COALESCE(excluded.album_title, tracks.album_title),
                duration_ms = COALESCE(excluded.duration_ms, tracks.duration_ms),
                duration_text = COALESCE(excluded.duration_text, tracks.duration_text),
                thumbnail_url = COALESCE(excluded.thumbnail_url, tracks.thumbnail_url),
                explicit = MAX(excluded.explicit, tracks.explicit),
                video_type = COALESCE(tracks.video_type, excluded.video_type),
                metadata_stub = CASE WHEN excluded.title <> excluded.video_id THEN 0 ELSE tracks.metadata_stub END
            """, arguments: [
                track.videoId, track.title, track.artistsText, artistsJSON, track.albumId, track.albumTitle, track.durationMs,
                track.durationMs.map(Durations.format), track.thumbnailUrl, track.explicit, track.videoType, EpochMs.now(),
            ])
    }

    public func save(_ tracks: [Track]) {
        write { db in for track in tracks { try Self.upsert(db, track) } }
    }

    public func track(_ videoId: String) -> Track? {
        read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.trackColumns) FROM tracks WHERE video_id = ?", arguments: [videoId]).map(Self.track)
        } ?? nil
    }

    private func tracks(_ sql: String, _ arguments: StatementArguments = []) -> [Track] {
        read { db in try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.track) } ?? []
    }

    // MARK: - Избранное

    public func likedIds() -> Set<String> {
        Set(read { db in try String.fetchAll(db, sql: "SELECT video_id FROM tracks WHERE liked_at IS NOT NULL") } ?? [])
    }

    public func isLiked(_ videoId: String) -> Bool {
        flag("SELECT liked_at IS NOT NULL FROM tracks WHERE video_id = ?", [videoId])
    }

    public func favorites(sort: FavoritesSort = .dateAdded) -> [Track] {
        let list = tracks("SELECT \(Self.trackColumns) FROM tracks WHERE liked_at IS NOT NULL ORDER BY liked_at DESC")
        switch sort {
        case .dateAdded: return list
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: return list.sorted { ($0.artistsText ?? "").localizedStandardCompare($1.artistsText ?? "") == .orderedAscending }
        case .duration: return list.sorted { ($0.durationMs ?? 0) > ($1.durationMs ?? 0) }
        }
    }

    public func setLiked(_ track: Track, _ liked: Bool) {
        write { db in
            try Self.upsert(db, track)
            if liked {
                try db.execute(sql: "UPDATE tracks SET liked_at = COALESCE(liked_at, ?) WHERE video_id = ?",
                               arguments: [EpochMs.now(), track.videoId])
            } else {
                try db.execute(sql: "UPDATE tracks SET liked_at = NULL WHERE video_id = ?", arguments: [track.videoId])
            }
        }
    }

    /// Вернуть время лайка (отмена «Убрать из Избранного»).
    public func restoreLike(_ videoId: String, at likedAt: Int64) {
        write { db in try db.execute(sql: "UPDATE tracks SET liked_at = ? WHERE video_id = ?", arguments: [likedAt, videoId]) }
    }

    public func likedAt(_ videoId: String) -> Int64? {
        read { db in try Int64.fetchOne(db, sql: "SELECT liked_at FROM tracks WHERE video_id = ?", arguments: [videoId]) } ?? nil
    }

    // MARK: - Альбомы и исполнители

    public func isAlbumSaved(_ browseId: String) -> Bool {
        flag("SELECT bookmarked_at IS NOT NULL FROM albums WHERE browse_id = ?", [browseId])
    }

    /// «Сохранить» альбом: закладка и треки альбома (альбом без сети и его загрузка, REWRITE §3.6).
    public func setAlbumSaved(_ album: AlbumItem, tracks: [Track], _ saved: Bool) {
        write { db in
            try Self.upsertAlbum(db, album, bookmarkedAt: saved ? EpochMs.now() : nil)
            if saved, !tracks.isEmpty {
                try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ?", arguments: [album.browseId])
                for (index, track) in tracks.enumerated() {
                    try Self.upsert(db, track)
                    try db.execute(sql: "INSERT OR REPLACE INTO album_tracks (album_id, video_id, position) VALUES (?, ?, ?)",
                                   arguments: [album.browseId, track.videoId, index])
                }
            }
        }
    }

    static func upsertAlbum(_ db: Database, _ album: AlbumItem, bookmarkedAt: Int64?) throws {
        try db.execute(sql: """
            INSERT INTO albums (browse_id, title, artists_text, year, thumbnail_url, playlist_id, bookmarked_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(browse_id) DO UPDATE SET
                title = COALESCE(excluded.title, albums.title),
                artists_text = COALESCE(excluded.artists_text, albums.artists_text),
                year = COALESCE(excluded.year, albums.year),
                thumbnail_url = COALESCE(excluded.thumbnail_url, albums.thumbnail_url),
                playlist_id = COALESCE(excluded.playlist_id, albums.playlist_id),
                bookmarked_at = CASE WHEN excluded.bookmarked_at IS NULL THEN NULL ELSE COALESCE(albums.bookmarked_at, excluded.bookmarked_at) END
            """, arguments: [album.browseId, album.title, album.artistsText, album.year, album.thumbnailUrl, album.playlistId, bookmarkedAt])
    }

    public func savedAlbums() -> [AlbumItem] {
        read { db in
            try Row.fetchAll(db, sql: """
                SELECT browse_id, title, artists_text, year, thumbnail_url, playlist_id FROM albums
                WHERE bookmarked_at IS NOT NULL ORDER BY bookmarked_at DESC
                """).map { row in
                AlbumItem(browseId: row["browse_id"], title: row["title"] ?? row["browse_id"], artistsText: row["artists_text"],
                          year: row["year"], thumbnailUrl: row["thumbnail_url"], playlistId: row["playlist_id"])
            }
        } ?? []
    }

    /// Треки сохранённого альбома — страница альбома без сети.
    public func albumTracks(_ browseId: String) -> [Track] {
        tracks("SELECT \(Self.columns("t")) FROM album_tracks a JOIN tracks t ON t.video_id = a.video_id WHERE a.album_id = ? ORDER BY a.position",
               [browseId])
    }

    public func savedAlbum(_ browseId: String) -> AlbumItem? {
        savedAlbums().first { $0.browseId == browseId }
    }

    public func isArtistSaved(_ browseId: String) -> Bool {
        flag("SELECT bookmarked_at IS NOT NULL FROM artists WHERE browse_id = ?", [browseId])
    }

    /// «Подписаться» на исполнителя или канал — закладка `Artist(UC…)` (REWRITE §3.7.2).
    public func setArtistSaved(_ artist: ArtistItem, _ saved: Bool) {
        write { db in
            try db.execute(sql: """
                INSERT INTO artists (browse_id, name, thumbnail_url, is_channel, bookmarked_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(browse_id) DO UPDATE SET
                    name = COALESCE(excluded.name, artists.name),
                    thumbnail_url = COALESCE(excluded.thumbnail_url, artists.thumbnail_url),
                    is_channel = excluded.is_channel,
                    bookmarked_at = CASE WHEN excluded.bookmarked_at IS NULL THEN NULL ELSE COALESCE(artists.bookmarked_at, excluded.bookmarked_at) END
                """, arguments: [artist.browseId, artist.name, artist.thumbnailUrl, artist.isChannel, saved ? EpochMs.now() : nil])
        }
    }

    public func savedArtists() -> [ArtistItem] {
        read { db in
            try Row.fetchAll(db, sql: """
                SELECT browse_id, name, thumbnail_url, is_channel FROM artists WHERE bookmarked_at IS NOT NULL ORDER BY bookmarked_at DESC
                """).map { row in
                ArtistItem(browseId: row["browse_id"], name: row["name"] ?? row["browse_id"], thumbnailUrl: row["thumbnail_url"],
                           isChannel: row["is_channel"] ?? false)
            }
        } ?? []
    }

    /// Лайкнутые треки исполнителя — «В вашей библиотеке» на его странице (REWRITE §3.7.1).
    public func likedTracks(ofArtist browseId: String, name: String) -> [Track] {
        favorites().filter { track in
            track.artists.contains { $0.id == browseId } || (track.artists.allSatisfy { $0.id == nil } && track.artistsText == name)
        }
    }

    // MARK: - Плейлисты

    public func playlists() -> [LibraryPlaylist] {
        read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.sync_id, p.name, p.browse_id, p.thumbnail_url, p.created_at, p.yt_link_mode, p.yt_synced_at,
                       (SELECT COUNT(*) FROM playlist_items i WHERE i.playlist_id = p.id) AS count
                FROM playlists p ORDER BY p.created_at DESC, p.id DESC
                """)
            return try rows.map { row in
                let id: Int64 = row["id"]
                let mosaic = try String.fetchAll(db, sql: """
                    SELECT t.thumbnail_url FROM playlist_items i JOIN tracks t ON t.video_id = i.video_id
                    WHERE i.playlist_id = ? AND t.thumbnail_url IS NOT NULL ORDER BY i.position LIMIT 4
                    """, arguments: [id])
                let browseId: String? = row["browse_id"]
                let mode: String? = row["yt_link_mode"]
                let link: LibraryPlaylist.YouTubeLink = mode.flatMap(LibraryPlaylist.YouTubeLink.init(rawValue:))
                    ?? (browseId == nil ? .none : .unknown)
                return LibraryPlaylist(
                    id: id, syncId: row["sync_id"], name: row["name"], browseId: browseId, thumbnailUrl: row["thumbnail_url"],
                    createdAt: row["created_at"], trackCount: row["count"], mosaic: mosaic, link: link, linkSyncedAt: row["yt_synced_at"]
                )
            }
        } ?? []
    }

    public func playlist(_ id: Int64) -> LibraryPlaylist? {
        playlists().first { $0.id == id }
    }

    /// Свой плейлист, связанный с этим плейлистом YouTube (`VL…` без префикса или с ним).
    public func playlist(browseId: String) -> LibraryPlaylist? {
        let bare = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        return playlists().first { $0.browseId == bare || $0.browseId == "VL" + bare }
    }

    public func playlistTracks(_ id: Int64) -> [Track] {
        tracks("SELECT \(Self.columns("t")) FROM playlist_items i JOIN tracks t ON t.video_id = i.video_id WHERE i.playlist_id = ? ORDER BY i.position",
               [id])
    }

    /// Новый плейлист; название обрезается до 200 символов (API §1.4). Возвращает id.
    @discardableResult
    public func createPlaylist(name: String, tracks: [Track] = [], browseId: String? = nil, thumbnailUrl: String? = nil,
                               link: LibraryPlaylist.YouTubeLink? = nil) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Self.truncate(trimmed.isEmpty ? "Playlist" : trimmed, 200)
        return try? database.writer.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO playlists (name, browse_id, thumbnail_url, created_at, yt_link_mode, yt_synced_at, yt_snapshot)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    title, browseId, thumbnailUrl, EpochMs.now(), link?.rawValue, link == nil ? nil : EpochMs.now(),
                    link == nil ? nil : Self.snapshot(tracks.map(\.videoId)),
                ])
            let id = db.lastInsertedRowID
            try Self.append(db, id, tracks)
            return id
        }
    }

    public func renamePlaylist(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write { db in try db.execute(sql: "UPDATE playlists SET name = ? WHERE id = ?", arguments: [Self.truncate(trimmed, 200), id]) }
    }

    public func deletePlaylist(_ id: Int64) {
        write { db in
            try db.execute(sql: "DELETE FROM playlist_items WHERE playlist_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM download_collections WHERE kind = 'playlist' AND key = ?", arguments: [String(id)])
            try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
        }
    }

    /// Добавить в конец; трек встречается в плейлисте не больше одного раза. Возвращает число добавленных.
    @discardableResult
    public func add(_ tracks: [Track], toPlaylist id: Int64) -> Int {
        (try? database.writer.write { db in try Self.append(db, id, tracks) }) ?? 0
    }

    private static func append(_ db: Database, _ playlistId: Int64, _ tracks: [Track]) throws -> Int {
        var next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_items WHERE playlist_id = ?",
                                    arguments: [playlistId]) ?? 0
        var added = 0
        let now = EpochMs.now()
        for track in tracks {
            try upsert(db, track)
            try db.execute(sql: "INSERT OR IGNORE INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (?, ?, ?, ?)",
                           arguments: [playlistId, track.videoId, next, now])
            if db.changesCount > 0 {
                added += 1
                next += 1
            }
        }
        return added
    }

    /// Убрать трек; возвращает прежнюю позицию (для «Отменить»).
    @discardableResult
    public func remove(_ videoId: String, fromPlaylist id: Int64) -> Int? {
        try? database.writer.write { db -> Int? in
            let position = try Int.fetchOne(db, sql: "SELECT position FROM playlist_items WHERE playlist_id = ? AND video_id = ?",
                                            arguments: [id, videoId])
            try db.execute(sql: "DELETE FROM playlist_items WHERE playlist_id = ? AND video_id = ?", arguments: [id, videoId])
            try Self.renumber(db, id)
            return position
        } ?? nil
    }

    /// Вставить трек на место `index` (0…n) — отмена «Убрать из плейлиста».
    public func insert(_ track: Track, intoPlaylist id: Int64, at index: Int) {
        write { db in
            try Self.upsert(db, track)
            var order = try Self.videoIds(db, id)
            guard !order.contains(track.videoId) else { return }
            order.insert(track.videoId, at: min(max(0, index), order.count))
            try db.execute(sql: "INSERT OR IGNORE INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (?, ?, ?, ?)",
                           arguments: [id, track.videoId, order.count, EpochMs.now()])
            try Self.setOrder(db, id, order)
        }
    }

    /// Перенести трек на место `newIndex` (0…n−1).
    public func move(_ videoId: String, inPlaylist id: Int64, to newIndex: Int) {
        write { db in
            var order = try Self.videoIds(db, id)
            guard let from = order.firstIndex(of: videoId) else { return }
            order.remove(at: from)
            order.insert(videoId, at: min(max(0, newIndex), order.count))
            try Self.setOrder(db, id, order)
        }
    }

    /// Порядок целиком — «Обновить из YouTube» и перестановка.
    public func setTracks(_ tracks: [Track], ofPlaylist id: Int64) {
        write { db in
            let keep = Set(tracks.map(\.videoId))
            for videoId in try Self.videoIds(db, id) where !keep.contains(videoId) {
                try db.execute(sql: "DELETE FROM playlist_items WHERE playlist_id = ? AND video_id = ?", arguments: [id, videoId])
            }
            _ = try Self.append(db, id, tracks)
            try Self.setOrder(db, id, tracks.map(\.videoId))
        }
    }

    public func playlistsContaining(_ videoId: String) -> Set<Int64> {
        Set(read { db in try Int64.fetchAll(db, sql: "SELECT playlist_id FROM playlist_items WHERE video_id = ?", arguments: [videoId]) } ?? [])
    }

    static func videoIds(_ db: Database, _ id: Int64) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT video_id FROM playlist_items WHERE playlist_id = ? ORDER BY position", arguments: [id])
    }

    private static func renumber(_ db: Database, _ id: Int64) throws {
        try setOrder(db, id, videoIds(db, id))
    }

    private static func setOrder(_ db: Database, _ id: Int64, _ order: [String]) throws {
        for (index, videoId) in order.enumerated() {
            try db.execute(sql: "UPDATE playlist_items SET position = ? WHERE playlist_id = ? AND video_id = ?", arguments: [index, id, videoId])
        }
    }

    // MARK: - Связь с YouTube (REWRITE §3.8.1)

    public func setLink(_ mode: LibraryPlaylist.YouTubeLink, ofPlaylist id: Int64) {
        write { db in
            try db.execute(sql: "UPDATE playlists SET yt_link_mode = ? WHERE id = ?", arguments: [mode == .none ? nil : mode.rawValue, id])
        }
    }

    /// Снимок списка YouTube на момент последнего обновления («Только добавлять» добавляет только новое).
    public func linkSnapshot(ofPlaylist id: Int64) -> [String]? {
        guard let text = read({ db in try String.fetchOne(db, sql: "SELECT yt_snapshot FROM playlists WHERE id = ?", arguments: [id]) }) ?? nil
        else { return nil }
        return text.isEmpty ? [] : text.split(separator: "\n").map(String.init)
    }

    /// Обновление из YouTube: применяется только полный список (все продолжения получены).
    /// «Зеркало» — список как на YouTube; «Только добавлять» — новые в конец. Без снимка «Только добавлять» только
    /// запоминает список. Возвращает число добавленных (`nil` — запомнили без добавления).
    @discardableResult
    public func applyYouTube(_ remote: [Track], toPlaylist id: Int64, mode: LibraryPlaylist.YouTubeLink) -> Int? {
        guard let playlist = playlist(id) else { return 0 }
        let snapshot = linkSnapshot(ofPlaylist: id)
        var result: Int? = 0
        switch mode {
        case .mirror:
            setTracks(remote, ofPlaylist: id)
            result = max(0, remote.count - playlist.trackCount)
        case .append:
            if let snapshot {
                let known = Set(snapshot)
                result = add(remote.filter { !known.contains($0.videoId) }, toPlaylist: id)
            } else {
                result = nil
            }
        default:
            return 0
        }
        write { db in
            try db.execute(sql: "UPDATE playlists SET yt_snapshot = ?, yt_synced_at = ? WHERE id = ?",
                           arguments: [Self.snapshot(remote.map(\.videoId)), EpochMs.now(), id])
        }
        return result
    }

    private static func snapshot(_ ids: [String]) -> String { ids.joined(separator: "\n") }

    // MARK: - История (REWRITE §3.2.4, Windows DESIGN §3.11)

    /// Прослушивание (сеанс ≥ 5 с): трек, событие с UUID и счётчик времени — одной транзакцией.
    public func recordPlay(_ track: Track, playTimeMs: Int64, endedAt: Int64 = EpochMs.now()) {
        guard playTimeMs >= 5000 else { return }
        write { db in
            try Self.upsert(db, track)
            try db.execute(sql: "INSERT INTO play_events (event_id, video_id, played_at, play_time_ms) VALUES (?, ?, ?, ?)",
                           arguments: [UUID().uuidString.lowercased(), track.videoId, endedAt, playTimeMs])
            try db.execute(sql: "UPDATE tracks SET total_play_ms = total_play_ms + ? WHERE video_id = ?", arguments: [playTimeMs, track.videoId])
        }
    }

    /// «Недавние»: разные треки по последнему прослушиванию.
    public func recentHistory(limit: Int = 500) -> [HistoryEntry] {
        read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns("t")), h.last FROM (
                    SELECT video_id, MAX(played_at) AS last FROM play_events GROUP BY video_id ORDER BY last DESC LIMIT ?
                ) h JOIN tracks t ON t.video_id = h.video_id ORDER BY h.last DESC
                """, arguments: [limit]).map { HistoryEntry(track: Self.track($0), playedAt: $0["last"]) }
        } ?? []
    }

    /// «Чаще всего» за период (`since` — epoch-мс; `nil` — всё время: общее время трека).
    public func mostPlayed(since: Int64?, limit: Int = 100) -> [TopEntry] {
        read { db in
            let sql = since == nil
                ? "SELECT \(Self.trackColumns), total_play_ms AS total FROM tracks WHERE total_play_ms > 0 ORDER BY total_play_ms DESC LIMIT ?"
                : """
                  SELECT \(Self.columns("t")), s.total FROM (
                      SELECT video_id, SUM(play_time_ms) AS total FROM play_events WHERE played_at >= ? GROUP BY video_id ORDER BY total DESC LIMIT ?
                  ) s JOIN tracks t ON t.video_id = s.video_id ORDER BY s.total DESC
                  """
            let arguments: StatementArguments = since.map { [$0, limit] } ?? [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { TopEntry(track: Self.track($0), playTimeMs: $0["total"]) }
        } ?? []
    }

    public func playCount() -> Int {
        (read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_events") } ?? nil) ?? 0
    }

    /// «Очистить историю»: события удаляются, общее время треков остаётся (как в ViTune).
    public func clearHistory() {
        let now = EpochMs.now()
        write { db in
            try db.execute(sql: "DELETE FROM play_events WHERE played_at <= ?", arguments: [now])
            try historyOpBox.record(db, HistoryOp(kind: "history.clear", videoId: nil, eventsBefore: now))
        }
    }

    /// «Убрать из истории»: события трека удаляются, общее время остаётся.
    public func removeFromHistory(_ videoId: String) {
        let now = EpochMs.now()
        write { db in
            try db.execute(sql: "DELETE FROM play_events WHERE video_id = ? AND played_at <= ?", arguments: [videoId, now])
            try historyOpBox.record(db, HistoryOp(kind: "history.forget", videoId: videoId, eventsBefore: now))
        }
    }

    /// Затравки «Для вас» (REWRITE §4.10.5): последний лайк, самый частый за 30 дней, последний прослушанный.
    public func forYouSeeds() -> [Track] {
        var seeds: [Track] = []
        if let liked = favorites().first { seeds.append(liked) }
        if let top = mostPlayed(since: EpochMs.now() - 30 * 24 * 3600 * 1000, limit: 1).first { seeds.append(top.track) }
        if let recent = recentHistory(limit: 1).first { seeds.append(recent.track) }
        var seen = Set<String>()
        return seeds.filter { seen.insert($0.videoId).inserted }
    }

    // MARK: - «Все треки» (задание 0007)

    /// Прослушанное, лайкнутое, лежащее в своих плейлистах и скачанное; кроме скрытого. Треки альбомов, которые только
    /// открывали, не входят.
    private static let allTracksWhere = """
        (p.video_id IS NOT NULL OR t.total_play_ms > 0 OR t.liked_at IS NOT NULL
         OR EXISTS (SELECT 1 FROM playlist_items i WHERE i.video_id = t.video_id)
         OR EXISTS (SELECT 1 FROM downloads d WHERE d.video_id = t.video_id AND d.state = 'completed'))
        AND NOT EXISTS (SELECT 1 FROM content_blocks b WHERE b.type = 'track' AND b.level = 'hide' AND b.key = t.video_id)
        """

    public func allTracks(sort: AllTracksSort = .recentlyPlayed) -> [AllTracksEntry] {
        let list = read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns("t")), t.total_play_ms, t.liked_at, p.last FROM tracks t
                LEFT JOIN (SELECT video_id, MAX(played_at) AS last FROM play_events GROUP BY video_id) p ON p.video_id = t.video_id
                WHERE \(Self.allTracksWhere)
                ORDER BY COALESCE(p.last, t.liked_at, 0) DESC
                """).map { row in
                AllTracksEntry(track: Self.track(row), lastPlayedAt: row["last"], playTimeMs: row["total_play_ms"], likedAt: row["liked_at"])
            }
        } ?? []
        switch sort {
        case .recentlyPlayed: return list
        case .playTime: return list.sorted { $0.playTimeMs > $1.playTimeMs }
        case .title: return list.sorted { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        case .artist:
            return list.sorted { ($0.track.artistsText ?? "").localizedStandardCompare($1.track.artistsText ?? "") == .orderedAscending }
        case .duration: return list.sorted { ($0.track.durationMs ?? 0) > ($1.track.durationMs ?? 0) }
        }
    }

    public func counts() -> LibraryCounts {
        read { db in
            var counts = LibraryCounts()
            counts.likes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE liked_at IS NOT NULL") ?? 0
            counts.playlists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlists") ?? 0
            counts.albums = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE bookmarked_at IS NOT NULL") ?? 0
            counts.artists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artists WHERE bookmarked_at IS NOT NULL") ?? 0
            counts.allTracks = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks t
                LEFT JOIN (SELECT DISTINCT video_id FROM play_events) p ON p.video_id = t.video_id
                WHERE \(Self.allTracksWhere)
                """) ?? 0
            counts.downloads = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloads WHERE state = 'completed'") ?? 0
            return counts
        } ?? LibraryCounts()
    }

    /// «В библиотеке» при вводе в Поиске: свои треки по названию и исполнителю.
    public func search(_ query: String, limit: Int = 5) -> [Track] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !text.isEmpty else { return [] }
        let pattern = "%\(text)%"
        return tracks("""
            SELECT \(Self.trackColumns) FROM tracks
            WHERE (liked_at IS NOT NULL OR total_play_ms > 0 OR video_id IN (SELECT video_id FROM playlist_items))
              AND (title LIKE ? OR artists_text LIKE ?)
            ORDER BY liked_at IS NULL, total_play_ms DESC LIMIT ?
            """, [pattern, pattern, limit])
    }

    // MARK: - «Не показывать этот трек»

    /// «Не показывать этот трек» (`hide`): исключается из радио, автовоспроизведения и «Для вас», в списке пропускается.
    public func hiddenIds() -> Set<String> {
        Set(read { db in try String.fetchAll(db, sql: "SELECT key FROM content_blocks WHERE type = 'track' AND level = 'hide'") } ?? [])
    }

    /// «Не интересно» (`not_interested`, REWRITE §4.10.7): только рекомендации — радио, автовоспроизведение, «Для вас».
    public func notInterestedIds() -> Set<String> {
        Set(read { db in
            try String.fetchAll(db, sql: "SELECT key FROM content_blocks WHERE type = 'track' AND level = 'not_interested'")
        } ?? [])
    }

    public func setNotInterested(_ track: Track, _ on: Bool) {
        write { db in
            if on {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO content_blocks (type, key, level, title, subtitle, thumbnail_url, blocked_at)
                    VALUES ('track', ?, 'not_interested', ?, ?, ?, ?)
                    """, arguments: [track.videoId, track.title, track.artistsText, track.thumbnailUrl, EpochMs.now()])
            } else {
                try db.execute(sql: "DELETE FROM content_blocks WHERE type = 'track' AND key = ? AND level = 'not_interested'",
                               arguments: [track.videoId])
            }
        }
    }

    public func setHidden(_ track: Track, _ hidden: Bool) {
        write { db in
            if hidden {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO content_blocks (type, key, level, title, subtitle, thumbnail_url, blocked_at)
                    VALUES ('track', ?, 'hide', ?, ?, ?, ?)
                    """, arguments: [track.videoId, track.title, track.artistsText, track.thumbnailUrl, EpochMs.now()])
            } else {
                try db.execute(sql: "DELETE FROM content_blocks WHERE type = 'track' AND key = ?", arguments: [track.videoId])
            }
        }
    }

    public func hiddenTracks() -> [Track] {
        read { db in
            try Row.fetchAll(db, sql: "SELECT key, title, subtitle, thumbnail_url FROM content_blocks WHERE type = 'track' AND level = 'hide' ORDER BY blocked_at DESC")
                .map { Track(videoId: $0["key"], title: $0["title"] ?? $0["key"], artistsText: $0["subtitle"], thumbnailUrl: $0["thumbnail_url"]) }
        } ?? []
    }

    // MARK: - Состояние

    public func state(_ key: String) -> String? {
        read { db in try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [key]) } ?? nil
    }

    public func setState(_ key: String, _ value: String?) {
        write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - Служебное

    private func read<T>(_ work: (Database) throws -> T) -> T? {
        do {
            return try database.writer.read(work)
        } catch {
            Log.error("library", "Чтение: \(error.localizedDescription)")
            return nil
        }
    }

    private func flag(_ sql: String, _ arguments: StatementArguments) -> Bool {
        (read { db in try Bool.fetchOne(db, sql: sql, arguments: arguments) } ?? nil) ?? false
    }

    private func write(_ work: (Database) throws -> Void) {
        do {
            try database.writer.write(work)
        } catch {
            Log.error("library", "Запись: \(error.localizedDescription)")
        }
    }

    /// Обрезка по UTF-16 (API §1.4), суррогатная пара не рвётся.
    static func truncate(_ text: String, _ limit: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > limit else { return text }
        var end = limit
        if UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        return String(decoding: units[..<end], as: UTF16.self)
    }
}

/// Хук записи операций истории; ставит его синк.
private final class HistoryOpBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: (@Sendable (Database, Library.HistoryOp) throws -> Void)?

    func set(_ value: (@Sendable (Database, Library.HistoryOp) throws -> Void)?) {
        lock.withLock { recorder = value }
    }

    func record(_ db: Database, _ op: Library.HistoryOp) throws {
        let current = lock.withLock { recorder }
        try current?(db, op)
    }
}

/// Наблюдение за таблицами библиотеки и загрузок: любая правка — своя, синка или загрузчика — зовёт обработчик после
/// коммита. Держите объект, пока нужно наблюдение.
public final class LibraryObservation: @unchecked Sendable {
    private var cancellables: [AnyDatabaseCancellable] = []

    public init(database: AppDatabase, library: @escaping @Sendable () -> Void, downloads: @escaping @Sendable () -> Void) {
        let writer = database.writer
        let libraryRegion = DatabaseRegionObservation(tracking: [
            Table("tracks"), Table("albums"), Table("artists"), Table("playlists"), Table("playlist_items"),
            Table("play_events"), Table("content_blocks"), Table("album_tracks"), Table("download_collections"),
        ])
        cancellables.append(libraryRegion.start(in: writer, onError: { error in
            Log.error("library", "Наблюдение: \(error.localizedDescription)")
        }, onChange: { _ in library() }))
        let downloadRegion = DatabaseRegionObservation(tracking: [Table("downloads")])
        cancellables.append(downloadRegion.start(in: writer, onError: { _ in }, onChange: { _ in downloads() }))
    }

    public func cancel() {
        for cancellable in cancellables { cancellable.cancel() }
        cancellables = []
    }
}
