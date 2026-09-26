import Foundation
import GRDB
import Testing
import MelogoldCore
@testable import MelogoldData

@Suite("Библиотека")
struct LibraryTests {
    let database: AppDatabase
    let library: Library

    init() throws {
        database = try AppDatabase.inMemory()
        library = Library(database: database)
    }

    private func track(_ id: String, _ title: String, artist: String = "Кино", ms: Int64 = 200_000) -> Track {
        Track(videoId: id, title: title, artists: [ArtistRef(id: "UC_kino", name: artist)], artistsText: artist, durationMs: ms)
    }

    @Test func likesAndFavoritesSorts() throws {
        library.setLiked(track("a1aaaaaaaaa", "Звезда"), true)
        Thread.sleep(forTimeInterval: 0.002)
        library.setLiked(track("b2bbbbbbbbb", "Апрель", ms: 300_000), true)
        #expect(library.favorites().map(\.title) == ["Апрель", "Звезда"])
        #expect(library.favorites(sort: .title).map(\.title) == ["Апрель", "Звезда"])
        #expect(library.favorites(sort: .duration).first?.title == "Апрель")
        #expect(library.isLiked("a1aaaaaaaaa"))
        library.setLiked(track("a1aaaaaaaaa", "Звезда"), false)
        #expect(!library.isLiked("a1aaaaaaaaa"))
        #expect(library.counts().likes == 1)
    }

    @Test func upsertKeepsKnownFields() throws {
        library.save([track("a1aaaaaaaaa", "Звезда")])
        library.save([Track(videoId: "a1aaaaaaaaa", title: "a1aaaaaaaaa")])
        let stored = try #require(library.track("a1aaaaaaaaa"))
        #expect(stored.title == "Звезда")
        #expect(stored.artistsText == "Кино")
        #expect(stored.artists == [ArtistRef(id: "UC_kino", name: "Кино")])
    }

    @Test func playlistsOrderAndUndo() throws {
        let id = try #require(library.createPlaylist(name: "  Дорога  ", tracks: [track("a1aaaaaaaaa", "A"), track("b2bbbbbbbbb", "B")]))
        #expect(library.add([track("c3ccccccccc", "C"), track("a1aaaaaaaaa", "A")], toPlaylist: id) == 1)
        #expect(library.playlistTracks(id).map(\.title) == ["A", "B", "C"])
        library.move("c3ccccccccc", inPlaylist: id, to: 0)
        #expect(library.playlistTracks(id).map(\.title) == ["C", "A", "B"])
        let position = library.remove("a1aaaaaaaaa", fromPlaylist: id)
        #expect(position == 1)
        #expect(library.playlistTracks(id).map(\.title) == ["C", "B"])
        library.insert(track("a1aaaaaaaaa", "A"), intoPlaylist: id, at: 1)
        #expect(library.playlistTracks(id).map(\.title) == ["C", "A", "B"])
        let playlist = try #require(library.playlist(id))
        #expect(playlist.name == "Дорога")
        #expect(playlist.trackCount == 3)
        library.deletePlaylist(id)
        #expect(library.playlists().isEmpty)
    }

    @Test func youTubeLinkAppendAndMirror() throws {
        let remote1 = [track("a1aaaaaaaaa", "A"), track("b2bbbbbbbbb", "B")]
        let id = try #require(library.createPlaylist(name: "YT", tracks: remote1, browseId: "PLx", link: .append))
        // Удалённый у себя трек «Только добавлять» не возвращает.
        library.remove("a1aaaaaaaaa", fromPlaylist: id)
        let remote2 = remote1 + [track("c3ccccccccc", "C")]
        #expect(library.applyYouTube(remote2, toPlaylist: id, mode: .append) == 1)
        #expect(library.playlistTracks(id).map(\.title) == ["B", "C"])
        library.applyYouTube([track("d4ddddddddd", "D"), track("b2bbbbbbbbb", "B")], toPlaylist: id, mode: .mirror)
        #expect(library.playlistTracks(id).map(\.title) == ["D", "B"])
        #expect(library.playlist(browseId: "VLPLx")?.id == id)
    }

