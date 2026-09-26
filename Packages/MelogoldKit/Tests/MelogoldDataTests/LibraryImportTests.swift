import Foundation
import GRDB
import Testing
import MelogoldCore
@testable import MelogoldData

/// Импорт и экспорт копии библиотеки (spec/backup-format.md §5, задание 0006): синтетическая копия ViTune v30 из теста
/// Android, повторный импорт, круг «экспорт → импорт в пустую базу», ошибки распознавания.
@Suite("Импорт и копия библиотеки")
struct LibraryImportTests {
    static let rick = "dQw4w9WgXcQ"
    static let other = "a1B2c3D4e5F"
    static let likedAt: Int64 = 1_726_000_000_000
    static let playedAt: Int64 = 1_726_000_100_000
    static let playlistSyncId = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    static let eventSyncId = "0f8fad5b-d9cb-469f-a165-70867728950e"

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Копия ViTune (схема v30): 3 трека (1 локальный), 5 прослушиваний (1 из 1970 года, 1 у локального), текст,
    /// закладка альбома, плейлист «Дорога», поиск — как `LegacyImporterTest` Android.
    private func vitune30Backup() throws -> URL {
        let url = directory.appendingPathComponent("vitune-\(UUID().uuidString).db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE Song (id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, artistsText TEXT, durationText TEXT,
                    thumbnailUrl TEXT, likedAt INTEGER, totalPlayTimeMs INTEGER NOT NULL, loudnessBoost REAL,
                    blacklisted INTEGER NOT NULL DEFAULT 0, explicit INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE Event (id INTEGER PRIMARY KEY AUTOINCREMENT, songId TEXT NOT NULL, timestamp INTEGER NOT NULL, playTime INTEGER NOT NULL);
                CREATE TABLE Lyrics (songId TEXT NOT NULL PRIMARY KEY, fixed TEXT, synced TEXT, startTime INTEGER);
                CREATE TABLE Album (id TEXT NOT NULL PRIMARY KEY, title TEXT, thumbnailUrl TEXT, year TEXT, authorsText TEXT,
                    shareUrl TEXT, timestamp INTEGER, bookmarkedAt INTEGER, description TEXT, otherInfo TEXT);
                CREATE TABLE Artist (id TEXT NOT NULL PRIMARY KEY, name TEXT, thumbnailUrl TEXT, timestamp INTEGER, bookmarkedAt INTEGER);
                CREATE TABLE SongAlbumMap (songId TEXT NOT NULL, albumId TEXT NOT NULL, position INTEGER, PRIMARY KEY (songId, albumId));
                CREATE TABLE SongArtistMap (songId TEXT NOT NULL, artistId TEXT NOT NULL, PRIMARY KEY (songId, artistId));
                CREATE TABLE Playlist (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, browseId TEXT, thumbnail TEXT);
                CREATE TABLE SongPlaylistMap (songId TEXT NOT NULL, playlistId INTEGER NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (songId, playlistId));
                CREATE TABLE SearchQuery (id INTEGER PRIMARY KEY AUTOINCREMENT, query TEXT NOT NULL);

                INSERT INTO Song VALUES ('\(Self.rick)', 'Never Gonna Give You Up', 'Rick Astley', '3:33', 'https://i.ytimg.com/vi/\(Self.rick)/hq.jpg', \(Self.likedAt), 600000, NULL, 0, 0);
                INSERT INTO Song VALUES ('\(Self.other)', '', NULL, NULL, NULL, NULL, 0, NULL, 0, 1);
                INSERT INTO Song VALUES ('local:42', 'My file.mp3', NULL, NULL, NULL, NULL, 90000, NULL, 0, 0);
                INSERT INTO Event (songId, timestamp, playTime) VALUES ('\(Self.rick)', \(Self.playedAt), 215000);
                INSERT INTO Event (songId, timestamp, playTime) VALUES ('\(Self.rick)', \(Self.playedAt + 1_000_000), 385000);
                INSERT INTO Event (songId, timestamp, playTime) VALUES ('\(Self.other)', \(Self.playedAt + 2_000_000), 0);
                INSERT INTO Event (songId, timestamp, playTime) VALUES ('\(Self.other)', 5, 1000);
                INSERT INTO Event (songId, timestamp, playTime) VALUES ('local:42', \(Self.playedAt), 90000);
                INSERT INTO Lyrics VALUES ('\(Self.rick)', '', '[00:01.00]Never gonna give you up', NULL);
                INSERT INTO Album (id, title, bookmarkedAt) VALUES ('MPREb_album1', 'Whenever You Need Somebody', \(Self.likedAt));
                INSERT INTO SongAlbumMap VALUES ('\(Self.rick)', 'MPREb_album1', 1);
                INSERT INTO Playlist (name) VALUES ('Дорога');
                INSERT INTO SongPlaylistMap VALUES ('\(Self.other)', 1, 0);
                INSERT INTO SongPlaylistMap VALUES ('\(Self.rick)', 1, 1);
                INSERT INTO SongPlaylistMap VALUES ('local:42', 1, 2);
                INSERT INTO SearchQuery (query) VALUES ('rick astley');
                PRAGMA user_version = 30;
                """)
        }
        try queue.close()
        return url
    }

    @Test func vitune30MergesOnce() throws {
        let database = try AppDatabase.inMemory()
        let first = try LibraryImport.run(try vitune30Backup(), into: database)
        #expect(first == ImportSummary(version: 30, tracks: 2, plays: 3, playsKnown: 0, favorites: 1, lyrics: 1, playlists: 1,
                                       saved: 1, localSkipped: 1, datesSkipped: 1))

        try database.writer.read { db in
            let rick = try #require(try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE video_id = ?", arguments: [Self.rick]))
            #expect(rick["liked_at"] as Int64? == Self.likedAt)
            #expect(rick["total_play_ms"] as Int64 == 600_000)
            #expect(rick["duration_ms"] as Int64? == 213_000)
            #expect(rick["album_id"] as String? == "MPREb_album1")
            let other = try #require(try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE video_id = ?", arguments: [Self.other]))
            #expect(other["title"] as String == Self.other)
            #expect(other["metadata_stub"] as Bool)
            #expect(other["explicit"] as Bool)
            let events = try Row.fetchAll(db, sql: "SELECT * FROM play_events WHERE video_id = ? ORDER BY played_at", arguments: [Self.rick])
            #expect(events.map { $0["played_at"] as Int64 } == [Self.playedAt, Self.playedAt + 1_000_000])
            #expect(events.first?["event_id"] as String? == ImportIds.eventId(videoId: Self.rick, timestampMs: Self.playedAt, playTimeMs: 215_000))
            #expect(events.allSatisfy { ($0["synced"] as Bool) == false && ($0["device_id"] as String?) == nil }, "свои, к отправке")
            #expect(try Int64.fetchOne(db, sql: "SELECT play_time_ms FROM play_events WHERE video_id = ?", arguments: [Self.other]) == 1)
            #expect(try String.fetchOne(db, sql: "SELECT synced FROM lyrics WHERE video_id = ?", arguments: [Self.rick]) == "[00:01.00]Never gonna give you up")
            #expect(try Int64.fetchOne(db, sql: "SELECT bookmarked_at FROM albums WHERE browse_id = 'MPREb_album1'") == Self.likedAt)
            let playlistId = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM playlists WHERE name = 'Дорога'"))
            #expect(try String.fetchAll(db, sql: "SELECT video_id FROM playlist_items WHERE playlist_id = ? ORDER BY position",
                                        arguments: [playlistId]) == [Self.other, Self.rick])
            #expect(try String.fetchAll(db, sql: "SELECT query FROM search_history") == ["rick astley"])
            #expect(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'historyMerge'") == "1")
        }

        let again = try LibraryImport.run(try vitune30Backup(), into: database)
        #expect(again.tracks == 0)
        #expect(again.plays == 0)
        #expect(again.playsKnown == 3)
        #expect(again.favorites == 0)
        #expect(again.playlists == 0, "треки уже в плейлисте")
        #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM play_events WHERE video_id = ?", arguments: [Self.rick]) } == 2)
        #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlists") } == 1)
    }

    /// «Сохранить копию» и «Импорт копии» на другом устройстве: свой текст остаётся своим, плейлист находит себя по id
    /// сервера, даже переименованный там, у прослушиваний — их id, прослушивания другого устройства — отправленные.
    @Test func copyGoesRound() throws {
        let sourceURL = directory.appendingPathComponent("source.sqlite")
        let source = try AppDatabase.open(at: sourceURL)
        let library = Library(database: source)
        let rick = Track(videoId: Self.rick, title: "Never Gonna Give You Up", artists: [ArtistRef(id: "UCuAXFkgsw1L7xaCfnd5JJOw", name: "Rick Astley")],
                         artistsText: "Rick Astley", albumId: "MPREb_album1", albumTitle: "Whenever You Need Somebody", durationMs: 213_000)
        library.setLiked(rick, true)
        library.setAlbumSaved(AlbumItem(browseId: "MPREb_album1", title: "Whenever You Need Somebody"), tracks: [rick], true)
        library.setArtistSaved(ArtistItem(browseId: "UCuAXFkgsw1L7xaCfnd5JJOw", name: "Rick Astley", thumbnailUrl: nil), true)
        try source.writer.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, sync_id, created_at) VALUES ('Дорога', ?, 1)", arguments: [Self.playlistSyncId])
            try db.execute(sql: "INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, 0, 1)", arguments: [Self.rick])
            try db.execute(sql: "INSERT INTO play_events (event_id, video_id, played_at, play_time_ms) VALUES (?, ?, ?, 215000)",
                           arguments: [Self.eventSyncId, Self.rick, Self.playedAt])
            try db.execute(sql: "INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES ('e2', ?, ?, 1000, 1, 'dev-2')",
                           arguments: [Self.rick, Self.playedAt + 5_000])
            try db.execute(sql: "INSERT INTO lyrics (video_id, plain, plain_source, synced, source, offset_ms, fetched_at) VALUES (?, 'Мои слова', 'user', '[00:01.00]Найдено', 'lrclib', 300, 1)",
                           arguments: [Self.rick])
            try db.execute(sql: "INSERT INTO search_history (query, searched_at) VALUES ('rick', 1)")
        }

        let copy = directory.appendingPathComponent(LibraryBackup.suggestedName())
        try LibraryBackup.export(databaseAt: sourceURL, to: copy, platform: "macos", appVersion: "0.1.0")
        #expect(copy.lastPathComponent.hasPrefix("Melogold_backup_"))
        let queue = try DatabaseQueue(path: copy.path)
        try queue.read { db in
            let marks = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM MelogoldBackup").map { ($0["key"] as String, $0["value"] as String) })
            #expect(marks["format"] == "1")
            #expect(marks["platform"] == "macos")
            #expect(marks["appVersion"] == "0.1.0")
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 31)
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "delete")
            #expect(try String.fetchOne(db, sql: "SELECT fixedSource FROM Lyrics") == "User")
            // Строка своего текста едет целиком, как у Windows: найденная сторона — со своим источником и сдвигом
            #expect(try String.fetchOne(db, sql: "SELECT syncedSource FROM Lyrics") == "LrcLib")
            #expect(try Int64.fetchOne(db, sql: "SELECT startTime FROM Lyrics") == -300)
            #expect(try String.fetchOne(db, sql: "SELECT artistId FROM SongArtistMap") == "UCuAXFkgsw1L7xaCfnd5JJOw")
            #expect(try String.fetchOne(db, sql: "SELECT deviceId FROM Event WHERE syncId = 'e2'") == "dev-2")
        }
        try queue.close()

        // Другое устройство: тот же плейлист, переименованный там, больше ничего
        let target = try AppDatabase.inMemory()
        try target.writer.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, sync_id, created_at) VALUES ('Road trip', ?, 1)", arguments: [Self.playlistSyncId])
        }
        let summary = try LibraryImport.run(copy, into: target)
        #expect(summary.version == 31)
        #expect(summary.tracks == 1)
        #expect(summary.plays == 2)
        #expect(summary.favorites == 1)
        #expect(summary.lyrics == 1)
        #expect(summary.saved == 2)
        try target.writer.read { db throws in
            #expect(try String.fetchOne(db, sql: "SELECT plain_source FROM lyrics WHERE video_id = ?", arguments: [Self.rick]) == "user", "свой текст остаётся своим")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlists") == 1, "второго плейлиста нет")
            #expect(try String.fetchAll(db, sql: "SELECT video_id FROM playlist_items") == [Self.rick])
            #expect(try Row.fetchOne(db, sql: "SELECT synced, device_id FROM play_events WHERE event_id = ?", arguments: [Self.eventSyncId])?["synced"] as Bool? == false)
            #expect(try Row.fetchOne(db, sql: "SELECT synced FROM play_events WHERE event_id = 'e2'")?["synced"] as Bool? == true)
            #expect(try String.fetchOne(db, sql: "SELECT artists_json FROM tracks")?.contains("UCuAXFkgsw1L7xaCfnd5JJOw") == true)
        }

        // Круг: экспорт → импорт в пустую библиотеку даёт те же числа
        let empty = try AppDatabase.inMemory()
        let again = try LibraryImport.run(copy, into: empty)
        #expect(again.tracks == 1 && again.plays == 2 && again.favorites == 1 && again.saved == 2 && again.playlists == 1)
    }

    @Test func recognizesWhatIsNotACopy() throws {
        let database = try AppDatabase.inMemory()
        let text = directory.appendingPathComponent("hello.db")
        try Data("hello".utf8).write(to: text)
        #expect(throws: ImportFailure.notABackup) { try LibraryImport.run(text, into: database) }

        let innerTune = directory.appendingPathComponent("innertune.db")
        let queue = try DatabaseQueue(path: innerTune.path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE song (id TEXT PRIMARY KEY)") }
        try queue.close()
        #expect(throws: ImportFailure.unsupported) { try LibraryImport.run(innerTune, into: database) }

        let old = directory.appendingPathComponent("old.db")
        let oldQueue = try DatabaseQueue(path: old.path)
        try oldQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE Song (id TEXT PRIMARY KEY, title TEXT NOT NULL); PRAGMA user_version = 5;")
        }
        try oldQueue.close()
        #expect(throws: ImportFailure.tooOld) { try LibraryImport.run(old, into: database) }

        let other = directory.appendingPathComponent("other.db")
        let otherQueue = try DatabaseQueue(path: other.path)
        try otherQueue.write { db in try db.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY)") }
        try otherQueue.close()
        #expect(throws: ImportFailure.notABackup) { try LibraryImport.run(other, into: database) }
    }

    /// Настоящая копия ViTune пользователя — только локально: `MELOGOLD_IMPORT_SAMPLE=/путь/к.db swift test`. В
    /// репозиторий она не кладётся: это чужая история. Ожидаемые числа — spec/backup-format.md §5.
    @Test func realBackupWhenGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["MELOGOLD_IMPORT_SAMPLE"], !path.isEmpty else { return }
        let database = try AppDatabase.inMemory()
        let summary = try LibraryImport.run(URL(fileURLWithPath: path), into: database)
        print("IMPORT SAMPLE: \(summary)")
        #expect(summary.tracks == 195)
        #expect(summary.plays == 16_046)
        #expect(summary.favorites == 21)
        #expect(summary.lyrics == 173)
        #expect(summary.saved == 3)
        #expect(summary.localSkipped == 16)
        let again = try LibraryImport.run(URL(fileURLWithPath: path), into: database)
        #expect(again.plays == 0 && again.playsKnown == summary.plays)
    }
}
