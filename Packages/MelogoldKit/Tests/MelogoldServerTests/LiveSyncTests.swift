import Foundation
import GRDB
import MelogoldCore
import MelogoldData
import Testing
@testable import MelogoldServer

/// Адрес сервера для живых тестов синка: `MELOGOLD_TEST_SERVER` (как у UI-тестов), например локальный
/// `http://127.0.0.1:8787`. Без переменной тесты пропускаются.
private let liveServerURL: String? = ProcessInfo.processInfo.environment["MELOGOLD_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }

/// Сквозная проверка на настоящем сервере — только с `MELOGOLD_TEST_SERVER`: два устройства одного аккаунта, каждое
/// со своей базой, синхронизируют библиотеку, историю и тексты. Тестовый аккаунт в конце удаляется
/// (`POST /auth/me/delete`).
@MainActor
@Suite("Живой синк", .enabled(if: liveServerURL != nil), .serialized)
struct LiveSyncTests {
    @MainActor
    final class Device {
        let database: AppDatabase
        let account: Account
        let engine: LibrarySync

        /// `recording` — запросы идут через `RecordingProtocol`: тест видит, что устройство отправило.
        init(name: String, platform: String, liveEvents: Bool = false, recording: Bool = false) throws {
            database = try AppDatabase.inMemory()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "live-\(UUID())")!)
            settings.serverURL = liveServerURL ?? ""
            let identity = DeviceIdentity(platform: platform, platformId: UUID().uuidString.lowercased(), name: name, osVersion: "27.0",
                                          model: "Test", clientVersion: "0.1.0")
            account = Account(settings: settings, secrets: MemorySecretStore(), identity: identity,
                              urlSession: recording ? RecordingProtocol.session() : .shared)
            engine = LibrarySync(account: account, database: database, liveEvents: liveEvents)
        }

        func sql(_ sql: String, _ arguments: StatementArguments = []) throws {
            try database.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
        }

        func strings(_ sql: String, _ arguments: StatementArguments = []) throws -> [String] {
            try database.writer.read { db in try String.fetchAll(db, sql: sql, arguments: arguments) }
        }

        func numbers(_ sql: String, _ arguments: StatementArguments = []) throws -> [Int64] {
            try database.writer.read { db in try Int64.fetchAll(db, sql: sql, arguments: arguments) }
        }

        func track(_ videoId: String, liked: Bool = false) throws {
            try sql("INSERT OR IGNORE INTO tracks (video_id, title, artists_text, created_at) VALUES (?, ?, 'Melogold test', 0)", [videoId, "Song \(videoId)"])
            if liked { try sql("UPDATE tracks SET liked_at = ? WHERE video_id = ?", [EpochMs.now(), videoId]) }
        }

        /// «Синхронизировать сейчас»; синхронизация должна пройти.
        func synced(sourceLocation: SourceLocation = #_sourceLocation) async {
            await engine.sync()
            if case .idle = engine.status { return }
            Issue.record("Синхронизация не прошла: \(engine.status)", sourceLocation: sourceLocation)
        }

        /// Запросы устройства к серверу за время `body` (нужен `recording`).
        func traffic(_ body: () async throws -> Void) async rethrows -> [StubServer.Request] {
            let token = account.session?.accessToken ?? ""
            let before = RecordingProtocol.requests(token: token).count
            try await body()
            return Array(RecordingProtocol.requests(token: token).dropFirst(before))
        }
    }

    @Test func twoDevicesShareLibraryHistoryAndLyrics() async throws {
        let mac = try Device(name: "Test Mac", platform: "macos")
        let watch = try Device(name: "Test Watch", platform: "watchos")
        try await withAccount(mac, watch) { try await scenario(mac: mac, watch: watch) }
    }

    /// Приёмка среза 5 от начала до конца: A — лайк, плейлист из трёх треков с переносом, закладка альбома, три
    /// прослушивания и свой текст; B получает всё это. B — снятый лайк, убранный трек плейлиста и «Убрать из истории»;
    /// A получает это. Синхронизация без правок ops не шлёт.
    @Test func roundTripBetweenTwoDevices() async throws {
        let a = try Device(name: "Test Mac", platform: "macos", recording: true)
        let b = try Device(name: "Test iPhone", platform: "ios", recording: true)
        try await withAccount(a, b) { try await roundTrip(a: a, b: b) }
    }

    /// Правки на обоих устройствах между синхронизациями сходятся к одному состоянию, и после этого ops не идут.
    @Test func concurrentEditsConverge() async throws {
        let a = try Device(name: "Test Mac", platform: "macos", recording: true)
        let b = try Device(name: "Test iPhone", platform: "ios", recording: true)
        try await withAccount(a, b) {
            let ids = ["aaaaaaaaaa1", "bbbbbbbbbb2", "cccccccccc3", "dddddddddd4", "eeeeeeeeee5", "ffffffffff6"]
            for id in ids { try a.track(id) }
            try a.sql("INSERT INTO playlists (name, created_at) VALUES ('Общий', ?)", [EpochMs.now()])
            try a.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, 0, 1), (1, ?, 1, 1), (1, ?, 2, 1), (1, ?, 3, 1)",
                      StatementArguments(ids.prefix(4)))
            try a.sql("INSERT INTO albums (browse_id, title, bookmarked_at) VALUES ('MPREb_one', 'Один', ?)", [EpochMs.now() - 5_000])
            try a.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES (?, '[00:01.00]one', NULL, 'file', NULL, 0, NULL, 0)",
                      [ids[0]])
            await a.synced()
            await b.synced()
            #expect(try b.strings("SELECT video_id FROM playlist_items ORDER BY position") == Array(ids.prefix(4)))

            // A: трек в конец плейлиста, лайк, прослушивание; B: перенос, убранный трек, другой лайк, прослушивание того же
            // трека, снятая закладка, свой текст изменён, имя плейлиста
            try a.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, 4, 2)", [ids[4]])
            try a.sql("UPDATE tracks SET liked_at = ? WHERE video_id = ?", [EpochMs.now() - 2_000, ids[5]])
            _ = try await SyncStore(database: a.database).recordPlay(SyncTrackRecord(videoId: ids[0], title: "Song"), playTimeMs: 10_000)
            let pb = try #require(try b.numbers("SELECT id FROM playlists").first)
            try b.sql("UPDATE playlist_items SET position = CASE video_id WHEN ? THEN 0 WHEN ? THEN 1 WHEN ? THEN 2 ELSE 3 END WHERE playlist_id = ?",
                      [ids[3], ids[0], ids[1], pb])
            try b.sql("DELETE FROM playlist_items WHERE video_id = ?", [ids[2]])
            try b.sql("UPDATE playlists SET name = 'Общий 2'")
            try b.sql("UPDATE tracks SET liked_at = ? WHERE video_id = ?", [EpochMs.now() - 1_000, ids[1]])
            try b.sql("UPDATE albums SET bookmarked_at = NULL")
            try b.sql("UPDATE lyrics SET synced = '[00:02.00]two', source = 'user'")
            _ = try await SyncStore(database: b.database).recordPlay(SyncTrackRecord(videoId: ids[0], title: "Song"), playTimeMs: 5_000)

            await a.synced()
            await b.synced()
            await a.synced()
            for device in [a, b] {
                #expect(try device.strings("SELECT video_id FROM playlist_items ORDER BY position") == [ids[3], ids[0], ids[1], ids[4]])
                #expect(try device.strings("SELECT name FROM playlists") == ["Общий 2"])
                #expect(try device.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL ORDER BY video_id") == [ids[1], ids[5]])
                #expect(try device.strings("SELECT browse_id FROM albums WHERE bookmarked_at IS NOT NULL").isEmpty)
                #expect(try device.strings("SELECT synced || ' · ' || source FROM lyrics") == ["[00:02.00]two · user"])
                #expect(try device.numbers("SELECT COUNT(*) FROM play_events") == [2])
                #expect(try device.numbers("SELECT total_play_ms FROM tracks WHERE video_id = ?", [ids[0]]) == [15_000])
            }
            await expectNothingSent(a)
            await expectNothingSent(b)
        }
    }

    /// Данные, которые сервер не примет как есть, не ломают синк и не уходят заново в каждом проходе: время вне
    /// диапазона API (часы устройства сбиты) — без него, трек с неверным `videoId` сервер отвергает один раз.
    @Test func unacceptableDataDoesNotLoop() async throws {
        let a = try Device(name: "Test Mac", platform: "macos", recording: true)
        let b = try Device(name: "Test iPhone", platform: "ios", recording: true)
        try await withAccount(a, b) {
            let liked = "dQw4w9WgXcQ"
            try a.track(liked)
            try a.track("local:song1")
            try a.sql("UPDATE tracks SET liked_at = 1000")
            try a.sql("INSERT INTO albums (browse_id, title, bookmarked_at) VALUES ('MPREb_old', 'Старый', 1000)")
            _ = try await SyncStore(database: a.database).recordPlay(SyncTrackRecord(videoId: liked, title: "Song"), playTimeMs: 10_000, playedAt: 1000)

            let sent = await a.traffic { await a.synced() }
            #expect(sent.filter { $0.path == "/sync" }.count == 1, "без бисекции")
            // Прослушивание 1970 года не уходит, накопленное время — play.baseline; лайк local:song1 сервер отвергает
            #expect(kinds(sent) == ["like.set", "like.set", "bookmark.set", "play.baseline"])
            #expect(try a.numbers("SELECT COUNT(*) FROM play_events WHERE synced = 0") == [0])
            await expectNothingSent(a)

            await b.synced()
            #expect(try b.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL") == [liked])
            #expect(try b.strings("SELECT browse_id FROM albums WHERE bookmarked_at IS NOT NULL") == ["MPREb_old"])
            #expect(try b.numbers("SELECT liked_at FROM tracks WHERE liked_at IS NOT NULL").allSatisfy { $0 > 946_684_800_000 })
            #expect(try b.numbers("SELECT bookmarked_at FROM albums").allSatisfy { $0 > 946_684_800_000 })
            #expect(try b.numbers("SELECT total_play_ms FROM tracks WHERE video_id = ?", [liked]) == [10_000])
            // У A — время сервера, а не 1970 год
            #expect(try a.numbers("SELECT liked_at FROM tracks WHERE video_id = ?", [liked]) == b.numbers("SELECT liked_at FROM tracks WHERE video_id = ?", [liked]))
        }
    }

    /// Большая библиотека уходит пакетами по 500 ops и приходит на другое устройство страницами (`hasMore`).
    @Test func largeLibraryGoesInBatchesAndPages() async throws {
        let a = try Device(name: "Test Mac", platform: "macos", recording: true)
        let b = try Device(name: "Test iPhone", platform: "ios", recording: true)
        try await withAccount(a, b) {
            let ids = (0 ..< 1200).map { String(format: "big%08d", $0) }
            let now = EpochMs.now()
            try await a.database.writer.write { db in
                try db.execute(sql: "INSERT INTO playlists (name, created_at) VALUES ('Большой', ?)", arguments: [now])
                for (index, id) in ids.enumerated() {
                    try db.execute(sql: "INSERT INTO tracks (video_id, title, artists_text, liked_at, total_play_ms, created_at) VALUES (?, ?, 'Melogold test', ?, ?, 0)",
                                   arguments: [id, "Song \(index)", index < 700 ? now - Int64(index) : nil, index < 1100 ? 1000 : 0])
                    try db.execute(sql: "INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, ?, 1)",
                                   arguments: [id, ids.count - index])
                    if index < 1100 {
                        try db.execute(sql: "INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES (?, ?, ?, 1000, 0, NULL)",
                                       arguments: [UUID().uuidString.lowercased(), id, now - 3_600_000 + Int64(index)])
                    }
                }
            }
            let sent = await a.traffic { await a.synced() }
            #expect(sent.filter { $0.path == "/sync" }.map { SyncFixtures.ops($0).count }.allSatisfy { $0 <= 500 })
            #expect(try a.numbers("SELECT COUNT(*) FROM play_events WHERE synced = 0") == [0])
            await expectNothingSent(a)

            let pulled = await b.traffic { await b.synced() }
            #expect(pulled.filter { $0.path == "/sync" }.count > 1, "страницами")
            #expect(try b.numbers("SELECT COUNT(*) FROM tracks WHERE liked_at IS NOT NULL") == [700])
            #expect(try b.strings("SELECT video_id FROM playlist_items ORDER BY position") == a.strings("SELECT video_id FROM playlist_items ORDER BY position"))
            #expect(try b.numbers("SELECT COUNT(*) FROM play_events") == [1100])
            #expect(try b.numbers("SELECT SUM(total_play_ms) FROM tracks") == [1_100_000])
            await expectNothingSent(b)
        }
    }

    /// Устройство со своей библиотекой до входа сливается с аккаунтом (API §4.7): плейлист с тем же именем занимает
    /// серверный, а не задваивает его; свои прослушивания и накопленное время уходят без задвоения.
    @Test func libraryBeforeSignInMergesIntoTheAccount() async throws {
        let a = try Device(name: "Test Mac", platform: "macos", recording: true)
        let b = try Device(name: "Test iPhone", platform: "ios", recording: true)
        let t = ["mergetrack1", "mergetrack2", "mergetrack3"]
        for id in t { try b.track(id) }
        try b.sql("INSERT INTO playlists (name, created_at) VALUES ('  дорога ', ?)", [EpochMs.now()])
        try b.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, 0, 1), (1, ?, 1, 1)", [t[1], t[2]])
        try b.sql("UPDATE tracks SET liked_at = ?, total_play_ms = 90000 WHERE video_id = ?", [EpochMs.now(), t[2]])
        _ = try await SyncStore(database: b.database).recordPlay(SyncTrackRecord(videoId: t[2], title: "Song"), playTimeMs: 30_000)
        try await withAccount(a, b) {
            for id in t.prefix(2) { try a.track(id) }
            try a.sql("INSERT INTO playlists (name, created_at) VALUES ('Дорога', ?)", [EpochMs.now()])
            try a.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, 0, 1), (1, ?, 1, 1)", [t[0], t[1]])
            await a.synced()

            await b.synced()
            await a.synced()
            for device in [a, b] {
                #expect(try device.strings("SELECT name FROM playlists") == ["Дорога"])
                #expect(try device.strings("SELECT video_id FROM playlist_items ORDER BY position") == t)
                #expect(try device.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL") == [t[2]])
                #expect(try device.numbers("SELECT COUNT(*) FROM play_events") == [1])
                #expect(try device.numbers("SELECT total_play_ms FROM tracks WHERE video_id = ?", [t[2]]) == [120_000])
            }
            await expectNothingSent(a)
            await expectNothingSent(b)
        }
    }

    /// Приёмка среза 5: правка на одном устройстве появляется на другом за секунды — по SSE `sync.changed`.
    @Test func changesArriveByLiveEvents() async throws {
        let mac = try Device(name: "Test Mac", platform: "macos")
        let watch = try Device(name: "Test Watch", platform: "watchos", liveEvents: true)
        try await withAccount(mac, watch) {
            watch.engine.start()
            defer { watch.engine.stop() }
            #expect(try await eventually { watch.engine.liveConnected })

            try mac.track("dQw4w9WgXcQ", liked: true)
            await mac.engine.sync()
            #expect(try await eventually { try watch.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL") == ["dQw4w9WgXcQ"] })

            let macId = try #require(mac.account.session?.deviceId)
            _ = try await mac.account.renameDevice(macId, name: "Рабочий Mac")
            #expect(try await eventually { watch.engine.devicesRevision > 0 })
        }
    }

    /// Сервер восстановлен из копии (курсор чужой эпохи → `410 cursor_invalid`): тихое слияние возвращает на сервер то,
    /// что он потерял, а плейлисты, прослушивания и время ничего не задваивают.
    @Test func restoredServerIsRefilledWithoutDuplicates() async throws {
        let mac = try Device(name: "Test Mac", platform: "macos")
        let watch = try Device(name: "Test Watch", platform: "watchos")
        try await withAccount(mac, watch) {
            try mac.track("dQw4w9WgXcQ", liked: true)
            try mac.track("kJQP7kiw5Fk")
            try mac.sql("INSERT INTO playlists (name, created_at) VALUES ('Дорога', 1)")
            try mac.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, 'kJQP7kiw5Fk', 0, 1)")
            try await SyncStore(database: mac.database).recordPlay(SyncTrackRecord(videoId: "dQw4w9WgXcQ", title: "Song dQw4w9WgXcQ"), playTimeMs: 60_000)
            await mac.engine.sync()

            // Лайк, который снимок Mac считает отправленным, а «восстановленный» сервер не знает
            try mac.track("9bZkp7q19f0", liked: true)
            try mac.sql("INSERT INTO synced_likes (video_id) VALUES ('9bZkp7q19f0')")
            try mac.sql("UPDATE sync_state SET value = '00000000.1.1' WHERE key = 'cursor'")
            await mac.engine.sync()
            guard case .idle = mac.engine.status else {
                Issue.record("status \(mac.engine.status)")
                return
            }

            await watch.engine.sync()
            #expect(try watch.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL ORDER BY video_id") == ["9bZkp7q19f0", "dQw4w9WgXcQ"])
            #expect(try watch.strings("SELECT name FROM playlists") == ["Дорога"])
            #expect(try watch.strings("SELECT video_id FROM playlist_items") == ["kJQP7kiw5Fk"])
            #expect(try watch.strings("SELECT CAST(COUNT(*) AS TEXT) FROM play_events") == ["1"])
            #expect(try watch.strings("SELECT CAST(total_play_ms AS TEXT) FROM tracks WHERE video_id = 'dQw4w9WgXcQ'") == ["60000"])
        }
    }

    /// Аккаунт на два устройства; в конце тестовый аккаунт удаляется в любом случае.
    private func withAccount(_ first: Device, _ second: Device, _ body: () async throws -> Void) async throws {
        let login = "synctest\(UUID().uuidString.prefix(8).lowercased())"
        let password = "длинный пароль \(UUID().uuidString)"
        _ = try await first.account.register(login: login, password: password)
        var failure: (any Error)?
        do {
            try await second.account.signIn(login: login, password: password)
            try await body()
        } catch {
            failure = error
        }
        try await first.account.authorized { api, token in
            try await api.sendEmpty("POST", "/auth/me/delete", body: ["password": password], token: token)
        }
        if let failure { throw failure }
    }

    /// Условие выполнилось не позже чем через 10 с.
    private func eventually(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0 ..< 100 {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try condition()
    }

    /// Kind каждой op, которую устройство отправило в `POST /sync`, по порядку.
    private func kinds(_ requests: [StubServer.Request]) -> [String] {
        requests.filter { $0.method == "POST" && $0.path == "/sync" }.flatMap(SyncFixtures.ops).compactMap { $0["kind"] as? String }
    }

    /// Синхронизация без правок спрашивает сервер (pull), но ops и тексты не шлёт.
    private func expectNothingSent(_ device: Device, sourceLocation: SourceLocation = #_sourceLocation) async {
        let sent = await device.traffic { await device.synced(sourceLocation: sourceLocation) }
        #expect(sent.contains { $0.method == "POST" && $0.path == "/sync" }, sourceLocation: sourceLocation)
        #expect(kinds(sent).isEmpty, "ops без правок: \(kinds(sent))", sourceLocation: sourceLocation)
        #expect(!sent.contains { $0.method == "PUT" || $0.method == "DELETE" }, sourceLocation: sourceLocation)
    }

    private func roundTrip(a: Device, b: Device) async throws {
        let liked = "dQw4w9WgXcQ"
        let songs = ["kJQP7kiw5Fk", "9bZkp7q19f0", "a1B2c3D4e5F"]
        let album = "MPREb_melogoldE2E"
        let lyrics = "[00:01.00]Never gonna\n[00:03.50]give you up"
        func record(_ videoId: String) -> SyncTrackRecord {
            SyncTrackRecord(videoId: videoId, title: "Song \(videoId)", artistsText: "Melogold test")
        }

        // A: лайк и плейлист из трёх треков — первая синхронизация создаёт плейлист на сервере
        try a.track(liked, liked: true)
        for id in songs { try a.track(id) }
        try a.sql("INSERT INTO playlists (name, created_at) VALUES ('Дорога', ?)", [EpochMs.now()])
        try a.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, ?, 0, 1), (1, ?, 1, 1), (1, ?, 2, 1)",
                  StatementArguments(songs))
        await a.synced()
        await expectNothingSent(a)

        // A: последний трек — в начало, закладка альбома, три прослушивания, свой текст
        try a.sql("UPDATE playlist_items SET position = CASE video_id WHEN ? THEN 0 WHEN ? THEN 1 ELSE 2 END", [songs[2], songs[0]])
        try a.sql("INSERT INTO albums (browse_id, title, artists_text, year, bookmarked_at) VALUES (?, 'Альбом', 'Исполнитель', '2020', ?)",
                  [album, EpochMs.now()])
        let store = SyncStore(database: a.database)
        let now = EpochMs.now()
        let plays = [
            try await store.recordPlay(record(liked), playTimeMs: 60_000, playedAt: now - 180_000),
            try await store.recordPlay(record(songs[0]), playTimeMs: 30_000, playedAt: now - 120_000),
            try await store.recordPlay(record(liked), playTimeMs: 45_000, playedAt: now - 60_000),
        ]
        try a.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, fetched_at) VALUES (?, ?, NULL, 'user', NULL, 0, 'en', 0)",
                  [liked, lyrics])
        let sent = await a.traffic { await a.synced() }
        #expect(kinds(sent) == ["playlist.item.move", "bookmark.set", "play.add", "play.add", "play.add"])
        #expect(sent.contains { $0.method == "PUT" && $0.path == "/lyrics/\(liked)" })
        #expect(try a.strings("SELECT video_id FROM playlist_items ORDER BY position") == [songs[2], songs[0], songs[1]])
        #expect(try a.numbers("SELECT COUNT(*) FROM play_events WHERE synced = 0") == [0])
        await expectNothingSent(a)

        // B получает всё: лайк со временем A, порядок плейлиста, закладку, прослушивания с устройством A, общее время,
        // свой текст
        await b.synced()
        #expect(try b.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL") == [liked])
        #expect(try b.numbers("SELECT liked_at FROM tracks WHERE video_id = ?", [liked]) == a.numbers("SELECT liked_at FROM tracks WHERE video_id = ?", [liked]))
        #expect(try b.strings("SELECT title || ' · ' || artists_text FROM tracks WHERE video_id = ?", [liked]) == ["Song \(liked) · Melogold test"])
        #expect(try b.strings("SELECT name FROM playlists") == ["Дорога"])
        #expect(try b.strings("SELECT video_id FROM playlist_items ORDER BY position") == [songs[2], songs[0], songs[1]])
        #expect(try b.strings("SELECT browse_id || ' · ' || title FROM albums WHERE bookmarked_at IS NOT NULL") == ["\(album) · Альбом"])
        #expect(try b.numbers("SELECT bookmarked_at FROM albums") == a.numbers("SELECT bookmarked_at FROM albums"))
        let aDevice = try #require(a.account.session?.deviceId)
        #expect(try b.strings("SELECT event_id FROM play_events ORDER BY played_at") == plays)
        #expect(try b.strings("SELECT DISTINCT COALESCE(device_id, '') FROM play_events") == [aDevice])
        #expect(try b.numbers("SELECT played_at FROM play_events ORDER BY played_at") == [now - 180_000, now - 120_000, now - 60_000])
        #expect(try b.numbers("SELECT play_time_ms FROM play_events ORDER BY played_at") == [60_000, 30_000, 45_000])
        #expect(try b.numbers("SELECT total_play_ms FROM tracks WHERE video_id = ?", [liked]) == [105_000])
        #expect(try b.numbers("SELECT total_play_ms FROM tracks WHERE video_id = ?", [songs[0]]) == [30_000])
        #expect(try b.strings("SELECT synced || ' · ' || source || ' · ' || language FROM lyrics WHERE video_id = ?", [liked])
            == ["\(lyrics) · user · en"])
        #expect(await b.engine.historyDevices().map(\.name) == ["Test Mac"])
        await expectNothingSent(b)

        // B: снятый лайк, убранный трек плейлиста, «Убрать из истории»
        try b.sql("UPDATE tracks SET liked_at = NULL WHERE video_id = ?", [liked])
        try b.sql("DELETE FROM playlist_items WHERE video_id = ?", [songs[0]])
        try await SyncStore(database: b.database).forgetFromHistory(videoId: liked)
        let edits = await b.traffic { await b.synced() }
        #expect(kinds(edits) == ["like.set", "playlist.item.remove", "history.forget"])

        // A получает это; общее время остаётся (resetTotal: false), свой текст — тоже
        await a.synced()
        #expect(try a.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL").isEmpty)
        #expect(try a.strings("SELECT video_id FROM playlist_items ORDER BY position") == [songs[2], songs[1]])
        #expect(try a.strings("SELECT event_id FROM play_events ORDER BY played_at") == [plays[1]])
        #expect(try b.strings("SELECT event_id FROM play_events ORDER BY played_at") == [plays[1]])
        for device in [a, b] {
            #expect(try device.numbers("SELECT total_play_ms FROM tracks WHERE video_id = ?", [liked]) == [105_000])
            #expect(try device.strings("SELECT synced FROM lyrics WHERE video_id = ?", [liked]) == [lyrics])
        }
        await expectNothingSent(a)
        await expectNothingSent(b)
    }

    private func scenario(mac: Device, watch: Device) async throws {

        // Mac: лайк, плейлист, прослушивание и свой текст
        try mac.track("dQw4w9WgXcQ", liked: true)
        for id in ["kJQP7kiw5Fk", "9bZkp7q19f0", "a1B2c3D4e5F"] { try mac.track(id) }
        try mac.sql("INSERT INTO playlists (name, created_at) VALUES ('Дорога', 1)")
        try mac.sql("INSERT INTO playlist_items (playlist_id, video_id, position, added_at) VALUES (1, 'kJQP7kiw5Fk', 0, 1), (1, '9bZkp7q19f0', 1, 1), (1, 'a1B2c3D4e5F', 2, 1)")
        try await SyncStore(database: mac.database).recordPlay(SyncTrackRecord(videoId: "dQw4w9WgXcQ", title: "Song dQw4w9WgXcQ"), playTimeMs: 60_000)
        try mac.sql("INSERT INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, fetched_at) VALUES ('dQw4w9WgXcQ', '[00:01.00]Never gonna', NULL, 'file', NULL, 0, 0)")
        await mac.engine.sync()
        #expect(mac.engine.status != .failed(offline: true, lastSyncAt: nil))

        // Часы получают всё с именем устройства в истории
        await watch.engine.sync()
        #expect(try watch.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL") == ["dQw4w9WgXcQ"])
        #expect(try watch.strings("SELECT video_id FROM playlist_items ORDER BY position") == ["kJQP7kiw5Fk", "9bZkp7q19f0", "a1B2c3D4e5F"])
        let macId = try #require(mac.account.session?.deviceId)
        #expect(try watch.strings("SELECT device_id FROM play_events") == [macId])
        #expect(try watch.strings("SELECT synced FROM lyrics") == ["[00:01.00]Never gonna"])
        #expect(await watch.engine.historyDevices().map(\.name) == ["Test Mac"])

        // Часы: перенос трека и снятый лайк; Mac получает их
        try watch.sql("UPDATE playlist_items SET position = CASE video_id WHEN 'a1B2c3D4e5F' THEN 0 WHEN 'kJQP7kiw5Fk' THEN 1 ELSE 2 END")
        try watch.sql("UPDATE tracks SET liked_at = NULL")
        await watch.engine.sync()
        await mac.engine.sync()
        #expect(try mac.strings("SELECT video_id FROM playlist_items ORDER BY position") == ["a1B2c3D4e5F", "kJQP7kiw5Fk", "9bZkp7q19f0"])
        #expect(try mac.strings("SELECT video_id FROM tracks WHERE liked_at IS NOT NULL").isEmpty)

        // Mac: «Очистить историю» и удалённый текст — на часах их тоже нет
        try await SyncStore(database: mac.database).clearHistory()
        try mac.sql("DELETE FROM lyrics")
        await mac.engine.sync()
        await watch.engine.sync()
        #expect(try watch.strings("SELECT event_id FROM play_events").isEmpty)
        #expect(try watch.strings("SELECT video_id FROM lyrics").isEmpty)
    }
}
