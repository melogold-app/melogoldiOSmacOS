import Foundation
import GRDB
import Testing
import MelogoldCore
@testable import MelogoldData

/// Слайс S6: свои названия в списках, поиск по правленому и оригинальному, «В Избранное» выделенным, закрепление текстов.
@Suite("Библиотека — свои названия и выделенное")
struct OverriddenLibraryTests {
    let database: AppDatabase
    let library: Library

    init() throws {
        database = try AppDatabase.inMemory()
        library = Library(database: database)
    }

    private func track(_ id: String, _ title: String, artist: String = "Канал", album: String? = nil) -> Track {
        Track(videoId: id, title: title, artists: [ArtistRef(id: "UC_ch", name: artist)], artistsText: artist, albumTitle: album, durationMs: 200_000)
    }

    /// Правка видна во всех списках библиотеки, а под ней в базе лежит оригинал.
    @Test func listsShowTheOverrideAndTheDatabaseKeepsTheOriginal() throws {
        let fan = track("a1aaaaaaaaa", "Кино — Звезда (live, fan upload)")
        library.setLiked(fan, true)
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride(title: "Звезда", artistsText: "Кино", albumTitle: "Концерт"))
        let shown = try #require(library.favorites().first)
        #expect(shown.title == "Звезда" && shown.artistsText == "Кино" && shown.albumTitle == "Концерт")
        #expect(shown.original?.title == "Кино — Звезда (live, fan upload)")
        #expect(library.allTracks().first?.track.title == "Звезда")
        library.recordPlay(fan, playTimeMs: 60_000)
        #expect(library.recentHistory().first?.track.title == "Звезда")
        #expect(library.mostPlayed(since: nil).first?.track.title == "Звезда")
        let id = try #require(library.createPlaylist(name: "Альбом", tracks: [fan]))
        #expect(library.playlistTracks(id).first?.albumTitle == "Концерт")
        // В базе — то, что дал YouTube
        #expect(library.track("a1aaaaaaaaa")?.title == "Кино — Звезда (live, fan upload)")
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride())
        #expect(library.favorites().first?.title == "Кино — Звезда (live, fan upload)", "«Как на YouTube»")
    }

    /// Показанный трек, записанный обратно (♡ из меню плеера, «Добавить в плейлист…»), не подменяет оригинал.
    @Test func writingAShownTrackKeepsTheOriginalInTheDatabase() throws {
        library.save([track("a1aaaaaaaaa", "Оригинал")])
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride(title: "Своё", artistsText: "Я", albumTitle: "Мой"))
        let shown = library.displayed(try #require(library.track("a1aaaaaaaaa")))
        #expect(shown.title == "Своё")
        library.setLiked(shown, true)
        _ = library.createPlaylist(name: "P", tracks: [shown])
        library.recordPlay(shown, playTimeMs: 60_000)
        library.setHidden(shown, true)
        let stored = try #require(library.track("a1aaaaaaaaa"))
        #expect(stored.title == "Оригинал" && stored.artistsText == "Канал" && stored.albumTitle == nil)
        #expect(library.hiddenTracks().first?.title == "Своё", "скрытые показываются по правке")
        library.setHidden(shown, false)
    }

    @Test func sortsByTheDisplayedTitle() {
        library.setLiked([track("a1aaaaaaaaa", "Zzz"), track("b2bbbbbbbbb", "Bbb")], true)
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride(title: "Aaa"))
        #expect(library.favorites(sort: .title).map(\.title) == ["Aaa", "Bbb"])
        #expect(library.allTracks(sort: .title).map(\.track.title) == ["Aaa", "Bbb"])
    }

    /// «В библиотеке» находит и по правленому названию, и по оригинальному.
    @Test func searchFindsByOverriddenAndOriginalNames() {
        library.setLiked(track("a1aaaaaaaaa", "Artist — Song (fan upload)", artist: "Fan"), true)
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride(title: "Красивая песня", artistsText: "Группа"))
        #expect(library.search("Красивая").map(\.videoId) == ["a1aaaaaaaaa"])
        #expect(library.search("Группа").map(\.videoId) == ["a1aaaaaaaaa"], "по правленому исполнителю")
        #expect(library.search("fan upload").map(\.videoId) == ["a1aaaaaaaaa"], "по оригинальному названию")
        #expect(library.search("Fan").map(\.videoId) == ["a1aaaaaaaaa"], "по оригинальному исполнителю")
        #expect(library.search("Красивая").first?.title == "Красивая песня", "в ответе — как показывать")
        #expect(library.search("нет такого").isEmpty)
    }

    /// «В Избранное» выделенным — одна транзакция: синк видит одно изменение, а не N.
    @Test func likingManyIsOneTransaction() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func hit() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let observation = DatabaseRegionObservation(tracking: Table("tracks")).start(in: database.writer, onError: { _ in }, onChange: { _ in counter.hit() })
        defer { observation.cancel() }
        let tracks = (0 ..< 20).map { track(String(format: "abcdefgh%03d", $0), "T\($0)") }
        library.setLiked(tracks[0], true)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(counter.count == 1)
        let changed = library.setLiked(tracks, true)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(changed == 19, "уже лайкнутый не считается")
        #expect(counter.count == 2, "20 треков — одна запись, а не 20")
        #expect(library.counts().likes == 20)
        let time = try #require(library.likedAt(tracks[0].videoId))
        library.setLiked(tracks, true)
        #expect(library.likedAt(tracks[0].videoId) == time, "повторное «В Избранное» время не сдвигает")
        library.setLiked(Array(tracks.prefix(5)), false)
        #expect(library.counts().likes == 15)
    }
}

