import Foundation
import Testing
@testable import MelogoldCore

/// Свои названия треков (задание 0014): применение правки, оригинал под ней, очередь и база всегда получают оригинал.
@Suite("Свои названия — применение правки")
struct TrackOverrideApplyTests {
    let track = Track(
        videoId: "a1aaaaaaaaa", title: "Artist — Song (live, fan upload)", artists: [ArtistRef(id: "UC1", name: "Fan Channel")],
        artistsText: "Fan Channel", albumId: "MPREb_1", albumTitle: "YouTube Album", durationMs: 200_000, thumbnailUrl: "https://i/1.jpg"
    )

    @Test func emptyFieldsStayAsOnYouTube() {
        let shown = TrackOverride(title: "Song").apply(to: track)
        #expect(shown.title == "Song")
        #expect(shown.artistsText == "Fan Channel", "пустое поле — как на YouTube")
        #expect(shown.artists == track.artists, "карту исполнителей убирает только правка исполнителя")
        #expect(shown.albumTitle == "YouTube Album" && shown.albumId == "MPREb_1")
        #expect(TrackOverride().apply(to: track) == track, "правки нет — трек как есть")
    }

    @Test func artistAndAlbumOverridesDropYouTubeLinks() {
        let shown = TrackOverride(title: "Song", artistsText: "Artist", albumTitle: "Мой альбом").apply(to: track)
        #expect(shown.artistsText == "Artist" && shown.artists.isEmpty && shown.primaryArtistId == nil)
        #expect(shown.albumTitle == "Мой альбом" && shown.albumId == nil)
        #expect(shown.thumbnailUrl == track.thumbnailUrl && shown.durationMs == track.durationMs)
    }

    /// Показанный трек помнит оригинал: повторная правка берёт его, а не наслаивается; снятая правка возвращает оригинал.
    @Test func shownTrackRemembersOriginal() {
        let shown = TrackOverride(title: "Song").apply(to: track)
        #expect(shown.isOverridden && shown.original?.title == track.title)
        #expect(shown.raw == track, "raw возвращает то, что дал YouTube")
        let again = TrackOverride(artistsText: "Artist").apply(to: shown)
        #expect(again.title == track.title, "новая правка заменяет прежнюю, а не дополняет её")
        #expect(again.artistsText == "Artist" && again.original?.title == track.title)
        #expect(TrackOverride().apply(to: shown) == track, "правка снята — оригинал")
        #expect(track.raw == track && !track.isOverridden)
    }

    /// В JSON очереди и на сервер уходит оригинал: правка живёт в своей таблице.
    @Test func codableWritesTheOriginal() throws {
        let shown = TrackOverride(title: "Мой заголовок", albumTitle: "Мой альбом").apply(to: track)
        let data = try JSONEncoder().encode(shown)
        let restored = try JSONDecoder().decode(Track.self, from: data)
        #expect(restored == track)
        #expect(String(decoding: data, as: UTF8.self).contains("Мой") == false)
    }

    @Test func statOverrideKeepsTheFields() {
        let value = TrackOverride(title: "A", artistsText: nil, albumTitle: "C").statOverride
        #expect(value == StatOverride(title: "A", artistsText: nil, albumTitle: "C"))
    }
}

@Suite("Выделенные треки — правила")
struct SelectionRulesTests {
    func track(_ id: String, album: String? = nil, live: Bool = false) -> Track {
        Track(videoId: id, title: id, albumTitle: album, videoType: live ? VideoType.live : nil)
    }

    /// «Слушать» и «Новый плейлист» берут выделенное в порядке списка, а не в порядке нажатий.
    @Test func selectedIsInListOrderWithoutDuplicates() {
        let list = [track("a"), track("b"), track("c"), track("b")]
        #expect(SelectionRules.selected(in: list, ids: ["c", "a", "b"]).map(\.videoId) == ["a", "b", "c"])
        #expect(SelectionRules.selected(in: list, ids: []).isEmpty)
    }

