import Foundation
import GRDB
import Synchronization
import Testing
import MelogoldCore
@testable import MelogoldData

/// Починка библиотеки (задание 0033 §3): клипы из альбомов, сохранённые до задания 0029, — на песни. Случаи — как у Linux
/// (`a_saved_clip_becomes_its_song`) и Windows (`AlbumClipsRepairTests`).
@Suite("Починка библиотеки: сохранённые клипы из альбомов — на песни")
struct AlbumClipsRepairTests {
    static let album = "MPREb_rMqWqQe5N3L"

    let database: AppDatabase
    let library: Library

    init() throws {
        database = try AppDatabase.inMemory()
        library = Library(database: database)
    }

    static let clip = row("a5JCltuobqQ")
    static let song = row("QjckqsLmb1o", type: VideoType.song)

    /// Строка альбома Tyler, The Creator: клип, а с `type` — песня или другое видео.
    static func row(_ id: String, album: String? = album, type: String = VideoType.video) -> Track {
        Track(videoId: id, title: "LEMONHEAD (feat. 42 Dugg)", artists: [ArtistRef(id: "UCsQBsZJltmLzlsJNG7HevBg", name: "Tyler, The Creator")],
              artistsText: "Tyler, The Creator", albumId: album, albumTitle: "CALL ME IF YOU GET LOST", durationMs: 131_000, videoType: type)
    }

    static func track(_ id: String) -> Track {
        Track(videoId: id, title: "Трек \(id)", artistsText: "Кино", videoType: VideoType.song)
    }

    func likedAt(_ videoId: String) throws -> Int64? {
        try database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT liked_at FROM tracks WHERE video_id = ?", arguments: [videoId]) }
    }

    func ids(_ playlist: Int64) -> [String] { library.playlistTracks(playlist).map(\.videoId) }

    // MARK: - Замена в библиотеке

