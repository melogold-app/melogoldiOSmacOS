import Foundation
import GRDB
import MelogoldCore
import Testing
@testable import MelogoldData

@Suite("Тексты на устройстве")
struct LyricsStoreTests {
    static let lrc = "[00:01.00]Один\n[00:02.00]Два"
    static let other = "[00:05.00]Чужой текст"

    let database: AppDatabase
    let store: LyricsStore

    init() throws {
        database = try AppDatabase.inMemory()
        store = LyricsStore(database: database)
    }

    private func columns() throws -> [String] {
        try database.writer.read { db in try db.columns(in: "lyrics").map(\.name) }
    }

    @Test func ownLyricsAreRecordedForSync() throws {
        final class Box: @unchecked Sendable { var ids: [String] = [] }
        let box = Box()
        store.setOwnLyricsRecorder { _, videoId in box.ids.append(videoId) }
        store.save("a1aaaaaaaaa", StoredLyrics(synced: "[00:01.00]x", plain: nil, syncedSource: LyricsSources.lrclib, plainSource: nil))
        #expect(box.ids.isEmpty)
        store.save("a1aaaaaaaaa", StoredLyrics(synced: "<tt/>", plain: nil, syncedSource: LyricsSources.user, plainSource: nil))
        store.delete("a1aaaaaaaaa")
        store.delete("a1aaaaaaaaa")
        #expect(box.ids == ["a1aaaaaaaaa", "a1aaaaaaaaa"])
        store.save("b2bbbbbbbbb", StoredLyrics(synced: nil, plain: "p", syncedSource: nil, plainSource: LyricsSources.youtubeMusic))
        store.save("c3ccccccccc", StoredLyrics(synced: nil, plain: "own", syncedSource: nil, plainSource: LyricsSources.file))
        #expect(store.fetchedSize() == 1)
        store.clearFetched()
        #expect(store.lyrics("b2bbbbbbbbb") == nil)
        #expect(store.lyrics("c3ccccccccc")?.plain == "own")
    }