    @Test func commonAlbumOnlyWhenEveryoneHasTheSame() {
        #expect(SelectionRules.commonAlbum([" Альбом ", "Альбом"]) == "Альбом")
        #expect(SelectionRules.commonAlbum(["Альбом", "Другой"]) == nil)
        #expect(SelectionRules.commonAlbum(["Альбом", nil]) == nil, "у одного альбома нет")
        #expect(SelectionRules.commonAlbum(["Альбом", "  "]) == nil)
        #expect(SelectionRules.commonAlbum([]) == nil)
        #expect(SelectionRules.commonAlbum(of: [track("a", album: "Х"), track("b", album: "Х")]) == "Х")
    }

    @Test func downloadSkipsBusyAndLive() {
        let list = [track("a"), track("b"), track("c", live: true), track("d"), track("a")]
        #expect(SelectionRules.toDownload(list, busy: ["b"]).map(\.videoId) == ["a", "d"], "скачанное, трансляции и повторы пропущены")
        #expect(SelectionRules.toDownload([track("a")], busy: ["a"]).isEmpty)
    }
}

@Suite("Ссылки «Поделиться»")
struct ShareURLsTests {
    @Test func youTubeLinks() {
        let song = Track(videoId: "dQw4w9WgXcQ", title: "Song", videoType: VideoType.song)
        let video = Track(videoId: "dQw4w9WgXcQ", title: "Clip", videoType: VideoType.ugc)
        #expect(ShareURLs.track(song).absoluteString == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(ShareURLs.track(video).absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(ShareURLs.album("MPREb_x").absoluteString == "https://music.youtube.com/browse/MPREb_x")
        #expect(ShareURLs.artist("UC1", isChannel: false).absoluteString == "https://music.youtube.com/channel/UC1")
        #expect(ShareURLs.artist("UC1", isChannel: true).absoluteString == "https://www.youtube.com/channel/UC1")
        #expect(ShareURLs.playlist("VLPL123").absoluteString == "https://music.youtube.com/playlist?list=PL123")
    }

    @Test func watchVideosTakesFirst50VideoIds() {
        let ids = (0 ..< 60).map { String(format: "abcdefgh%03d", $0) }
        let url = ShareURLs.watchVideos(["local-file", "short"] + ids)
        let parts = url?.absoluteString.components(separatedBy: "video_ids=").last?.split(separator: ",")
        #expect(parts?.count == 50 && parts?.first == "abcdefgh000")
        #expect(ShareURLs.watchVideos(["local", "x"]) == nil)
    }

    @Test func messageIsTitleArtistAndLink() throws {
        let url = try #require(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(ShareURLs.message(title: " Song ", subtitle: "Artist", url: url) == "Song — Artist\nhttps://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(ShareURLs.message(title: "Song", subtitle: nil, url: url).hasPrefix("Song\n"))
        #expect(ShareURLs.message(title: "", subtitle: "", url: url) == url.absoluteString)
    }

    @Test func melogoldShareRoundTripsThroughTheParser() throws {
        let url = try #require(ShareURLs.melogoldShare(server: "https://178-250-187-202.sslip.io", shareId: "Ab3dE6gH9j"))
        let parsed = try #require(ShareLink.parse(url))
        #expect(parsed.shareId == "Ab3dE6gH9j" && parsed.server == "https://178-250-187-202.sslip.io")
    }
}

@Suite("Закреплённый текст — правила")
struct LyricsPinRulesTests {
    func found(synced: String? = "[00:01.00]Один", plain: String? = "Один", source: String = LyricsSources.lrclib, ref: String? = "123", offsetMs: Int64 = 0) -> StoredLyrics {
        StoredLyrics(synced: synced, plain: plain, syncedSource: synced == nil ? nil : source, plainSource: plain == nil ? nil : source,
                     offsetMs: offsetMs, syncedRef: synced == nil ? nil : ref, plainRef: plain == nil ? nil : ref)
    }

