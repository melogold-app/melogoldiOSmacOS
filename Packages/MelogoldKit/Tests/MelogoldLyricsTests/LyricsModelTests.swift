import Foundation
import GRDB
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
import Testing
@testable import MelogoldLyrics
@testable import MelogoldServer

/// Модель текста играющего трека (audit 4.2): гонки, которые раньше нельзя было проверить — модель жила в приложении.
/// Настоящая база в памяти и цепочка поиска, которую тест держит и отпускает.
@MainActor
@Suite("LyricsModel — текст играющего трека")
struct LyricsModelTests {
    static let lrc = "[00:01.00]Один\n[00:02.00]Два"
    static let imported = "[00:05.00]Из файла"
    static let plainFound = "Найденный обычный"

    let database: AppDatabase
    let store: LyricsStore
    let fetcher = FakeFetcher()
    let model: LyricsModel

    init() throws {
        database = try AppDatabase.inMemory()
        store = LyricsStore(database: database)
        model = LyricsModel(fetcher: fetcher, store: store)
    }

    private func track(_ id: String) -> Track {
        Track(videoId: id, title: "Song \(id)", artists: [], artistsText: "Artist", durationMs: 200_000)
    }

    private func found(synced: String? = nil, plain: String? = nil, syncedSource: String? = LyricsSources.lrclib, plainSource: String? = LyricsSources.lrclib) -> LyricsFetchResult {
        LyricsFetchResult(plain: plain, synced: synced, plainSource: plain == nil ? nil : plainSource, syncedSource: synced == nil ? nil : syncedSource)
    }

    /// Своя версия с сервера (`MyLyrics`, API §4.10): синхронная сторона, источник, сдвиг «раньше» — `startTimeMs`.
    private func serverVersion(
        _ videoId: String, rev: Int, synced: String? = nil, source: String = "lrclib", startTimeMs: Int? = nil, deleted: Bool = false
    ) throws -> MyLyrics {
        let text: [String: Any?]? = synced.map {
            ["plain": nil, "plainSource": nil, "synced": $0, "syncedFormat": "lrc", "syncedSource": source, "startTimeMs": startTimeMs, "language": nil]
        }
        let object: [String: Any?] = [
            "id": "00000000-0000-4000-8000-000000000001", "videoId": videoId, "rev": rev, "deleted": deleted, "text": text,
            "updatedAt": "2026-09-25T12:00:00.000Z",
        ]
        func json(_ value: Any?) -> Any { value ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: object.mapValues { value -> Any in
            if let inner = value as? [String: Any?] { return inner.mapValues(json) }
            return json(value)
        })
        return try JSONDecoder().decode(MyLyrics.self, from: data)
    }

    /// Поиски вернули ответы, и модель успела их разобрать.
    private func searchesDone(_ count: Int) async throws {
        try await eventually { fetcher.finished == count }
        try await Task.sleep(for: .milliseconds(80))
    }

    /// Пока не пришли значения поиска и наблюдения, модель показывает то, что было.
    private func settle() async throws {
        try await eventually { model.state != .loading }
    }

    // MARK: - Показ

    @Test func showsStoredTextWithoutSearching() async throws {
        store.saveOwn("a1aaaaaaaaa", synced: Self.lrc, plain: "Один\nДва", source: LyricsSources.user)
        model.load(track("a1aaaaaaaaa"))
        #expect(model.state == .loaded)
        #expect(model.showingSynced)
        #expect(model.rows.count == 2)
        #expect(fetcher.calls.isEmpty)
    }

