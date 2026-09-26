import Foundation
import GRDB
import MelogoldCore

/// Что принёс импорт (spec/backup-format.md §3.4) — для итога.
public struct ImportSummary: Equatable, Sendable {
    public var version: Int
    public var tracks: Int
    public var plays: Int
    public var playsKnown: Int
    public var favorites: Int
    public var lyrics: Int
    public var playlists: Int
    public var saved: Int
    public var localSkipped: Int
    public var datesSkipped: Int
}

/// Почему копию не удалось импортировать.
public enum ImportFailure: Error, Equatable, Sendable {
    case notABackup
    case tooOld
    /// InnerTune, Metrolist и родня: другие таблицы.
    case unsupported
    case unreadable
}

/// «Импорт копии» (spec/backup-format.md §3, эталон — Android `LegacyImporter`, порт Windows `LibraryImport`): копия
/// ViTune, ViMusic, их форков или Melogold любой платформы **добавляется** к библиотеке — здесь ничего не заменяется
/// и не удаляется.
///
/// - Файл копируется во временную папку и читается там, по колонкам, которые у него есть; оригинал не трогается.
/// - Одна транзакция: сбой посередине не меняет ничего.
/// - Треки: новые добавляются; у известных — самый ранний лайк, наибольшее время, недостающие поля.
/// - Прослушивания: тот же трек в тот же момент — один раз; id — из копии или `ImportIds`, поэтому одна копия на двух
///   устройствах не удваивает историю на сервере. С `deviceId` — уже на сервере (отправлены), без — свои `play.add`.
/// - Тексты заполняют только пустые стороны; плейлист находит свой по id сервера, ссылке YouTube или имени.
/// - Локальные файлы и невозможные даты не переносятся.
/// - Копия базы своей схемы (старая копия Windows) сначала переводится в формат копии.
public enum LibraryImport {
    static let minVersion = 12
    static let maxPlayTimeMs: Int64 = 86_400_000
    static let searchQueries = 200
    static let nameMax = 200
    /// Даты вне [2000-01-01, 2100-01-01) отбрасываются: сервер их не примет.
    static let saneDates: Range<Int64> = 946_684_800_000 ..< 4_102_444_800_000

