import Foundation
import GRDB
import MelogoldCore
import MelogoldData
import Testing
@testable import MelogoldServer

/// Сквозная проверка на настоящем сервере — только с `MELOGOLD_LIVE=1` (как у Windows): два устройства одного
/// аккаунта, каждое со своей базой, синхронизируют библиотеку, историю и тексты. Сервер — `MELOGOLD_SERVER`
/// (по умолчанию локальный `http://127.0.0.1:8787`); тестовый аккаунт в конце удаляется (`POST /auth/me/delete`).
@MainActor
@Suite("Живой синк", .enabled(if: ProcessInfo.processInfo.environment["MELOGOLD_LIVE"] == "1"), .serialized)
struct LiveSyncTests {
    nonisolated static let serverURL = ProcessInfo.processInfo.environment["MELOGOLD_SERVER"] ?? "http://127.0.0.1:8787"

    @MainActor
    final class Device {
        let database: AppDatabase
        let account: Account
        let engine: LibrarySync

        init(name: String, platform: String, liveEvents: Bool = false) throws {
            database = try AppDatabase.inMemory()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "live-\(UUID())")!)
            settings.serverURL = LiveSyncTests.serverURL
            let identity = DeviceIdentity(platform: platform, platformId: UUID().uuidString.lowercased(), name: name, osVersion: "27.0",
                                          model: "Test", clientVersion: "0.1.0")
            account = Account(settings: settings, secrets: MemorySecretStore(), identity: identity)
            engine = LibrarySync(account: account, database: database, liveEvents: liveEvents)
        }

        func sql(_ sql: String, _ arguments: StatementArguments = []) throws {
            try database.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
        }

        func strings(_ sql: String) throws -> [String] {
            try database.writer.read { db in try String.fetchAll(db, sql: sql) }
        }

        func track(_ videoId: String, liked: Bool = false) throws {
            try sql("INSERT OR IGNORE INTO tracks (video_id, title, artists_text, created_at) VALUES (?, ?, 'Melogold test', 0)", [videoId, "Song \(videoId)"])
            if liked { try sql("UPDATE tracks SET liked_at = ? WHERE video_id = ?", [EpochMs.now(), videoId]) }
        }
    }

    @Test func twoDevicesShareLibraryHistoryAndLyrics() async throws {
        let mac = try Device(name: "Test Mac", platform: "macos")
        let watch = try Device(name: "Test Watch", platform: "watchos")
        try await withAccount(mac, watch) { try await scenario(mac: mac, watch: watch) }
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