    /// ♡ и места в плейлистах переходят с клипа на песню; там, где песня уже есть, клип просто убирается; своё название и
    /// закреплённый текст — тоже на песню; загрузки и история остаются за клипом.
    @Test func aSavedClipBecomesItsSong() throws {
        library.setLiked(Self.clip, true)
        let clipLikedAt = try #require(try likedAt(Self.clip.videoId))
        let mixed = try #require(library.createPlaylist(name: "Смесь", tracks: [Self.track("a"), Self.clip, Self.track("b")]))
        let both = try #require(library.createPlaylist(name: "Обе", tracks: [Self.song, Self.clip]))
        try database.writer.write { db in try db.execute(sql: "UPDATE playlist_items SET sort_key = 'a1' WHERE video_id = ?", arguments: [Self.clip.videoId]) }
        library.setTrackOverride(Self.clip.videoId, TrackOverride(title: "Лимонная голова"))
        let pin = try #require(LyricsPin(source: "lrclib", ref: "123", startTimeMs: 500))
        library.setLyricsPin(Self.clip.videoId, pin)
        library.recordPlay(Self.clip, playTimeMs: 60_000)
        library.setLiked(Self.track("x"), true)

        #expect(try library.savedAlbumClips().map(\.videoId) == [Self.clip.videoId])
        let replaced = try library.replaceClipWithSong(Self.clip.videoId, with: Self.song)
        #expect(replaced == Library.ClipReplaced(liked: true, playlists: 2, movedOverride: true, movedPin: true))

        #expect(!library.isLiked(Self.clip.videoId) && library.isLiked(Self.song.videoId))
        #expect(try likedAt(Self.song.videoId) == clipLikedAt, "дата ♡ прежняя — порядок Избранного не меняется")
        #expect(ids(mixed) == ["a", Self.song.videoId, "b"], "на том же месте")
        #expect(ids(both) == [Self.song.videoId], "песня там уже была — клип убран")
        let sortKey = try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT sort_key FROM playlist_items WHERE playlist_id = ? AND video_id = ?", arguments: [mixed, Self.song.videoId])
        }
        #expect(sortKey == nil, "ключ порядка сервера был у клипа")
        #expect(library.displayed(Self.song).title == "Лимонная голова")
        #expect(library.trackOverride(Self.clip.videoId) == nil)
        #expect(library.lyricsPin(Self.song.videoId) == pin && library.lyricsPin(Self.clip.videoId) == nil)
        #expect(library.recentHistory().map(\.track.videoId) == [Self.clip.videoId], "история — то, что звучало")
        #expect(library.track(Self.song.videoId)?.videoType == VideoType.song)
        #expect(try library.savedAlbumClips().isEmpty)
    }

    /// Своё у песни не затирается: её ♡ с её датой, её название и закреплённый текст остаются; клип своё сохраняет.
    @Test func theSongsOwnLikeOverrideAndPinStay() throws {
        library.setLiked(Self.song, true)
        let songLikedAt = try #require(try likedAt(Self.song.videoId))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE tracks SET liked_at = liked_at - 60000 WHERE video_id = ?", arguments: [Self.song.videoId])
        }
        library.setLiked(Self.clip, true)
        library.setTrackOverride(Self.song.videoId, TrackOverride(title: "Песня"))
        library.setTrackOverride(Self.clip.videoId, TrackOverride(title: "Клип"))
        let songPin = try #require(LyricsPin(source: "lrclib", ref: "1"))
        library.setLyricsPin(Self.song.videoId, songPin)
        library.setLyricsPin(Self.clip.videoId, LyricsPin(source: "lrclib", ref: "2"))

        let replaced = try library.replaceClipWithSong(Self.clip.videoId, with: Self.song)
        #expect(replaced == Library.ClipReplaced(liked: true, playlists: 0, movedOverride: false, movedPin: false))
        #expect(try likedAt(Self.song.videoId) == songLikedAt - 60_000)
        #expect(!library.isLiked(Self.clip.videoId))
        #expect(library.trackOverride(Self.song.videoId)?.title == "Песня")
        #expect(library.lyricsPin(Self.song.videoId) == songPin)
        #expect(library.trackOverride(Self.clip.videoId)?.title == "Клип")
    }

    /// Песня встаёт в Избранном на место клипа: порядок по дате ♡ не меняется.
    @Test func favoritesKeepTheirOrder() throws {
        library.setLiked(Self.track("old"), true)
        Thread.sleep(forTimeInterval: 0.002)
        library.setLiked(Self.clip, true)
        Thread.sleep(forTimeInterval: 0.002)
        library.setLiked(Self.track("new"), true)
        try library.replaceClipWithSong(Self.clip.videoId, with: Self.song)
        #expect(library.favorites().map(\.videoId) == ["new", Self.song.videoId, "old"])
    }

    /// Чинятся только сохранённые клипы из альбомов: видео без альбома, песня альбома, клип только в истории и в
    /// закладке альбома — нет.
    @Test func onlySavedAlbumClipsAreFound() throws {
        library.setLiked(Self.row("video000001", album: nil), true)
        library.setLiked(Self.row("ugc00000001", type: VideoType.ugc), true)
        library.setLiked(Self.song, true)
        let played = Self.row("played00001")
        library.recordPlay(played, playTimeMs: 60_000)
        library.setAlbumSaved(AlbumItem(browseId: Self.album, title: "CALL ME IF YOU GET LOST"), tracks: [played], true)
        #expect(try library.savedAlbumClips().isEmpty)

        library.createPlaylist(name: "Плейлист", tracks: [Self.row("listed00001")])
        #expect(try library.savedAlbumClips().map(\.videoId) == ["listed00001"])
    }

    // MARK: - Один раз после запуска

    /// Пары альбома, клипов которых в библиотеке нет, не трогаются; второй запуск ничего не спрашивает.
    @Test func theRepairRunsOnce() async throws {
        library.setLiked(Self.clip, true)
        let other = Self.row("Lqvwm3zAILI")
        let otherSong = Self.row("qz-k3DoMxkw", type: VideoType.song)
        let asked = Mutex<[String]>([])

        let outcome = await AlbumClipsRepair.run(library: library, delay: .zero) { album in
            asked.withLock { $0.append(album) }
            return [(clipId: Self.clip.videoId, song: Self.song), (clipId: other.videoId, song: otherSong)]
        }
        #expect(outcome == AlbumClipsRepair.Outcome(albums: 1, replaced: 1, retry: false))
        #expect(asked.withLock { $0 } == [Self.album])
        #expect(library.isLiked(Self.song.videoId) && library.track(otherSong.videoId) == nil)
        #expect(library.state(AlbumClipsRepair.doneKey) == "1")

        let again = await AlbumClipsRepair.run(library: library, delay: .zero) { _ in
            asked.withLock { $0.append("again") }
            return []
        }
        #expect(again == nil)
        #expect(asked.withLock { $0 } == [Self.album])
    }

    /// Альбом не загрузился (нет сети, поиск не прошёл) — отметки нет, починка повторится при следующем запуске;
    /// остальные альбомы чинятся.
    @Test func withoutNetworkTheRepairIsRepeated() async throws {
        library.setLiked(Self.clip, true)
        library.createPlaylist(name: "Плейлист", tracks: [Self.row("foreign0001", album: "MPREb_another")])

        let outcome = await AlbumClipsRepair.run(library: library, delay: .zero) { album in
            if album == "MPREb_another" { throw URLError(.notConnectedToInternet) }
            return [(clipId: Self.clip.videoId, song: Self.song)]
        }
        #expect(outcome == AlbumClipsRepair.Outcome(albums: 2, replaced: 1, retry: true))
        #expect(library.state(AlbumClipsRepair.doneKey) == nil)
        #expect(try library.savedAlbumClips().map(\.videoId) == ["foreign0001"])
    }

    /// Проверка на бота останавливает починку сразу: следующий альбом YouTube в этот запуск не спрашивают.
    @Test func aBotCheckStopsTheRepair() async throws {
        library.setLiked(Self.row("first000001", album: "MPREb_a"), true)
        library.setLiked(Self.row("second00001", album: "MPREb_b"), true)
        struct BotCheck: Error {}
        let asked = Mutex<[String]>([])

        let outcome = await AlbumClipsRepair.run(library: library, delay: .zero, twins: { album in
            asked.withLock { $0.append(album) }
            throw BotCheck()
        }, stopsAll: { $0 is BotCheck })
        #expect(outcome?.retry == true)
        #expect(asked.withLock { $0 } == ["MPREb_a"])
        #expect(library.state(AlbumClipsRepair.doneKey) == nil)
    }

    /// Нечего чинить — отметка ставится сразу, YouTube не спрашивают.
    @Test func anEmptyLibraryIsDoneAtOnce() async throws {
        let outcome = await AlbumClipsRepair.run(library: library, delay: .zero) { _ in
            Issue.record("YouTube не нужен")
            return []
        }
        #expect(outcome == AlbumClipsRepair.Outcome(albums: 0, replaced: 0, retry: false))
        #expect(library.state(AlbumClipsRepair.doneKey) == "1")
    }
}