@Suite("Закреплённый текст — база")
struct LyricsPinStoreTests {
    static let lrc = "[00:01.00]Один\n[00:02.00]Два"
    let database: AppDatabase
    let store: LyricsStore

    init() throws {
        database = try AppDatabase.inMemory()
        store = LyricsStore(database: database)
    }

    private func found(ref: String = "123", source: String = LyricsSources.lrclib, offsetMs: Int64 = 0) -> StoredLyrics {
        StoredLyrics(synced: Self.lrc, plain: "Один\nДва", syncedSource: source, plainSource: source, offsetMs: offsetMs, syncedRef: ref, plainRef: ref)
    }

    @Test func refsRoundTripAndSurviveTheStore() {
        store.save("a1aaaaaaaaa", found(ref: "MPLYt_x", source: LyricsSources.youtubeMusic))
        let row = store.lyrics("a1aaaaaaaaa")
        #expect(row?.syncedRef == "MPLYt_x" && row?.plainRef == "MPLYt_x")
        let result = store.saveFetched("b2bbbbbbbbb", baseline: nil, found: FoundLyrics(synced: Self.lrc, plain: "", syncedSource: "kugou", plainSource: nil, syncedRef: "42:abc"))
        #expect(result?.syncedRef == "42:abc" && result?.plainRef == nil)
    }

    /// Прослушал 30 с с найденным текстом — закрепляется; уже закреплённое не перезакрепляется; свой текст — никогда.
    @Test func pinPlayedPinsFoundLyricsOnceAndNeverOwnOnes() throws {
        store.save("a1aaaaaaaaa", found())
        #expect(store.pinPlayed("a1aaaaaaaaa"))
        #expect(store.pin("a1aaaaaaaaa") == LyricsPin(source: "lrclib", ref: "123"))
        // Другой поиск нашёл бы другое, но первое закрепление — общее
        store.save("a1aaaaaaaaa", found(ref: "999"))
        #expect(!store.pinPlayed("a1aaaaaaaaa"))
        #expect(store.pin("a1aaaaaaaaa")?.ref == "123")

        store.save("b2bbbbbbbbb", StoredLyrics(synced: Self.lrc, plain: nil, syncedSource: LyricsSources.user, plainSource: nil, syncedRef: "1"))
        #expect(!store.pinPlayed("b2bbbbbbbbb"), "свой текст")
        var chosen = found()
        chosen.chosen = true
        store.save("c3ccccccccc", chosen)
        #expect(!store.pinPlayed("c3ccccccccc"), "выбранный в «Найти текст»")
        store.save("d4ddddddddd", found(ref: ""))
        #expect(!store.pinPlayed("d4ddddddddd"), "без ссылки закреплять нечего")
        #expect(!store.pinPlayed("e5eeeeeeeee"), "текста нет")
    }

    @Test func shiftLaterUpdatesThePin() throws {
        store.save("a1aaaaaaaaa", found())
        #expect(store.pinPlayed("a1aaaaaaaaa"))
        store.shift("a1aaaaaaaaa", by: -500)
        #expect(store.pin("a1aaaaaaaaa")?.startTimeMs == 500, "«позже» обновляет закрепление")
        store.shift("a1aaaaaaaaa", by: -500)
        #expect(store.pin("a1aaaaaaaaa")?.startTimeMs == 1000)
        store.shift("a1aaaaaaaaa", by: 2000)
        #expect(store.pin("a1aaaaaaaaa")?.startTimeMs == nil, "«раньше» остаётся на устройстве")
        // Закрепление другого текста сдвиг не трогает
        store.setPin("a1aaaaaaaaa", LyricsPin(source: "lrclib", ref: "777", startTimeMs: 300))
        store.shift("a1aaaaaaaaa", by: -100)
        #expect(store.pin("a1aaaaaaaaa")?.startTimeMs == 300)
    }

    @Test func pinsAreOrdinaryRowsForSync() throws {
        store.setPin("a1aaaaaaaaa", LyricsPin(source: "kugou", ref: "42:abc", startTimeMs: 250))
        #expect(Library(database: database).lyricsPin("a1aaaaaaaaa") == LyricsPin(source: "kugou", ref: "42:abc", startTimeMs: 250))
        store.setPin("a1aaaaaaaaa", nil)
        #expect(store.pin("a1aaaaaaaaa") == nil)
    }
}
