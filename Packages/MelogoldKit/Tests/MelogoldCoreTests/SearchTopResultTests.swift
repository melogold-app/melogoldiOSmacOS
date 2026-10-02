import Testing
@testable import MelogoldCore

/// Лучший результат поиска (задание 0023): исполнитель по имени, когда YouTube Music не дал карточку.
@Suite("Лучший результат поиска")
struct SearchTopResultTests {
    private let kino = MusicItem.artist(ArtistItem(browseId: "UCL9NQ06h7I0CRUcGxPWMtkQ", name: "Кино", thumbnailUrl: nil))
    private let song = MusicItem.track(Track(videoId: "xtxjm7ciwmc", title: "Кино — Группа крови", artistsText: "Кино"))

    @Test func artistWithTheQueryNameComesFirst() {
        let summary = SearchSummary(topResult: nil, items: [song, kino]).withTopResult(for: "  КИНО! ")
        #expect(summary.topResult == kino)
    }

    @Test func yoAndPunctuationDoNotMatter() {
        let artist = MusicItem.artist(ArtistItem(browseId: "UC1", name: "Ёлка", thumbnailUrl: nil))
        #expect(SearchSummary(topResult: nil, items: [artist]).withTopResult(for: "елка").topResult == artist)
    }

    @Test func cardFromYouTubeMusicWins() {
        let summary = SearchSummary(topResult: song, items: [kino]).withTopResult(for: "кино")
        #expect(summary.topResult == song)
    }

    @Test func noArtistWithThatNameMeansNoTopResult() {
        #expect(SearchSummary(topResult: nil, items: [song, kino]).withTopResult(for: "группа крови").topResult == nil)
    }
}