    @Test func appendWithoutSnapshotOnlyRemembers() throws {
        let id = try #require(library.createPlaylist(name: "ViTune", tracks: [track("a1aaaaaaaaa", "A")], browseId: "PLy"))
        library.setLink(.append, ofPlaylist: id)
        #expect(library.applyYouTube([track("a1aaaaaaaaa", "A"), track("b2bbbbbbbbb", "B")], toPlaylist: id, mode: .append) == nil)
        #expect(library.playlistTracks(id).count == 1)
        #expect(library.applyYouTube([track("a1aaaaaaaaa", "A"), track("b2bbbbbbbbb", "B"), track("c3ccccccccc", "C")],
                                     toPlaylist: id, mode: .append) == 1)
    }

    @Test func historyRecentAndMostPlayed() throws {
        let now = EpochMs.now()
        library.recordPlay(track("a1aaaaaaaaa", "A"), playTimeMs: 3000, endedAt: now)
        #expect(library.playCount() == 0)
        library.recordPlay(track("a1aaaaaaaaa", "A"), playTimeMs: 60_000, endedAt: now - 10_000)
        library.recordPlay(track("b2bbbbbbbbb", "B"), playTimeMs: 30_000, endedAt: now)
        library.recordPlay(track("a1aaaaaaaaa", "A"), playTimeMs: 60_000, endedAt: now - 40 * 24 * 3600 * 1000)
        #expect(library.recentHistory().map(\.track.title) == ["B", "A"])
        #expect(library.mostPlayed(since: now - 7 * 24 * 3600 * 1000).map(\.playTimeMs) == [60_000, 30_000])
        #expect(library.mostPlayed(since: nil).first?.playTimeMs == 120_000)
        library.removeFromHistory("a1aaaaaaaaa")
        #expect(library.recentHistory().map(\.track.title) == ["B"])
        // Общее время остаётся.
        #expect(library.mostPlayed(since: nil).first?.track.title == "A")
        library.clearHistory()
        #expect(library.playCount() == 0)
    }

    @Test func historyOpsGoToRecorder() throws {
        final class Box: @unchecked Sendable { var kinds: [String] = [] }
        let box = Box()
        library.setHistoryOpRecorder { _, op in box.kinds.append(op.kind + (op.videoId.map { ":" + $0 } ?? "")) }
        library.removeFromHistory("a1aaaaaaaaa")
        library.clearHistory()
        #expect(box.kinds == ["history.forget:a1aaaaaaaaa", "history.clear"])
    }

    /// Задание 0007: прослушанный, лайкнутый, в плейлисте и скачанный входят; скрытый и трек только открытого альбома — нет.
    @Test func allTracksComposition() throws {
        let played = track("p1ppppppppp", "Прослушанный")
        let liked = track("l1lllllllll", "Лайкнутый")
        let listed = track("i1iiiiiiiii", "В плейлисте")
        let downloaded = track("d1ddddddddd", "Скачанный")
        let hidden = track("h1hhhhhhhhh", "Скрытый")
        let opened = track("o1ooooooooo", "Из открытого альбома")
        library.recordPlay(played, playTimeMs: 10_000)
        library.setLiked(liked, true)
        library.createPlaylist(name: "P", tracks: [listed])
        library.save([downloaded, opened])
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO downloads (video_id, state, created_at) VALUES (?, 'completed', 1)", arguments: [downloaded.videoId])
        }
        library.recordPlay(hidden, playTimeMs: 10_000)
        library.setHidden(hidden, true)
        let ids = Set(library.allTracks().map(\.track.videoId))
        #expect(ids == [played.videoId, liked.videoId, listed.videoId, downloaded.videoId])
        #expect(library.counts().allTracks == 4)
    }

    @Test func allTracksSorts() throws {
        let now = EpochMs.now()
        library.recordPlay(track("a1aaaaaaaaa", "Бета", artist: "Ария", ms: 100_000), playTimeMs: 90_000, endedAt: now - 1000)
        library.recordPlay(track("b2bbbbbbbbb", "Альфа", artist: "Кино", ms: 300_000), playTimeMs: 10_000, endedAt: now)
        library.setLiked(track("c3ccccccccc", "Гамма", artist: "Браво", ms: 200_000), true)
        // У непрослушанного — время лайка: лайк раньше прослушиваний — в конце.
        library.restoreLike("c3ccccccccc", at: now - 60_000)
        #expect(library.allTracks().map(\.track.title) == ["Альфа", "Бета", "Гамма"])
        #expect(library.allTracks(sort: .playTime).first?.track.title == "Бета")
        #expect(library.allTracks(sort: .title).map(\.track.title) == ["Альфа", "Бета", "Гамма"])
        #expect(library.allTracks(sort: .artist).map(\.track.title) == ["Бета", "Гамма", "Альфа"])
        #expect(library.allTracks(sort: .duration).map(\.track.title) == ["Альфа", "Гамма", "Бета"])
    }

    @Test func savedAlbumKeepsTracksOffline() throws {
        let album = AlbumItem(browseId: "MPREb_x", title: "Группа крови", artistsText: "Кино", year: "1988")
        library.setAlbumSaved(album, tracks: [track("a1aaaaaaaaa", "A"), track("b2bbbbbbbbb", "B")], true)
        #expect(library.isAlbumSaved("MPREb_x"))
        #expect(library.albumTracks("MPREb_x").map(\.title) == ["A", "B"])
        // Треки открытого альбома в «Все треки» не входят.
        #expect(library.allTracks().isEmpty)
        library.setAlbumSaved(album, tracks: [], false)
        #expect(!library.isAlbumSaved("MPREb_x"))
        #expect(library.savedAlbums().isEmpty)
    }

    @Test func downloadPlan() throws {
        let store = DownloadStore(database: database, directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)"))
        let id = try #require(library.createPlaylist(name: "P", tracks: [track("a1aaaaaaaaa", "A"), track("b2bbbbbbbbb", "B")]))
        store.setCollection(.playlist, key: String(id), title: "P", downloading: true)
        #expect(Set(store.pending(limit: 10)) == ["a1aaaaaaaaa", "b2bbbbbbbbb"])
        // Новый трек плейлиста докачивается сам, убранный — удаляется.
        library.add([track("c3ccccccccc", "C")], toPlaylist: id)
        library.remove("a1aaaaaaaaa", fromPlaylist: id)
        store.reconcile()
        #expect(Set(store.pending(limit: 10)) == ["b2bbbbbbbbb", "c3ccccccccc"])
        // Ручная загрузка остаётся после снятия коллекции.
        store.requestTrack(track("b2bbbbbbbbb", "B"))
        store.setCollection(.playlist, key: String(id), title: "P", downloading: false)
        #expect(store.pending(limit: 10) == ["b2bbbbbbbbb"])
        #expect(store.collections().isEmpty)
    }

    @Test func downloadWritesResumeAndComplete() throws {
        let store = DownloadStore(database: database, directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)"))
        store.requestTrack(track("a1aaaaaaaaa", "A"))
        store.prepare("a1aaaaaaaaa", itag: 140, mimeType: "audio/mp4", contentLength: 10, durationMs: 1000, loudnessDb: nil)
        #expect(store.missing("a1aaaaaaaaa") == 0..<10)
        #expect(!store.write("a1aaaaaaaaa", offset: 0, data: Data(repeating: 1, count: 4)))
        #expect(store.missing("a1aaaaaaaaa") == 4..<10)
        #expect(store.write("a1aaaaaaaaa", offset: 4, data: Data(repeating: 2, count: 6)))
        #expect(store.isComplete("a1aaaaaaaaa"))
        #expect(store.read("a1aaaaaaaaa", offset: 2, length: 4) == Data([1, 1, 2, 2]))
        #expect(store.completeInfo("a1aaaaaaaaa")?.length == 10)
        #expect(library.counts().downloads == 1)
        store.removeTrack("a1aaaaaaaaa")
        #expect(store.entry("a1aaaaaaaaa") == nil)
    }
}

@Suite("Тексты на устройстве")
struct LyricsStoreTests {
    @Test func ownLyricsAreRecordedForSync() throws {
        final class Box: @unchecked Sendable { var ids: [String] = [] }
        let box = Box()
        let store = LyricsStore(database: try AppDatabase.inMemory())
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
}