    /// Импорт копии `file` в библиотеку `database`.
    public static func run(_ file: URL, into database: AppDatabase, appVersion: String = "") throws -> ImportSummary {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("melogold-import-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        var copy = directory.appendingPathComponent("backup.db")
        do {
            try fm.copyItem(at: file, to: copy)
        } catch {
            throw ImportFailure.unreadable
        }
        guard isSQLite(copy) else { throw ImportFailure.notABackup }

        var version: Int
        var tables: Set<String>
        do {
            let queue = try open(copy)
            (version, tables) = try queue.read { db in
                (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
                 Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")))
            }
            try queue.close()
        } catch {
            throw ImportFailure.unreadable
        }
        // Копия своей схемы (старая копия Windows): перевести в формат копии и читать его
        if !tables.contains("Song"), tables.contains("tracks"), tables.contains("play_events") {
            let converted = directory.appendingPathComponent("converted.db")
            do {
                try LibraryBackup.export(databaseAt: copy, to: converted, platform: "converted", appVersion: appVersion)
            } catch {
                throw ImportFailure.unreadable
            }
            copy = converted
            version = LibraryBackup.formatUserVersion
            tables.insert("Song")
        }
        guard tables.contains("Song") else { throw tables.contains("song") ? ImportFailure.unsupported : ImportFailure.notABackup }
        if (1 ..< minVersion).contains(version) { throw ImportFailure.tooOld }

        let bundle: Bundle
        do {
            let queue = try open(copy)
            bundle = try queue.read { db in try Reader(db, tables: tables).read() }
            try queue.close()
        } catch {
            throw ImportFailure.unreadable
        }
        return try database.writer.write { db in try merge(db, bundle, version: version) }
    }

    private static func open(_ url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        // Своя копия: из WAL в один файл
        try queue.writeWithoutTransaction { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") }
        return queue
    }

    static func isSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return false }
        return header.prefix(15) == Data("SQLite format 3".utf8) && header.last == 0
    }

    /// Правило имён плана слияния сервера (API §4.7): NFKC, без краевых пробелов, пробелы схлопнуты, нижний регистр.
    static func norm(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }

    static func isVideoId(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// Источник, как его пишут копии (имена ViTune и Android или слова API §4.10) → слово API.
    static func sourceFromBackup(_ source: String?) -> String? {
        switch source {
        case "User", "user": LyricsSources.user
        case "File", "file": LyricsSources.file
        case "YouTubeMusic", "youtube_music": LyricsSources.youtubeMusic
        case "LrcLib", "lrclib": LyricsSources.lrclib
        case "KuGou", "kugou": LyricsSources.kugou
        default: nil
        }
    }

    // MARK: - Чтение копии

    struct Song {
        var id: String
        var title: String
        var artistsText: String?
        var durationText: String?
        var thumbnailUrl: String?
        var likedAt: Int64?
        var totalPlayTimeMs: Int64
        var blacklisted: Bool
        var explicit: Bool
    }

    struct Event {
        var songId: String
        var timestamp: Int64
        var playTime: Int64
        var syncId: String?
        var deviceId: String?
    }

    struct Lyrics {
        var songId: String
        var fixed: String?
        var synced: String?
        var startTime: Int64?
        var fixedSource: String?
        var syncedSource: String?
    }

    struct Album {
        var id: String
        var title: String?
        var thumbnailUrl: String?
        var year: String?
        var authorsText: String?
        var bookmarkedAt: Int64?
    }

    struct Artist {
        var id: String
        var name: String?
        var thumbnailUrl: String?
        var bookmarkedAt: Int64?
    }

    struct Playlist {
        var name: String
        var browseId: String?
        var thumbnail: String?
        var syncId: String?
        var songIds: [String]
    }

    struct Bundle {
        var songs: [Song] = []
        var localSkipped = 0
        var events: [Event] = []
        var lyrics: [Lyrics] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var songAlbums: [(songId: String, albumId: String)] = []
        var songArtists: [(songId: String, artistId: String)] = []
        var playlists: [Playlist] = []
        var searches: [String] = []
    }

    /// Таблицы копии по колонкам, которые у неё есть; недостающие читаются как NULL. Значения странного типа
    /// (текст вместо числа и наоборот) приводятся, а не роняют чтение.
    struct Reader {
        let db: Database
        let tables: Set<String>

        init(_ db: Database, tables: Set<String>) {
            self.db = db
            self.tables = tables
        }

        struct Values {
            let row: Row
            func string(_ name: String) -> String? {
                switch (row[name] as DatabaseValue).storage {
                case .null: nil
                case .int64(let value): String(value)
                case .double(let value): String(value)
                case .string(let value): value
                case .blob(let data): String(data: data, encoding: .utf8)
                }
            }

            func long(_ name: String) -> Int64? {
                switch (row[name] as DatabaseValue).storage {
                case .null: nil
                case .int64(let value): value
                case .double(let value): value.isFinite ? Int64(value) : nil
                case .string(let value): Int64(value.trimmingCharacters(in: .whitespaces))
                case .blob: nil
                }
            }
        }

        private func select<T>(_ table: String, _ wanted: [String], orderBy: String? = nil, _ read: (Values) -> T?) throws -> [T] {
            guard tables.contains(table) else { return [] }
            let have = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")").map { $0["name"] as String })
            let list = wanted.map { have.contains($0) ? "\"\($0)\"" : "NULL AS \"\($0)\"" }.joined(separator: ", ")
            let order = orderBy.map { " ORDER BY \($0)" } ?? ""
            let cursor = try Row.fetchCursor(db, sql: "SELECT \(list) FROM \"\(table)\"\(order)")
            var result: [T] = []
            while let row = try cursor.next() {
                if let item = read(Values(row: row)) { result.append(item) }
            }
            return result
        }

        func read() throws -> Bundle {
            var bundle = Bundle()
            var localSkipped = 0
            bundle.songs = try select("Song", ["id", "title", "artistsText", "durationText", "thumbnailUrl", "likedAt", "totalPlayTimeMs",
                                               "blacklisted", "explicit"]) { row in
                guard let id = row.string("id") else { return nil }
                guard isVideoId(id) else {
                    localSkipped += 1
                    return nil
                }
                let title = row.string("title").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? id
                return Song(id: id, title: title, artistsText: row.string("artistsText"), durationText: row.string("durationText"),
                            thumbnailUrl: row.string("thumbnailUrl"), likedAt: row.long("likedAt").flatMap { $0 > 0 ? $0 : nil },
                            totalPlayTimeMs: max(0, row.long("totalPlayTimeMs") ?? 0), blacklisted: row.long("blacklisted") == 1,
                            explicit: row.long("explicit") == 1)
            }
            bundle.localSkipped = localSkipped
            bundle.events = try select("Event", ["songId", "timestamp", "playTime", "syncId", "deviceId"], orderBy: "timestamp") { row in
                guard let song = row.string("songId"), let at = row.long("timestamp") else { return nil }
                return Event(songId: song, timestamp: at, playTime: min(max(row.long("playTime") ?? 0, 1), maxPlayTimeMs),
                             syncId: row.string("syncId"), deviceId: row.string("deviceId"))
            }
            bundle.lyrics = try select("Lyrics", ["songId", "fixed", "synced", "startTime", "fixedSource", "syncedSource"]) { row in
                guard let song = row.string("songId") else { return nil }
                let fixed = row.string("fixed").flatMap { $0.isEmpty ? nil : $0 }
                let synced = row.string("synced").flatMap { $0.isEmpty ? nil : $0 }
                guard fixed != nil || synced != nil else { return nil }
                return Lyrics(songId: song, fixed: fixed, synced: synced, startTime: row.long("startTime"),
                              fixedSource: fixed == nil ? nil : sourceFromBackup(row.string("fixedSource")),
                              syncedSource: synced == nil ? nil : sourceFromBackup(row.string("syncedSource")))
            }
            bundle.albums = try select("Album", ["id", "title", "thumbnailUrl", "year", "authorsText", "bookmarkedAt"]) { row in
                row.string("id").map {
                    Album(id: $0, title: row.string("title"), thumbnailUrl: row.string("thumbnailUrl"), year: row.string("year"),
                          authorsText: row.string("authorsText"), bookmarkedAt: row.long("bookmarkedAt"))
                }
            }
            bundle.artists = try select("Artist", ["id", "name", "thumbnailUrl", "bookmarkedAt"]) { row in
                row.string("id").map {
                    Artist(id: $0, name: row.string("name"), thumbnailUrl: row.string("thumbnailUrl"), bookmarkedAt: row.long("bookmarkedAt"))
                }
            }
            bundle.songAlbums = try select("SongAlbumMap", ["songId", "albumId"]) { row in
                guard let song = row.string("songId"), let album = row.string("albumId") else { return nil }
                return (songId: song, albumId: album)
            }
            bundle.songArtists = try select("SongArtistMap", ["songId", "artistId"]) { row in
                guard let song = row.string("songId"), let artist = row.string("artistId") else { return nil }
                return (songId: song, artistId: artist)
            }
            // ViMusic v11 называл связь с плейлистом SongInPlaylist
            let mapTable = tables.contains("SongPlaylistMap") ? "SongPlaylistMap" : "SongInPlaylist"
            var items: [Int64: [String]] = [:]
            for (playlist, song) in try select(mapTable, ["songId", "playlistId", "position"], orderBy: "position, rowid", { row -> (Int64, String)? in
                guard let playlist = row.long("playlistId"), let song = row.string("songId") else { return nil }
                return (playlist, song)
            }) where !(items[playlist]?.contains(song) ?? false) {
                items[playlist, default: []].append(song)
            }
            bundle.playlists = try select("Playlist", ["id", "name", "browseId", "thumbnail", "syncId"], orderBy: "rowid") { row in
                guard let id = row.long("id") else { return nil }
                return Playlist(name: row.string("name") ?? "", browseId: row.string("browseId"), thumbnail: row.string("thumbnail"),
                                syncId: row.string("syncId"), songIds: items[id] ?? [])
            }
            bundle.searches = Array(try select("SearchQuery", ["query"], orderBy: "rowid DESC") { $0.string("query") }.prefix(searchQueries))
            return bundle
        }
    }

