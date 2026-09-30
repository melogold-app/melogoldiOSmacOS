import Foundation
import Testing
import MelogoldCore
import MelogoldData
@testable import MelogoldServer

/// Свои названия (задание 0014) и закреплённые тексты (задание 0015) через `POST /sync`: ops только при виде в
/// `features.sync.kinds`, замена целиком, снятие без полей, строки с сервера, правка во время запроса не затирается.
@MainActor
@Suite("Синк своих названий и закреплённых текстов")
struct OverridesPinsSyncTests {
    typealias F = OvrFixtures

    @Test func nothingGoesToAServerThatDoesNotKnowTheKinds() async throws {
        let h = try SyncHarness(kinds: [])
        try h.track(F.video)
        h.library.setTrackOverride(F.video, TrackOverride(title: "Песня", albumTitle: "Альбом"))
        h.library.setLyricsPin(F.video, LyricsPin(source: "lrclib", ref: "123"))
        h.server.on("POST", "/sync") { request in (200, F.echo(request)) }
        await h.engine.sync()
        #expect(h.syncRequests.allSatisfy { SyncFixtures.ops($0).isEmpty })
        #expect(h.library.trackOverride(F.video)?.title == "Песня", "правка живёт здесь")
    }

    @Test func overrideGoesUpWholeAndItsRemovalWithoutFields() async throws {
        let h = try SyncHarness(kinds: F.kinds)
        try h.track(F.video)
        h.library.setTrackOverride(F.video, TrackOverride(title: "  Песня  ", artistsText: "", albumTitle: "Альбом"), at: 1_790_000_000_000)
        h.server.on("POST", "/sync") { request in (200, F.echo(request)) }

        await h.engine.sync()
        let op = try #require(h.ops(0).first { $0["kind"] as? String == "track.override.set" })
        #expect(op["videoId"] as? String == F.video)
        #expect(op["title"] as? String == "Песня" && op["artistsText"] == nil && op["albumTitle"] as? String == "Альбом")
        #expect(op["at"] as? String == "2026-09-21T14:13:20.000Z")
        #expect(try h.strings("SELECT video_id || ':' || title || ':' || album_title FROM synced_overrides") == ["\(F.video):Песня:Альбом"])

        await h.engine.sync()
        #expect(h.ops(1).isEmpty, "без правок — ни одной op")

        h.library.setTrackOverride(F.video, TrackOverride())
        await h.engine.sync()
        let removal = try #require(h.ops(2).first)
        #expect(removal["kind"] as? String == "track.override.set" && removal["videoId"] as? String == F.video)
        #expect(removal["title"] == nil && removal["albumTitle"] == nil)
        #expect(try h.strings("SELECT video_id FROM synced_overrides").isEmpty)
    }

    @Test func pinGoesUpAndItsRemovalWithoutRef() async throws {
        let h = try SyncHarness(kinds: F.kinds)
        try h.track(F.video)
        h.library.setLyricsPin(F.video, LyricsPin(source: "youtube_music", ref: "MPLYt_abc", startTimeMs: 1500))
        h.server.on("POST", "/sync") { request in (200, F.echo(request)) }
        await h.engine.sync()
        let op = try #require(h.ops(0).first { $0["kind"] as? String == "lyrics.pin.set" })
        #expect(op["source"] as? String == "youtube_music" && op["ref"] as? String == "MPLYt_abc" && op["startTimeMs"] as? Int == 1500)
        #expect(try h.strings("SELECT ref FROM synced_lyrics_pins") == ["MPLYt_abc"])

        h.library.setLyricsPin(F.video, nil)
        await h.engine.sync()
        let removal = try #require(h.ops(1).first)
        #expect(removal["kind"] as? String == "lyrics.pin.set" && removal["ref"] == nil && removal["source"] == nil)
        #expect(try h.strings("SELECT video_id FROM synced_lyrics_pins").isEmpty)
    }

    @Test func rowsOfAnotherDeviceApplyAndDeletedRowsRemove() async throws {
        let h = try SyncHarness(kinds: F.kinds)
        try h.track(F.video)
        try h.track("b2C3d4E5f6G")
        h.library.setTrackOverride("b2C3d4E5f6G", TrackOverride(title: "Старая"))
        try h.sql("INSERT INTO synced_overrides (video_id, title) VALUES ('b2C3d4E5f6G', 'Старая')")
        h.server.on("POST", "/sync") { request in
            (200, SyncFixtures.response(request, rows: [
                "overrides": "[" + F.overrideRow(F.video, title: "С Windows", album: "Альбом") + ","
                    + F.overrideRow("b2C3d4E5f6G", title: nil, album: nil, deleted: true) + "]",
                "lyricsPins": "[" + F.pinRow(F.video, source: "kugou", ref: "42:key") + "]",
            ]))
        }
        await h.engine.sync()
        #expect(h.library.trackOverride(F.video) == TrackOverride(title: "С Windows", albumTitle: "Альбом"))
        #expect(h.library.trackOverride("b2C3d4E5f6G") == nil, "снятая на другом устройстве")
        #expect(h.library.lyricsPin(F.video) == LyricsPin(source: "kugou", ref: "42:key"))
        let shown = h.library.displayed(Track(videoId: F.video, title: "Artist - Song (live)", artists: [ArtistRef(id: "UC1", name: "Channel")],
                                              artistsText: "Channel", albumId: "MPREb_x", albumTitle: "Other"))
        #expect(shown.title == "С Windows" && shown.albumTitle == "Альбом" && shown.albumId == nil && shown.artistsText == "Channel")
        await h.engine.sync()
        #expect(h.ops(1).isEmpty, "строки с сервера не уходят обратно")
    }

