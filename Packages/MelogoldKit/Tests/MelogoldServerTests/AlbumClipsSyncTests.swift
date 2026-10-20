import Foundation
import Testing
import MelogoldCore
import MelogoldData
@testable import MelogoldServer

/// Починка клипов из альбомов (задание 0033 §3) уходит на сервер обычными правками: снятый ♡ у клипа и ♡ у песни с
/// прежней датой, замена трека в плейлисте, правка и закрепление у песни и их снятие у клипа. Так её получают остальные
/// устройства аккаунта.
@MainActor
@Suite("Синк починки клипов из альбомов")
struct AlbumClipsSyncTests {
    static let clip = "a5JCltuobqQ"
    static let song = Track(videoId: "QjckqsLmb1o", title: "LEMONHEAD (feat. 42 Dugg)", artistsText: "Tyler, The Creator",
                            albumId: "MPREb_rMqWqQe5N3L", albumTitle: "CALL ME IF YOU GET LOST", durationMs: 131_000, videoType: VideoType.song)

    @Test func theReplacementGoesUpAsOrdinaryEdits() async throws {
        let h = try SyncHarness(kinds: OvrFixtures.kinds)
        for id in ["t1", "t2"] { try h.track(id) }
        try h.track(Self.clip, likedAt: 1_790_000_000_000)
        try h.sql("INSERT INTO synced_likes (video_id) VALUES (?)", [Self.clip])
        try h.sql("INSERT INTO playlists (sync_id, name, created_at) VALUES ('P1', 'Дорога', 1)")
        try h.sql("INSERT INTO playlist_items (playlist_id, video_id, position, sort_key, added_at) VALUES (1, 't1', 0, 'a0', 1), (1, ?, 1, 'a1', 1), (1, 't2', 2, 'a2', 1)",
                  [Self.clip])
        try h.sql("INSERT INTO synced_playlists (sync_id, name, video_ids) VALUES ('P1', 'Дорога', ?)", ["t1\n\(Self.clip)\nt2"])
        h.library.setTrackOverride(Self.clip, TrackOverride(title: "Лимонная голова"), at: 1_790_000_000_000)
        try h.sql("INSERT INTO synced_overrides (video_id, title) VALUES (?, 'Лимонная голова')", [Self.clip])
        h.library.setLyricsPin(Self.clip, LyricsPin(source: "lrclib", ref: "123"), at: 1_790_000_000_000)
        try h.sql("INSERT INTO synced_lyrics_pins (video_id, source, ref) VALUES (?, 'lrclib', '123')", [Self.clip])

        try h.library.replaceClipWithSong(Self.clip, with: Self.song)
        h.server.on("POST", "/sync") { request in (200, SyncFixtures.response(request)) }
        await h.engine.sync()

        let sent = h.ops(0)
        func ops(_ kind: String) -> [[String: Any]] { sent.filter { $0["kind"] as? String == kind } }
        let likes = ops("like.set")
        #expect(likes.count == 2)
        let liked = try #require(likes.first { $0["videoId"] as? String == Self.song.videoId })
        #expect(liked["liked"] as? Bool == true)
        #expect(liked["likedAt"] as? String == "2026-09-21T14:13:20.000Z", "дата ♡ клипа")
        let likedTrack = try #require((liked["tracks"] as? [[String: Any]])?.first)
        #expect(likedTrack["videoType"] as? String == "song")
        let unliked = try #require(likes.first { $0["videoId"] as? String == Self.clip })
        #expect(unliked["liked"] as? Bool == false)

        let removed: [String] = ops("playlist.item.remove").compactMap { $0["videoId"] as? String }
        #expect(removed == [Self.clip])
        let added = try #require(ops("playlist.items.add").first)
        #expect(added["videoIds"] as? [String] == [Self.song.videoId])
        #expect(added["after"] as? String == "t1", "на месте клипа")

        let overrides = ops("track.override.set")
        let songOverride = try #require(overrides.first { $0["videoId"] as? String == Self.song.videoId })
        #expect(songOverride["title"] as? String == "Лимонная голова")
        let clipOverride = try #require(overrides.first { $0["videoId"] as? String == Self.clip })
        #expect(clipOverride["title"] == nil, "у клипа правка снята")
        let pins = ops("lyrics.pin.set")
        let songPin = try #require(pins.first { $0["videoId"] as? String == Self.song.videoId })
        #expect(songPin["ref"] as? String == "123")
        let clipPin = try #require(pins.first { $0["videoId"] as? String == Self.clip })
        #expect(clipPin["ref"] == nil, "у клипа закрепление снято")
    }
}
