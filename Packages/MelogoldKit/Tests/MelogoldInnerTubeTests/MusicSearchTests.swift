import Foundation
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

@Suite("Выдача YouTube Music — фикстуры Android")
struct MusicSearchTests {
    @Test func songsRussian() throws {
        let page = YouTubeMusic.parseSearchPage(try Fixture.json("ytm/search-songs.ru"))
        #expect(page.items.count == 20)
        #expect(page.continuation != nil)
        let first = try #require(page.items.first?.track)
        #expect(first.videoId == "xtxjm7ciwmc")
        #expect(first.title == "Группа крови")
        #expect(first.artists == [ArtistRef(id: "UCL9NQ06h7I0CRUcGxPWMtkQ", name: "Кино")])
        #expect(first.artistsText == "Кино")
        #expect(first.albumId == "MPREb_OLmD8O5IYNS")
        #expect(first.albumTitle == "Группа крови")
        #expect(first.durationMs == 285_000)
        #expect(first.videoType == VideoType.song)
        #expect(!first.isVideo)
        #expect(first.thumbnailUrl != nil)
        #expect(first.viewsText == nil || first.viewsText?.contains("прослушиван") == true)
    }

    @Test(arguments: ["ru", "en"])
    func songsHaveArtistsAndDurations(language: String) throws {
        let page = YouTubeMusic.parseSearchPage(try Fixture.json("ytm/search-songs.\(language)"))
        let tracks = page.items.compactMap(\.track)
        #expect(tracks.count == page.items.count)
        #expect(tracks.allSatisfy { !$0.artists.isEmpty && $0.durationMs != nil })
        #expect(Set(tracks.map(\.videoId)).count == tracks.count)
    }

    @Test(arguments: ["ru", "en"])
    func summaryHasTopResultAndMixedItems(language: String) throws {
        let summary = YouTubeMusic.parseSearchSummary(try Fixture.json("ytm/search-all.\(language)"))
        let top = try #require(summary.topResult)
        if language == "ru" {
            #expect(top.track?.videoId == "xtxjm7ciwmc")
        }
        #expect(!summary.items.isEmpty)
        #expect(summary.items.contains { $0.track != nil })
        let hasAlbum = summary.items.contains { item in
            if case .album = item { return true }
            return false
        }
        #expect(hasAlbum)
        #expect(Set(summary.items.map(\.id)).count == summary.items.count)
    }

    @Test(arguments: ["ru", "en"])
    func videosAreClips(language: String) throws {
        let page = YouTubeMusic.parseSearchPage(try Fixture.json("ytm/search-videos.\(language)"))
        let tracks = page.items.compactMap(\.track)
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { $0.isVideo })
    }

    @Test(arguments: ["ru", "en"])
    func albums(language: String) throws {
        let page = YouTubeMusic.parseSearchPage(try Fixture.json("ytm/search-albums.\(language)"))
        let albums = page.items.compactMap { if case .album(let album) = $0 { album } else { nil } }
        #expect(!albums.isEmpty)
        #expect(albums.allSatisfy { $0.browseId.hasPrefix("MPREb_") })
        #expect(albums.contains { $0.year != nil })
    }

    @Test(arguments: ["ru", "en"])
    func artists(language: String) throws {
        let page = YouTubeMusic.parseSearchPage(try Fixture.json("ytm/search-artists.\(language)"))
        let artists = page.items.compactMap { if case .artist(let artist) = $0 { artist } else { nil } }
        #expect(!artists.isEmpty)
        #expect(artists.allSatisfy { $0.browseId.hasPrefix("UC") })
    }

    @Test(arguments: ["community-playlists", "featured-playlists"])
    func playlists(kind: String) throws {
        let page = YouTubeMusic.parseSearchPage(try Fixture.json("ytm/search-\(kind).ru"))
        let playlists = page.items.compactMap { if case .playlist(let playlist) = $0 { playlist } else { nil } }
        #expect(!playlists.isEmpty)
        #expect(playlists.allSatisfy { !$0.playlistId.hasPrefix("VL") })
    }

    @Test(arguments: ["ru", "en"])
    func suggestions(language: String) throws {
        let suggestions = YouTubeMusic.parseSuggestions(try Fixture.json("ytm/search-suggestions.\(language)"))
        #expect(!suggestions.isEmpty)
        #expect(suggestions.count <= 10)
        #expect(Set(suggestions).count == suggestions.count)
    }
}

@Suite("«Далее» и поток — фикстуры Android")
struct NextAndPlayerTests {
    @Test func radioQueue() throws {
        let next = YouTubeMusic.parseNext(try Fixture.json("ytm/next-radio.ru"))
        #expect(next.playlistId == "RDAMVMxtxjm7ciwmc")
        #expect(next.tracks.count == 50)
        #expect(next.continuation != nil)
        #expect(next.tracks.first?.videoId == "xtxjm7ciwmc")
        #expect(next.tracks.first?.artists.first?.id == "UCL9NQ06h7I0CRUcGxPWMtkQ")
    }

    @Test func lyricsAndRelatedTabs() throws {
        let next = YouTubeMusic.parseNext(try Fixture.json("ytm/next.ru"))
        #expect(next.lyricsBrowseId == "MPLYt_OLmD8O5IYNS-1")
        #expect(next.relatedBrowseId == "MPTRt_OLmD8O5IYNS-1")
    }

    @Test func playerResponse() throws {
        let player = PlayerResponse.parse(try Fixture.json("ytm/player-ios.ru"))
        #expect(player.status == "OK")
        #expect(player.durationMs == 284_000)
        // В фикстурах у форматов вырезаны адреса: форматов с прямой ссылкой нет.
        #expect(player.audioFormats.isEmpty)
        let loudness = try #require(player.loudnessDb)
        #expect(abs(loudness - 0.38) < 0.001)
    }
}