    @Test func editDuringTheRequestIsNotOverwritten() async throws {
        let h = try SyncHarness(kinds: F.kinds)
        try h.track(F.video)
        let library = h.library
        h.server.on("POST", "/sync") { request in
            // Человек правит, пока идёт запрос; сервер присылает правку другого устройства
            library.setTrackOverride(F.video, TrackOverride(title: "Моя"))
            return (200, SyncFixtures.response(request, rows: ["overrides": "[" + F.overrideRow(F.video, title: "Чужая", album: nil) + "]"]))
        }
        await h.engine.sync()
        #expect(h.library.trackOverride(F.video)?.title == "Моя")
        #expect(try h.strings("SELECT title FROM synced_overrides") == ["Чужая"])
        h.server.on("POST", "/sync") { request in (200, F.echo(request)) }
        await h.engine.sync()
        let op = try #require(h.syncRequests.last.flatMap { SyncFixtures.ops($0).first })
        #expect(op["kind"] as? String == "track.override.set" && op["title"] as? String == "Моя")
    }

    @Test func anotherAccountForgetsTheSnapshotsButKeepsTheEdits() async throws {
        let h = try SyncHarness(kinds: F.kinds)
        h.library.setTrackOverride(F.video, TrackOverride(title: "Песня"))
        try h.sql("INSERT INTO synced_overrides (video_id, title) VALUES (?, 'Песня')", [F.video])
        try h.sql("INSERT INTO synced_lyrics_pins (video_id, source, ref) VALUES (?, 'lrclib', '1')", [F.video])
        try await h.store.write { tx in try tx.forgetBinding() }
        #expect(try h.strings("SELECT video_id FROM synced_overrides").isEmpty)
        #expect(try h.strings("SELECT video_id FROM synced_lyrics_pins").isEmpty)
        #expect(h.library.trackOverride(F.video)?.title == "Песня")
    }
}

/// Ответы сервера для этих тестов. Вне `@MainActor`: их строят обработчики заглушки в потоках URLSession.
enum OvrFixtures {
    static let kinds = ["track.override.set", "lyrics.pin.set"]
    static let video = "a1B2c3D4e5F"

    static func overrideRow(_ videoId: String, title: String?, artist: String? = nil, album: String?, deleted: Bool = false) -> String {
        func text(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return #"{"videoId":"\#(videoId)","title":\#(text(title)),"artistsText":\#(text(artist)),"albumTitle":\#(text(album)),"updatedAt":"2026-09-25T10:00:00.000Z","deleted":\#(deleted)}"#
    }

    static func pinRow(_ videoId: String, source: String?, ref: String?, start: Int? = nil, deleted: Bool = false) -> String {
        func text(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return #"{"videoId":"\#(videoId)","source":\#(text(source)),"ref":\#(text(ref)),"startTimeMs":\#(start.map(String.init) ?? "null"),"updatedAt":"2026-09-25T10:00:00.000Z","deleted":\#(deleted)}"#
    }

    /// Ответ, в котором сервер возвращает строки на каждую принятую op правки и закрепления.
    static func echo(_ request: StubServer.Request) -> String {
        let ops = SyncFixtures.ops(request)
        let overrides = ops.filter { $0["kind"] as? String == "track.override.set" }.map { op in
            let empty = op["title"] == nil && op["artistsText"] == nil && op["albumTitle"] == nil
            return overrideRow(op["videoId"] as? String ?? "", title: op["title"] as? String, artist: op["artistsText"] as? String,
                               album: op["albumTitle"] as? String, deleted: empty)
        }
        let pins = ops.filter { $0["kind"] as? String == "lyrics.pin.set" }.map { op in
            pinRow(op["videoId"] as? String ?? "", source: op["source"] as? String, ref: op["ref"] as? String,
                   start: op["startTimeMs"] as? Int, deleted: op["ref"] == nil)
        }
        return SyncFixtures.response(request, rows: ["overrides": "[" + overrides.joined(separator: ",") + "]", "lyricsPins": "[" + pins.joined(separator: ",") + "]"])
    }

}