    // MARK: - Слияние

    static func merge(_ db: Database, _ bundle: Bundle, version: Int) throws -> ImportSummary {
        let now = EpochMs.now()
        var tracks = 0, favorites = 0, datesSkipped = 0
        var known = Set<String>()
        // Треки, которые библиотека показывает: прослушанные, в Избранном, в плейлистах. ViTune хранит и треки всех
        // открытых альбомов — они приходят (страницы альбомов, тексты), но в итог не входят: их нигде не найти
        let shown = Set(bundle.events.map(\.songId) + bundle.playlists.flatMap(\.songIds))
        var visible = Set<String>()

        for song in bundle.songs {
            let likedAt = song.likedAt.flatMap { saneDates.contains($0) ? $0 : nil }
            if song.likedAt != nil && likedAt == nil { datesSkipped += 1 }
            if shown.contains(song.id) || likedAt != nil || song.totalPlayTimeMs > 0 { visible.insert(song.id) }
            let local = try Row.fetchOne(db, sql: "SELECT liked_at FROM tracks WHERE video_id = ?", arguments: [song.id])
            let durationMs = Durations.parse(song.durationText)
            if local == nil {
                try db.execute(sql: """
                    INSERT INTO tracks (video_id, title, artists_text, duration_ms, duration_text, thumbnail_url, explicit, metadata_stub,
                                        liked_at, total_play_ms, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [song.id, song.title, song.artistsText, durationMs, song.durationText, song.thumbnailUrl, song.explicit,
                                     song.title == song.id, likedAt, song.totalPlayTimeMs, now])
                if visible.contains(song.id) { tracks += 1 }
                if likedAt != nil { favorites += 1 }
            } else {
                // Заглушка, названная своим id, узнаёт настоящее название; пустые поля заполняются
                try db.execute(sql: """
                    UPDATE tracks SET
                        metadata_stub = CASE WHEN title = video_id AND :title <> video_id THEN 0 ELSE metadata_stub END,
                        title = CASE WHEN title = video_id AND :title <> video_id THEN :title ELSE title END,
                        artists_text = COALESCE(artists_text, :artists),
                        duration_text = COALESCE(duration_text, :text),
                        duration_ms = COALESCE(duration_ms, :ms),
                        thumbnail_url = COALESCE(thumbnail_url, :thumb),
                        liked_at = CASE WHEN liked_at IS NULL THEN :liked WHEN :liked IS NULL THEN liked_at ELSE MIN(liked_at, :liked) END,
                        total_play_ms = MAX(total_play_ms, :total),
                        explicit = MAX(explicit, :explicit)
                    WHERE video_id = :id
                    """, arguments: ["title": song.title, "artists": song.artistsText, "text": song.durationText, "ms": durationMs,
                                     "thumb": song.thumbnailUrl, "liked": likedAt, "total": song.totalPlayTimeMs, "explicit": song.explicit,
                                     "id": song.id])
                if (local?["liked_at"] as Int64?) == nil && likedAt != nil { favorites += 1 }
            }
            if song.blacklisted {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO content_blocks (type, key, level, title, subtitle, thumbnail_url, blocked_at)
                    VALUES ('track', ?, 'hide', ?, ?, ?, ?)
                    """, arguments: [song.id, song.title, song.artistsText, song.thumbnailUrl, now])
            }
            known.insert(song.id)
        }
        func isTrack(_ id: String) throws -> Bool {
            if known.contains(id) { return true }
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM tracks WHERE video_id = ?", arguments: [id]) != nil else { return false }
            known.insert(id)
            return true
        }

        // Альбомы и исполнители: недостающие добавляются, закладка — самая ранняя
        var saved = 0
        for album in bundle.albums {
            try db.execute(sql: "INSERT OR IGNORE INTO albums (browse_id, title, artists_text, year, thumbnail_url) VALUES (?, ?, ?, ?, ?)",
                           arguments: [album.id, album.title, album.authorsText, album.year, album.thumbnailUrl])
            guard let at = album.bookmarkedAt, saneDates.contains(at) else { continue }
            if try Int64.fetchOne(db, sql: "SELECT bookmarked_at FROM albums WHERE browse_id = ?", arguments: [album.id]) == nil { saved += 1 }
            try db.execute(sql: "UPDATE albums SET bookmarked_at = MIN(COALESCE(bookmarked_at, :at), :at) WHERE browse_id = :id",
                           arguments: ["at": at, "id": album.id])
        }
        for artist in bundle.artists {
            try db.execute(sql: "INSERT OR IGNORE INTO artists (browse_id, name, thumbnail_url) VALUES (?, ?, ?)",
                           arguments: [artist.id, artist.name, artist.thumbnailUrl])
            guard let at = artist.bookmarkedAt, saneDates.contains(at) else { continue }
            if try Int64.fetchOne(db, sql: "SELECT bookmarked_at FROM artists WHERE browse_id = ?", arguments: [artist.id]) == nil { saved += 1 }
            try db.execute(sql: "UPDATE artists SET bookmarked_at = MIN(COALESCE(bookmarked_at, :at), :at) WHERE browse_id = :id",
                           arguments: ["at": at, "id": artist.id])
        }
        // Трек в альбоме и исполнители трека — только если обе стороны есть; известное здесь не затирается
        let albums = Dictionary(bundle.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for map in bundle.songAlbums {
            guard let album = albums[map.albumId], try isTrack(map.songId) else { continue }
            try db.execute(sql: "UPDATE tracks SET album_id = COALESCE(album_id, ?), album_title = COALESCE(album_title, ?) WHERE video_id = ?",
                           arguments: [map.albumId, album.title, map.songId])
        }
        let artists = Dictionary(bundle.artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var artistsOf: [String: [ArtistRef]] = [:]
        var songOrder: [String] = []
        for map in bundle.songArtists {
            guard let artist = artists[map.artistId] else { continue }
            if artistsOf[map.songId] == nil { songOrder.append(map.songId) }
            artistsOf[map.songId, default: []].append(ArtistRef(id: map.artistId, name: artist.name ?? ""))
        }
        for songId in songOrder where try isTrack(songId) {
            guard let data = try? JSONEncoder().encode(artistsOf[songId] ?? []), let json = String(data: data, encoding: .utf8) else { continue }
            try db.execute(sql: "UPDATE tracks SET artists_json = COALESCE(artists_json, ?) WHERE video_id = ?", arguments: [json, songId])
        }

        // Прослушивания: тот же трек в тот же момент — один раз, какой бы ни был id
        var playedAt = Set(try String.fetchAll(db, sql: "SELECT video_id || ':' || played_at FROM play_events"))
        var plays = 0, playsKnown = 0
        for event in bundle.events {
            guard try isTrack(event.songId) else { continue }
            guard saneDates.contains(event.timestamp) else {
                datesSkipped += 1
                continue
            }
            guard playedAt.insert("\(event.songId):\(event.timestamp)").inserted else {
                playsKnown += 1
                continue
            }
            let id = event.syncId ?? ImportIds.eventId(videoId: event.songId, timestampMs: event.timestamp, playTimeMs: event.playTime)
            // С deviceId — прослушивание другого устройства аккаунта: оно уже на сервере
            try db.execute(sql: """
                INSERT OR IGNORE INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, event.songId, event.timestamp, event.playTime, event.deviceId != nil, event.deviceId])
            if db.changesCount > 0 { plays += 1 } else { playsKnown += 1 }
        }

        // Тексты: только пустые стороны здесь («не искали» или «не нашли»)
        var lyricsAdded = 0
        for lyrics in bundle.lyrics where try isTrack(lyrics.songId) {
            let local = try Row.fetchOne(db, sql: "SELECT synced, plain FROM lyrics WHERE video_id = ?", arguments: [lyrics.songId])
            let offset = -(lyrics.startTime ?? 0)
            guard let local else {
                try db.execute(sql: """
                    INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [lyrics.songId, lyrics.synced, lyrics.fixed, lyrics.syncedSource, lyrics.fixedSource,
                                     lyrics.synced == nil ? 0 : offset, now])
                if visible.contains(lyrics.songId) { lyricsAdded += 1 }
                continue
            }
            let takePlain = ((local["plain"] as String?) ?? "").isEmpty && lyrics.fixed != nil
            let takeSynced = ((local["synced"] as String?) ?? "").isEmpty && lyrics.synced != nil
            guard takePlain || takeSynced else { continue }
            if takePlain {
                try db.execute(sql: "UPDATE lyrics SET plain = ?, plain_source = ? WHERE video_id = ?",
                               arguments: [lyrics.fixed, lyrics.fixedSource, lyrics.songId])
            }
            if takeSynced {
                try db.execute(sql: "UPDATE lyrics SET synced = ?, source = ?, offset_ms = ? WHERE video_id = ?",
                               arguments: [lyrics.synced, lyrics.syncedSource, offset, lyrics.songId])
            }
            if visible.contains(lyrics.songId) { lyricsAdded += 1 }
        }

        // Плейлисты: тот же (id сервера), иначе с той же ссылкой YouTube или единственный с тем же именем — недостающие
        // треки дописываются в конец; иначе новый
        var playlistsTouched = 0
        var taken = Set<Int64>()
        let locals = try Row.fetchAll(db, sql: "SELECT id, sync_id, browse_id, name FROM playlists ORDER BY id").map {
            (id: $0["id"] as Int64, syncId: $0["sync_id"] as String?, browseId: $0["browse_id"] as String?, name: $0["name"] as String)
        }
        for imported in bundle.playlists {
            let tracksOf = try imported.songIds.filter { try isTrack($0) }
            let free = locals.filter { !taken.contains($0.id) }
            var match = free.first { imported.syncId != nil && $0.syncId == imported.syncId }
            if match == nil { match = free.first { imported.browseId != nil && $0.browseId == imported.browseId } }
            if match == nil {
                let sameName = free.filter { norm($0.name) == norm(imported.name) }
                if sameName.count == 1 { match = sameName[0] }
            }
            let playlistId: Int64
            if let match {
                playlistId = match.id
            } else {
                let trimmed = imported.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmed.isEmpty ? "—" : Library.truncate(imported.name, nameMax)
                try db.execute(sql: "INSERT INTO playlists (name, browse_id, thumbnail_url, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [name, imported.browseId, imported.thumbnail, now])
                playlistId = db.lastInsertedRowID
            }
            taken.insert(playlistId)
            let have = Set(try String.fetchAll(db, sql: "SELECT video_id FROM playlist_items WHERE playlist_id = ?", arguments: [playlistId]))
            let start = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_items WHERE playlist_id = ?",
                                           arguments: [playlistId]) ?? 0
            let added = tracksOf.filter { !have.contains($0) }
            for (offset, videoId) in added.enumerated() {
                try db.execute(sql: "INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (?, ?, ?, ?)",
                               arguments: [playlistId, videoId, start + Int64(offset), now])
            }
            if match == nil || !added.isEmpty { playlistsTouched += 1 }
        }

        // Поиск: последние запросы, новые — сверху
        for (index, query) in bundle.searches.enumerated() {
            try db.execute(sql: "INSERT OR IGNORE INTO search_history (query, searched_at) VALUES (?, ?)",
                           arguments: [Library.truncate(query, 200), now - Int64(index)])
        }
        // Накопленное время — на сервер заново (`play.baseline atLeast`) при следующей синхронизации: ключ
        // `historyMerge` таблицы синка (MelogoldServer `SyncStateKey`), как у Windows
        if try db.tableExists("sync_state") {
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('historyMerge', '1')")
        }
        return ImportSummary(version: version, tracks: tracks, plays: plays, playsKnown: playsKnown, favorites: favorites,
                             lyrics: lyricsAdded, playlists: playlistsTouched, saved: saved, localSkipped: bundle.localSkipped,
                             datesSkipped: datesSkipped)
    }
}