    @Test func chosenColumnRoundTripsAndDefaultsToFalse() throws {
        #expect(try columns().contains("chosen"))
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil, chosen: true))
        store.save("b2bbbbbbbbb", StoredLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil))
        #expect(store.lyrics("a1aaaaaaaaa")?.chosen == true)
        #expect(store.lyrics("b2bbbbbbbbb")?.chosen == false)
    }

    /// Задание 0011: выбранный LrcLib-текст переживает «Очистить кэш», найденный такой же — нет.
    @Test func clearCacheKeepsChosenText() throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil, chosen: true))
        store.save("b2bbbbbbbbb", StoredLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil))
        // В размер кэша идёт только найденный текст (SQLite считает символы)
        #expect(store.fetchedSize() == Int64(Self.lrc.count))
        store.clearFetched()
        #expect(store.lyrics("a1aaaaaaaaa")?.chosen == true)
        #expect(store.lyrics("b2bbbbbbbbb") == nil)
        #expect(store.fetchedSize() == 0)
    }

    @Test func chooseIsChosenWithItsOwnSourceAndKeepsTypedTextUntilConfirmed() throws {
        // Пустая строка → выбор
        let first = store.choose("a1aaaaaaaaa", synced: Self.lrc, plain: nil)
        #expect(first == .chosen(StoredLyrics(synced: Self.lrc, plain: "", syncedSource: "lrclib", plainSource: nil, chosen: true)))
        // Свой набранный текст без подтверждения не заменяется, строка не меняется
        store.saveOwn("b2bbbbbbbbb", synced: Self.lrc, plain: "Свой", source: LyricsSources.user)
        let before = store.lyrics("b2bbbbbbbbb")
        #expect(store.choose("b2bbbbbbbbb", synced: Self.other, plain: nil) == .typedTextKept)
        #expect(store.lyrics("b2bbbbbbbbb") == before)
        // С подтверждением — заменяется выбранным
        let replaced = store.choose("b2bbbbbbbbb", synced: Self.other, plain: nil, replacingTyped: true)
        #expect(replaced == .chosen(StoredLyrics(synced: Self.other, plain: "", syncedSource: "lrclib", plainSource: nil, chosen: true)))
    }

    @Test func saveOwnWritesToTheGivenTrackOnly() throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.lrc, plain: "A", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib))
        store.saveOwn("b2bbbbbbbbb", synced: nil, plain: "Свой B", source: LyricsSources.user)
        #expect(store.lyrics("a1aaaaaaaaa")?.plain == "A")
        #expect(store.lyrics("b2bbbbbbbbb")?.plainSource == "user")
    }

    @Test func forgetFoundKeepsOwnAndChosenTextInTheDatabase() throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib))
        #expect(store.forgetFound("a1aaaaaaaaa") == nil)
        #expect(store.lyrics("a1aaaaaaaaa") == nil)
        store.saveOwn("b2bbbbbbbbb", synced: Self.lrc, plain: "Свой", source: LyricsSources.user)
        let own = store.lyrics("b2bbbbbbbbb")
        #expect(store.forgetFound("b2bbbbbbbbb") == own)
        store.choose("c3ccccccccc", synced: Self.lrc, plain: nil)
        let chosen = store.lyrics("c3ccccccccc")
        #expect(store.forgetFound("c3ccccccccc") == chosen)
    }

    @Test func saveFetchedDoesNotOverwriteTextThatAppearedMeanwhile() throws {
        // Поиск начался с пустой строки, за это время лёг импортированный файл
        store.saveOwn("a1aaaaaaaaa", synced: Self.other, plain: nil, source: LyricsSources.file)
        let merged = store.saveFetched(
            "a1aaaaaaaaa", baseline: nil,
            found: FoundLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib)
        )
        #expect(merged?.synced == Self.other)
        #expect(merged?.syncedSource == "file")
        #expect(merged?.plain == "Найденный")
        #expect(store.lyrics("a1aaaaaaaaa") == merged)
    }

    /// Сдвиг «раньше» уходит с ближайшим циклом синка (таблица `lyrics` наблюдается), «позже» сервер не хранит;
    /// хранилище отмечает правку своего текста и в той же транзакции.
    @Test func shiftAddsToStoredOffsetAndMarksOwnTextForSync() throws {
        final class Box: @unchecked Sendable { var ids: [String] = [] }
        let box = Box()
        store.setOwnLyricsRecorder { _, videoId in box.ids.append(videoId) }
        store.saveOwn("a1aaaaaaaaa", synced: Self.lrc, plain: nil, source: LyricsSources.user)
        store.save("b2bbbbbbbbb", StoredLyrics(synced: Self.lrc, plain: nil, syncedSource: LyricsSources.lrclib, plainSource: nil))
        box.ids = []
        #expect(store.shift("a1aaaaaaaaa", by: -100)?.offsetMs == -100)
        #expect(store.shift("a1aaaaaaaaa", by: -500)?.offsetMs == -600)
        #expect(store.lyrics("a1aaaaaaaaa")?.offsetMs == -600)
        #expect(box.ids == ["a1aaaaaaaaa", "a1aaaaaaaaa"])
        // Найденный текст не свой: сдвиг остаётся здесь
        #expect(store.shift("b2bbbbbbbbb", by: 100)?.offsetMs == 100)
        #expect(box.ids.count == 2)
        #expect(store.shift("a1aaaaaaaaa", by: nil)?.offsetMs == 0)
        #expect(store.shift("нет-такого", by: 100) == nil)
    }

    @MainActor
    @Test func observationDeliversFirstValueAndLaterEdits() async throws {
        final class Log: @unchecked Sendable { var values: [StoredLyrics?] = [] }
        let log = Log()
        let observation = store.observe("a1aaaaaaaaa") { log.values.append($0) }
        defer { observation.cancel() }
        // Первое значение приходит сразу, при запуске
        #expect(log.values.count == 1)
        #expect(log.values.first == .some(nil))
        // Правка синком (запись мимо хранилища, как SyncTx) приходит наблюдателю
        try await database.writer.write { db in
            try SyncTx(db: db).saveLyrics("a1aaaaaaaaa", StoredLyrics(synced: Self.lrc, plain: "", syncedSource: "lrclib", plainSource: nil, chosen: true))
        }
        try await eventually { log.values.last??.chosen == true }
        #expect(log.values.last??.synced == Self.lrc)
        // Чужой трек наблюдателя не будит
        let count = log.values.count
        store.saveOwn("b2bbbbbbbbb", synced: nil, plain: "x", source: LyricsSources.user)
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.values.count == count)
    }
}

/// Ждёт условия до двух секунд: значения наблюдения приходят на главный актор с задержкой.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("условие не выполнилось за 2 с")
}