    @Test func searchFillsTheDatabaseAndTheScreen() async throws {
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc, plain: Self.plainFound))
        model.load(track("a1aaaaaaaaa"))
        #expect(model.state == .loading)
        try await settle()
        #expect(model.state == .loaded)
        #expect(store.lyrics("a1aaaaaaaaa") == StoredLyrics(synced: Self.lrc, plain: Self.plainFound, syncedSource: "lrclib", plainSource: "lrclib"))
        #expect(model.plain == Self.plainFound)
    }

    @Test func nothingFoundIsRememberedSoItIsNotSearchedAgain() async throws {
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        #expect(model.state == .notFound)
        #expect(store.lyrics("a1aaaaaaaaa") == StoredLyrics(synced: "", plain: "", syncedSource: nil, plainSource: nil))
        model.load(track("b2bbbbbbbbb"))
        try await settle()
        model.load(track("a1aaaaaaaaa"))
        #expect(model.state == .notFound)
        #expect(fetcher.calls.map(\.videoId) == ["a1aaaaaaaaa", "b2bbbbbbbbb"])
    }

    // MARK: - Редактор, импорт, выбор пишут в свой трек

    /// Редактор открыт для трека A; под ним очередь ушла к B. Сохранение ложится в A, а не в B.
    @Test func editorSaveGoesToTheTrackItWasOpenedFor() async throws {
        fetcher.answer("b2bbbbbbbbb", found(synced: Self.lrc, syncedSource: LyricsSources.youtubeMusic))
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        // Очередь переключилась на B, пока редактор A открыт
        model.load(track("b2bbbbbbbbb"))
        try await settle()
        let bBefore = store.lyrics("b2bbbbbbbbb")

        model.saveOwn(videoId: "a1aaaaaaaaa", synced: Self.imported, plain: "Из редактора", source: LyricsSources.user)

        let a = try #require(store.lyrics("a1aaaaaaaaa"))
        #expect(a.synced == Self.imported)
        #expect(a.plainSource == "user")
        // B не тронут ни в базе, ни на экране
        #expect(store.lyrics("b2bbbbbbbbb") == bBefore)
        #expect(model.track?.videoId == "b2bbbbbbbbb")
        #expect(model.stored?.syncedSource == "youtube_music")
        #expect(model.synced?.lines.first?.text != "Из файла")
        // Открытый для A редактор читает текст A из базы, а не тот, что показан
        #expect(model.stored(for: "a1aaaaaaaaa")?.plain == "Из редактора")
    }

    @Test func searchSheetChoiceAndImportGoToTheirOwnTrack() async throws {
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        model.load(track("b2bbbbbbbbb"))
        try await settle()

        #expect(model.use(synced: Self.lrc, plain: nil, for: "a1aaaaaaaaa") == .applied)
        #expect(model.importFile("Просто текст из файла", for: "c3ccccccccc"))
        #expect(model.importFile(Self.imported, for: "c3ccccccccc"))

        #expect(store.lyrics("a1aaaaaaaaa")?.chosen == true)
        let c = try #require(store.lyrics("c3ccccccccc"))
        #expect(c.plain == "Просто текст из файла" && c.plainSource == "file")
        #expect(c.synced == Self.imported && c.syncedSource == "file")
        // На экране по-прежнему B, и у него текста нет
        #expect(model.track?.videoId == "b2bbbbbbbbb")
        #expect(model.state == .notFound)
        #expect(!model.hasAny)
        // Нечитаемый файл — отказ, ничего не записано
        #expect(!model.importFile("   \n ", for: "d4ddddddddd"))
        #expect(store.lyrics("d4ddddddddd") == nil)
    }

    // MARK: - Поиск в полёте

    @Test func searchInFlightDoesNotOverwriteImportedText() async throws {
        fetcher.hold()
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc, plain: Self.plainFound))
        model.load(track("a1aaaaaaaaa"))
        #expect(model.state == .loading)

        // Пока идёт поиск, пользователь импортирует синхронный текст из файла
        #expect(model.importFile(Self.imported, for: "a1aaaaaaaaa"))
        #expect(model.state == .loaded)
        fetcher.release()
        try await eventually { model.stored?.plain == Self.plainFound }

        let row = try #require(store.lyrics("a1aaaaaaaaa"))
        #expect(row.synced == Self.imported)
        #expect(row.syncedSource == "file")
        #expect(row.plain == Self.plainFound)
        #expect(model.stored == row)
        #expect(row.isOwn)
    }

    @Test func searchInFlightDoesNotOverwriteEditorTextOrChosenText() async throws {
        fetcher.hold()
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc, plain: Self.plainFound))
        fetcher.answer("b2bbbbbbbbb", found(synced: Self.lrc, plain: Self.plainFound))
        model.load(track("a1aaaaaaaaa"))
        model.saveOwn(videoId: "a1aaaaaaaaa", synced: Self.imported, plain: "Из редактора", source: LyricsSources.user)
        model.load(track("b2bbbbbbbbb"))
        model.use(synced: "[00:07.00]Выбранный", plain: nil, for: "b2bbbbbbbbb")
        fetcher.release()
        // Поиск A отменён сменой трека и на строку не влияет; поиск B доходит и ничего не меняет
        try await eventually { fetcher.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(150))

        let a = try #require(store.lyrics("a1aaaaaaaaa"))
        #expect(a.synced == Self.imported && a.plain == "Из редактора")
        let b = try #require(store.lyrics("b2bbbbbbbbb"))
        #expect(b.synced == "[00:07.00]Выбранный")
        #expect(b.chosen)
        #expect(model.stored == b)
    }

    @Test func searchInFlightDoesNotOverwriteWhatSyncBroughtMeanwhile() async throws {
        fetcher.hold()
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc, plain: Self.plainFound))
        model.load(track("a1aaaaaaaaa"))
        // Синк принёс версию пользователя с другого устройства
        let version = try serverVersion("a1aaaaaaaaa", rev: 4, synced: Self.imported)
        try await SyncStore(database: database).write { tx in try LibrarySync.applyLyrics(tx, version) }
        fetcher.release()
        try await searchesDone(1)

        // Версия пользователя — обе стороны, «обычной нет» — пустая строка: поиск её не дополняет
        let row = try #require(store.lyrics("a1aaaaaaaaa"))
        #expect(row == StoredLyrics(synced: Self.imported, plain: "", syncedSource: "lrclib", plainSource: nil, chosen: true))
        #expect(model.stored == row)
    }

    // MARK: - Синк обновляет экран

    @Test func screenFollowsWhatSyncPulls() async throws {
        store.saveOwn("a1aaaaaaaaa", synced: Self.lrc, plain: nil, source: LyricsSources.user)
        model.load(track("a1aaaaaaaaa"))
        #expect(model.synced?.lines.count == 2)
        // Пользователь правит текст на Android — версия приходит синком
        let snapshot = LyricsSyncRules.hash(LyricsSyncRules.payload(try #require(store.lyrics("a1aaaaaaaaa"))))
        try await SyncStore(database: database).write { try $0.setSyncedLyrics("a1aaaaaaaaa", rev: 3, hash: snapshot) }
        let version = try serverVersion("a1aaaaaaaaa", rev: 4, synced: Self.imported, source: "user")

        try await SyncStore(database: database).write { tx in try LibrarySync.applyLyrics(tx, version) }

        try await eventually { model.stored?.synced == Self.imported }
        #expect(model.synced?.lines.first?.text == "Из файла")
        #expect(model.state == .loaded)
    }

    @Test func remoteDeleteEmptiesTheScreen() async throws {
        store.saveOwn("a1aaaaaaaaa", synced: Self.lrc, plain: nil, source: LyricsSources.user)
        model.load(track("a1aaaaaaaaa"))
        let snapshot = LyricsSyncRules.hash(LyricsSyncRules.payload(try #require(store.lyrics("a1aaaaaaaaa"))))
        try await SyncStore(database: database).write { try $0.setSyncedLyrics("a1aaaaaaaaa", rev: 3, hash: snapshot) }
        let tombstone = try serverVersion("a1aaaaaaaaa", rev: 4, deleted: true)

        try await SyncStore(database: database).write { tx in try LibrarySync.applyLyrics(tx, tombstone) }

        try await eventually { !model.hasAny }
        #expect(model.state == .notFound)
    }

    @Test func shiftAddsToWhatSyncStoredNotToAStaleCopy() async throws {
        store.saveOwn("a1aaaaaaaaa", synced: Self.lrc, plain: nil, source: LyricsSources.user)
        model.load(track("a1aaaaaaaaa"))
        model.shift(by: 100)
        #expect(model.offsetMs == 100)
        // Другое устройство прислало версию со сдвигом «раньше»: startTimeMs 500 → сдвиг −500 (свой текст здесь после
        // прошлого синка не менялся — версия применяется)
        let synced = LyricsSyncRules.hash(LyricsSyncRules.payload(try #require(store.lyrics("a1aaaaaaaaa"))))
        try await SyncStore(database: database).write { try $0.setSyncedLyrics("a1aaaaaaaaa", rev: 3, hash: synced) }
        let version = try serverVersion("a1aaaaaaaaa", rev: 4, synced: Self.lrc, source: "user", startTimeMs: 500)
        try await SyncStore(database: database).write { tx in try LibrarySync.applyLyrics(tx, version) }
        try await eventually { model.offsetMs == -500 }

        model.shift(by: 100)

        #expect(model.offsetMs == -400)
        #expect(store.lyrics("a1aaaaaaaaa")?.offsetMs == -400)
        model.shift(by: nil)
        #expect(store.lyrics("a1aaaaaaaaa")?.offsetMs == 0)
    }

    // MARK: - «Найти текст»: выбор

    @Test func chosenTextIsChosenWithItsSourceAndTypedTextIsNotReplacedSilently() async throws {
        store.saveOwn("a1aaaaaaaaa", synced: Self.lrc, plain: "Свой", source: LyricsSources.user)
        model.load(track("a1aaaaaaaaa"))
        let before = store.lyrics("a1aaaaaaaaa")

        #expect(model.use(synced: Self.imported, plain: nil, for: "a1aaaaaaaaa") == .needsConfirmation)
        #expect(store.lyrics("a1aaaaaaaaa") == before)
        #expect(model.stored == before)

        #expect(model.use(synced: Self.imported, plain: nil, for: "a1aaaaaaaaa", replacingTyped: true) == .applied)
        let row = try #require(store.lyrics("a1aaaaaaaaa"))
        #expect(row == StoredLyrics(synced: Self.imported, plain: "", syncedSource: "lrclib", plainSource: nil, chosen: true))
        #expect(model.stored == row)
        // Выбранное заменяется другим выбранным без вопросов
        #expect(model.use(synced: Self.lrc, plain: "Обычный", for: "a1aaaaaaaaa") == .applied)
        #expect(store.lyrics("a1aaaaaaaaa")?.plainSource == "lrclib")
    }

    // MARK: - «Искать заново»

    @Test func searchAgainForgetsFoundTextButKeepsOwn() async throws {
        // Найденное: искать заново — заново находит
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc, plain: Self.plainFound))
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.imported, plain: "Новый обычный"))
        model.searchAgain()
        try await eventually { model.stored?.plain == "Новый обычный" }
        #expect(store.lyrics("a1aaaaaaaaa")?.synced == Self.imported)
        // Найденное не «свой» после повторного поиска
        #expect(store.lyrics("a1aaaaaaaaa")?.isOwn == false)

        // Свой текст (и выбранный) не затирается
        store.saveOwn("b2bbbbbbbbb", synced: Self.lrc, plain: "Свой", source: LyricsSources.user)
        let own = store.lyrics("b2bbbbbbbbb")
        model.load(track("b2bbbbbbbbb"))
        fetcher.answer("b2bbbbbbbbb", found(synced: "[00:09.00]Чужой", plain: "Чужой", syncedSource: LyricsSources.kugou, plainSource: LyricsSources.kugou))
        model.searchAgain()
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.lyrics("b2bbbbbbbbb") == own)
        #expect(model.stored == own)

        model.use(synced: Self.lrc, plain: nil, for: "c3ccccccccc")
        model.load(track("c3ccccccccc"))
        let chosen = store.lyrics("c3ccccccccc")
        model.searchAgain()
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.lyrics("c3ccccccccc") == chosen)
    }

    /// Свой текст с одной стороной и найденная другая: искать заново ищет только недостающую.
    @Test func searchAgainSearchesOnlyTheSideThatIsNotOwn() async throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.lrc, plain: "Мой", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.user))
        model.load(track("a1aaaaaaaaa"))
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.imported, plain: "Мой", syncedSource: LyricsSources.kugou, plainSource: LyricsSources.user))
        model.searchAgain()
        try await eventually { model.stored?.synced == Self.imported }

        let call = try #require(fetcher.calls.last)
        #expect(call.current?.plain == "Мой")
        #expect(call.current?.synced == nil)
        #expect(store.lyrics("a1aaaaaaaaa")?.plainSource == "user")
    }

    // MARK: - Нет сети

    @Test func offlineRetryRunsTheChainAgain() async throws {
        fetcher.answer("a1aaaaaaaaa", LyricsFetchResult(anyFailure: true))
        model.load(track("a1aaaaaaaaa"))
        try await eventually { model.state == .offline }
        #expect(store.lyrics("a1aaaaaaaaa") == nil)

        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc))
        model.retry()
        #expect(model.state == .loading)
        try await eventually { model.state == .loaded }
        #expect(fetcher.calls.count == 2)
        #expect(model.synced != nil)
    }

    @Test func communityTextFromOwnServerVersionIsChosenAndSharedOneIsNot() async throws {
        fetcher.answer("a1aaaaaaaaa", LyricsFetchResult(synced: Self.lrc, syncedSource: "lrclib", chosen: true))
        fetcher.answer("b2bbbbbbbbb", LyricsFetchResult(synced: Self.lrc, syncedSource: LyricsSources.melogold))
        model.load(track("a1aaaaaaaaa"))
        try await eventually { model.state == .loaded }
        model.load(track("b2bbbbbbbbb"))
        try await eventually { model.state == .loaded }

        let own = try #require(store.lyrics("a1aaaaaaaaa"))
        #expect(own.chosen)
        #expect(own.isOwn)
        let shared = try #require(store.lyrics("b2bbbbbbbbb"))
        #expect(!shared.isOwn)
        #expect(model.isCommunity)
    }

    // MARK: - Без базы

    @Test func withoutDatabaseTheModelStillShowsWhatItFound() async throws {
        let memory = LyricsModel(fetcher: fetcher, store: nil)
        fetcher.answer("a1aaaaaaaaa", found(synced: Self.lrc, plain: Self.plainFound))
        memory.load(track("a1aaaaaaaaa"))
        try await eventually { memory.state == .loaded }
        #expect(memory.plain == Self.plainFound)
        memory.saveOwn(videoId: "a1aaaaaaaaa", synced: nil, plain: "Свой", source: LyricsSources.user)
        #expect(memory.stored?.plainSource == "user")
        #expect(memory.use(synced: Self.imported, plain: nil, for: "a1aaaaaaaaa") == .needsConfirmation)
        memory.shift(by: 100)
        #expect(memory.offsetMs == 100)
    }
}