    @Test func pinOfFoundLyricsIsTheShownSide() {
        #expect(LyricsPinRules.pin(of: found()) == LyricsPin(source: "lrclib", ref: "123"))
        #expect(LyricsPinRules.pin(of: found(synced: nil)) == LyricsPin(source: "lrclib", ref: "123"), "нет синхронного — обычный")
        // Синхронный от YouTube Music, обычный от LrcLib: закрепляется синхронный
        var mixed = found(source: LyricsSources.youtubeMusic, ref: "MPLYt_a")
        mixed.plainSource = LyricsSources.lrclib
        mixed.plainRef = "77"
        #expect(LyricsPinRules.pin(of: mixed) == LyricsPin(source: "youtube_music", ref: "MPLYt_a"))
        #expect(LyricsPinRules.pin(of: found(source: LyricsSources.kugou, ref: "42:abc"))?.ref == "42:abc")
    }

    @Test func ownAndRefLessLyricsAreNeverPinned() {
        #expect(LyricsPinRules.pin(of: found(source: LyricsSources.user)) == nil, "набранный текст")
        #expect(LyricsPinRules.pin(of: found(source: LyricsSources.file)) == nil, "текст из файла")
        var chosen = found()
        chosen.chosen = true
        #expect(LyricsPinRules.pin(of: chosen) == nil, "выбранный в «Найти текст»")
        #expect(LyricsPinRules.pin(of: found(ref: nil)) == nil, "ссылки нет")
        #expect(LyricsPinRules.pin(of: found(source: LyricsSources.melogold)) == nil, "общий текст сообщества")
        #expect(LyricsPinRules.pin(of: found(synced: "", plain: "")) == nil, "пусто")
    }

    @Test func shiftLaterIsThePinsStartTime() throws {
        #expect(LyricsPinRules.pin(of: found(offsetMs: -1500))?.startTimeMs == 1500)
        #expect(LyricsPinRules.pin(of: found(offsetMs: 800))?.startTimeMs == nil, "«раньше» остаётся на устройстве")
        let pin = try #require(LyricsPin(source: "lrclib", ref: "123"))
        #expect(LyricsPinRules.shifted(pin, row: found(offsetMs: -500))?.startTimeMs == 500)
        #expect(LyricsPinRules.shifted(pin, row: found(offsetMs: 0)) == nil, "менять нечего")
        #expect(LyricsPinRules.shifted(pin, row: found(ref: "999", offsetMs: -500)) == nil, "закрепление этот текст не показывает")
    }

    @Test func rowShowsThePinBySourceAndRef() throws {
        let pin = try #require(LyricsPin(source: "lrclib", ref: "123"))
        #expect(LyricsPinRules.shows(found(), pin))
        #expect(!LyricsPinRules.shows(found(ref: "124"), pin))
        #expect(!LyricsPinRules.shows(found(source: LyricsSources.kugou), pin))
        #expect(!LyricsPinRules.shows(nil, pin))
        #expect(LyricsPinRules.shows(found(synced: nil), pin), "показывает обычной стороной")
    }

    /// Записать найденный текст с той же ссылкой заново (текст, найденный до ссылок): ссылка дописывается.
    @Test func mergeFetchedRecordsTheRefOfTheSameText() {
        let stored = StoredLyrics(synced: "[00:01.00]Один", plain: "Один", syncedSource: "lrclib", plainSource: "lrclib")
        let result = LyricsRules.mergeFetched(
            baseline: stored, current: stored,
            found: FoundLyrics(synced: "[00:01.00]Один", plain: "Один", syncedSource: "lrclib", plainSource: "lrclib", syncedRef: "123", plainRef: "123")
        )
        #expect(result?.syncedRef == "123" && result?.plainRef == "123")
        #expect(LyricsRules.forgetFound(result) == nil, "«Искать заново» забывает и ссылки")
    }

    @Test func ownEditKeepsOnlyRefsOfUntouchedSides() {
        let row = found(synced: "[00:01.00]Один", plain: "Один")
        let saved = LyricsRules.saveOwn(current: row, synced: "[00:02.00]Мой", plain: nil, source: LyricsSources.user, language: nil)
        #expect(saved.syncedRef == nil, "заменённая сторона — уже не поставщика")
        #expect(saved.plainRef == "123", "обычная осталась найденной")
    }
}
