import Foundation
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
import Testing
@testable import MelogoldLyrics

/// Модель текста и закрепление (задание 0015): закреплённый текст встаёт на место найденного здесь, свой текст важнее
/// закрепления, поставщик не отдал — поиск идёт как обычно; закрепление с другого устройства доходит до открытого экрана.
@MainActor
@Suite("LyricsModel — закреплённый текст")
struct LyricsPinModelTests {
    static let foundLrc = "[00:01.00]Найденный\n[00:02.00]Два"
    static let pinnedLrc = "[00:01.00]Закреплённый\n[00:02.00]Два"

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

    private func pin(_ ref: String) -> LyricsPin { LyricsPin(source: "lrclib", ref: ref)! }

    private func result(_ synced: String, ref: String, source: String = LyricsSources.lrclib) -> LyricsFetchResult {
        LyricsFetchResult(synced: synced, syncedSource: source, syncedRef: ref)
    }

    private func settle() async throws {
        try await eventually { model.state != .loading }
        try await Task.sleep(for: .milliseconds(80))
    }

    /// Поиск получает закрепление: цепочка сама решает, что важнее (`LyricsFetcher`).
    @Test func searchGetsThePin() async throws {
        store.setPin("a1aaaaaaaaa", pin("123"))
        fetcher.answer("a1aaaaaaaaa", result(Self.pinnedLrc, ref: "123"))
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        #expect(fetcher.calls.first?.pin == pin("123"))
        #expect(store.lyrics("a1aaaaaaaaa")?.syncedRef == "123")
        #expect(LyricsPinRules.shows(model.stored, pin("123")))
    }

    /// На устройстве уже лежит другой найденный текст — закреплённый встаёт на его место, а найденный забывается.
    @Test func pinReplacesADifferentFoundText() async throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.foundLrc, plain: "Найденный", syncedSource: "lrclib", plainSource: "lrclib", syncedRef: "999", plainRef: "999"))
        store.setPin("a1aaaaaaaaa", pin("123"))
        fetcher.answer("a1aaaaaaaaa", LyricsFetchResult(plain: "Закреплённый", synced: Self.pinnedLrc, plainSource: "lrclib", syncedSource: "lrclib", plainRef: "123", syncedRef: "123"))
        model.load(track("a1aaaaaaaaa"))
        try await eventually { model.stored?.syncedRef == "123" }
        #expect(model.stored?.synced == Self.pinnedLrc)
        #expect(fetcher.calls.first?.current == nil, "найденное перед поиском забыто")
        #expect(store.lyrics("a1aaaaaaaaa")?.plain == "Закреплённый")
    }

    /// Показывается уже закреплённый — сети не нужно; свой текст закреплению не уступает.
    @Test func shownPinAndOwnTextAreLeftAlone() async throws {
        let shownPin = pin("123")
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.pinnedLrc, plain: "Закреплённый", syncedSource: "lrclib", plainSource: "lrclib", syncedRef: "123", plainRef: "123"))
        store.setPin("a1aaaaaaaaa", shownPin)
        model.load(track("a1aaaaaaaaa"))
        #expect(model.state == .loaded)
        #expect(fetcher.calls.isEmpty)

        store.saveOwn("b2bbbbbbbbb", synced: Self.foundLrc, plain: "Мой", source: LyricsSources.user)
        store.setPin("b2bbbbbbbbb", pin("5"))
        model.load(track("b2bbbbbbbbb"))
        #expect(model.state == .loaded)
        #expect(fetcher.calls.isEmpty, "свой текст важнее закрепления")
        #expect(store.lyrics("b2bbbbbbbbb")?.synced == Self.foundLrc)
    }

    /// Закрепление достаётся один раз за запуск: поставщик не отдал — на каждый показ заново не ходим.
    @Test func unfetchablePinIsTriedOncePerLaunch() async throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.foundLrc, plain: "Найденный", syncedSource: "lrclib", plainSource: "lrclib", syncedRef: "999", plainRef: "999"))
        store.setPin("a1aaaaaaaaa", pin("404"))
        // Поставщик не отдал закреплённое — цепочка вернула найденное, как оно было
        fetcher.answer("a1aaaaaaaaa", LyricsFetchResult(plain: "Найденный", synced: Self.foundLrc, plainSource: "lrclib", syncedSource: "lrclib", plainRef: "999", syncedRef: "999"))
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        model.load(track("b2bbbbbbbbb"))
        try await settle()
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        #expect(fetcher.calls.filter { $0.videoId == "a1aaaaaaaaa" }.count == 1)
        #expect(store.pin("a1aaaaaaaaa")?.ref == "404", "закрепление не снимается")
    }

    /// Закрепление пришло с другого устройства, пока текст открыт, — он заменяется закреплённым.
    @Test func pinFromAnotherDeviceReachesTheOpenScreen() async throws {
        store.save("a1aaaaaaaaa", StoredLyrics(synced: Self.foundLrc, plain: "Найденный", syncedSource: "lrclib", plainSource: "lrclib", syncedRef: "999", plainRef: "999"))
        model.load(track("a1aaaaaaaaa"))
        #expect(model.state == .loaded)
        #expect(fetcher.calls.isEmpty)
        fetcher.answer("a1aaaaaaaaa", result(Self.pinnedLrc, ref: "123"))
        store.setPin("a1aaaaaaaaa", pin("123"))
        try await eventually { model.stored?.syncedRef == "123" }
        #expect(model.stored?.synced == Self.pinnedLrc)
        #expect(fetcher.calls.count == 1 && fetcher.calls[0].pin?.ref == "123")
    }

    /// Найденное без закрепления получает ссылку — из неё потом строится закрепление.
    @Test func foundTextGetsItsRefForPinning() async throws {
        fetcher.answer("a1aaaaaaaaa", result(Self.foundLrc, ref: "999"))
        model.load(track("a1aaaaaaaaa"))
        try await settle()
        #expect(store.pinPlayed("a1aaaaaaaaa"))
        #expect(store.pin("a1aaaaaaaaa") == LyricsPin(source: "lrclib", ref: "999"))
    }
}
