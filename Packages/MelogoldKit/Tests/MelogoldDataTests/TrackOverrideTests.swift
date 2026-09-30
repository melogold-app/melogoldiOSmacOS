import Foundation
import Testing
import MelogoldCore
@testable import MelogoldData

@Suite("Свои названия треков и закреплённые тексты — библиотека")
struct TrackOverrideTests {
    @Test func cleanTrimsAndCutsAt500() {
        #expect(TrackOverride.clean("  Песня \n") == "Песня")
        #expect(TrackOverride.clean("   ") == nil)
        #expect(TrackOverride.clean(String(repeating: "я", count: 600))?.utf16.count == 500)
        let emoji = String(repeating: "a", count: 499) + "😀"
        #expect(TrackOverride.clean(emoji) == String(repeating: "a", count: 499), "пара не рвётся")
        #expect(TrackOverride(title: " ", artistsText: "", albumTitle: nil).isEmpty)
    }

    @Test func setReplaceRemoveAndAlbumForSelection() throws {
        let library = Library(database: try AppDatabase.inMemory())
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride(title: "Песня", artistsText: "Группа"))
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride(albumTitle: "Альбом"))
        #expect(library.trackOverride("a1aaaaaaaaa") == TrackOverride(albumTitle: "Альбом"), "замена целиком")
        library.setAlbum("Сборник", for: ["a1aaaaaaaaa", "b2bbbbbbbbb"])
        #expect(library.trackOverrides(["a1aaaaaaaaa", "b2bbbbbbbbb", "c3ccccccccc"]).mapValues(\.albumTitle) == ["a1aaaaaaaaa": "Сборник", "b2bbbbbbbbb": "Сборник"])
        library.setAlbum(nil, for: ["b2bbbbbbbbb"])
        #expect(library.trackOverride("b2bbbbbbbbb") == nil, "без полей правки нет")
        library.setTrackOverride("a1aaaaaaaaa", TrackOverride())
        #expect(library.allTrackOverrides().isEmpty)
    }

    @Test func pinsAreValidated() throws {
        #expect(LyricsPin(source: "lrclib", ref: " 123 ")?.ref == "123")
        #expect(LyricsPin(source: "genius", ref: "1") == nil)
        #expect(LyricsPin(source: "lrclib", ref: "  ") == nil)
        #expect(LyricsPin(source: "lrclib", ref: "1", startTimeMs: 90_000_000)?.startTimeMs == nil)
        let library = Library(database: try AppDatabase.inMemory())
        library.setLyricsPin("a1aaaaaaaaa", LyricsPin(source: "lrclib", ref: "123", startTimeMs: 500))
        #expect(library.lyricsPin("a1aaaaaaaaa") == LyricsPin(source: "lrclib", ref: "123", startTimeMs: 500))
        library.setLyricsPin("a1aaaaaaaaa", nil)
        #expect(library.lyricsPin("a1aaaaaaaaa") == nil)
    }
}
