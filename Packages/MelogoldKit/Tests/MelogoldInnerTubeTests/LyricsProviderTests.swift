import Foundation
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

@Suite("Источники текстов")
struct LyricsProviderTests {
    @Test func youTubeMusicPlainLyrics() throws {
        let result = try #require(YouTubeMusic.parseLyrics(try Fixture.json("ytm/lyrics.ru")))
        #expect(result.text.hasPrefix("lyrics line 1\nlyrics line 2"))
    }

    @Test func timedLyricsBecomeLrc() {
        let response = JSON([
            "contents": ["timedLyricsModel": ["lyricsData": ["timedLyricsData": [
                ["lyricLine": "Первая", "cueRange": ["startTimeMilliseconds": "12340", "endTimeMilliseconds": "15000"]],
                ["lyricLine": "Вторая", "cueRange": ["startTimeMilliseconds": 75_010]],
            ]]]],
        ])
        #expect(YouTubeMusic.parseTimedLyrics(response) == "[00:12.34]Первая\n[01:15.01]Вторая")
    }

    @Test func lrcLibPicksCloseDuration() throws {
        let json = """
        [{"id":1,"trackName":"Кукушка","artistName":"Кино","duration":400,"plainLyrics":"a","syncedLyrics":"[00:01.00]a"},
         {"id":2,"trackName":"Кукушка","artistName":"Кино","duration":402.5,"plainLyrics":"b","syncedLyrics":"[00:01.00]b"}]
        """
        let tracks = try JSONDecoder().decode([LrcLibTrack].self, from: Data(json.utf8))
        #expect(LrcLib.bestMatching(tracks, title: "Кукушка", durationMs: 403_000)?.id == 2)
        #expect(LrcLib.bestMatching(tracks, title: "Кукушка", durationMs: 300_000) == nil)
    }

    @Test func kuGouDropsCredits() {
        // Титр в строке после служебных тегов уходит вместе с ними; первая строка без титров остаётся.
        let lrc = "[ti:Song]\n[ar:Singer]\n[00:00.00]Song - Singer\n[00:00.50]Written by：Someone\n[00:01.00]Words\n[00:02.00]More"
        #expect(KuGou.normalize(lrc) == "[00:01.00]Words\n[00:02.00]More")
        #expect(KuGou.keyword(artist: "A & B", title: "Song (feat. C)") == "A、B、C - Song")
    }
}
