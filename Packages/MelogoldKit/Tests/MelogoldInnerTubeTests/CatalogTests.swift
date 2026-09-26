import Foundation
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

@Suite("Каталог — фикстуры Android")
struct CatalogTests {
    @Test(arguments: ["ru", "en"])
    func exploreShelvesByPurpose(language: String) throws {
        let shelves = try YouTubeMusic.parseShelves(try Fixture.json("ytm/explore.\(language)"), browseId: "FEmusic_explore")
        let page = ExplorePage(shelves: shelves, loadedAt: Date())
        let releases = try #require(page.newReleases)
        #expect(releases.items.count == 24)
        #expect(releases.items.allSatisfy { if case .album = $0 { true } else { false } })
        let moods = try #require(page.moods)
        #expect(moods.items.count == 36)
        let trending = try #require(page.trending)
        #expect(trending.tracks.count == 20)
        #expect(page.trendingPlaylistId == "OLAK5uy_lODBFYhyNVz-TGrBj1hQP-LnBFQ-vZcJM")
        #expect(page.newVideos?.tracks.isEmpty == false)
        if language == "ru" {
            #expect(trending.title == "В тренде")
        }
    }

    @Test func exploreSurvivesCacheRoundTrip() throws {
        let shelves = try YouTubeMusic.parseShelves(try Fixture.json("ytm/explore.ru"), browseId: "FEmusic_explore")
        let page = ExplorePage(shelves: shelves, loadedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let copy = try JSONDecoder().decode(ExplorePage.self, from: try JSONEncoder().encode(page))
        #expect(copy == page)
    }

    @Test func moodsGroupedByHeader() throws {
        let shelves = try YouTubeMusic.parseShelves(try Fixture.json("ytm/moods.ru"), browseId: "FEmusic_moods_and_genres")
        #expect(shelves.map(\.title) == ["Настроения и события", "Жанры"])
        let first = try #require(shelves.first?.items.first)
        guard case .mood(let mood) = first else { Issue.record("не настроение"); return }
        #expect(mood.title == "В дороге")
        #expect(mood.browseId == "FEmusic_moods_and_genres_category")
        #expect(mood.params != nil)
        #expect(mood.color != nil)
    }

    @Test func moodIsPlaylistCarousels() throws {
        let shelves = try YouTubeMusic.parseShelves(try Fixture.json("ytm/mood.ru"), browseId: "FEmusic_moods_and_genres_category")
        #expect(shelves.count == 11)
        #expect(shelves[0].title == "Хорошее настроение")
        let playlist = try #require(shelves[0].items.first)
        guard case .playlist(let item) = playlist else { Issue.record("не плейлист"); return }
        #expect(item.playlistId == "RDCLAK5uy_mkEwQuegHYB8_aAzBO8Q__6gGoaFblISw")
    }

    @Test(arguments: ["ru", "en"])
    func newReleasesGrid(language: String) throws {
        let shelves = try YouTubeMusic.parseShelves(try Fixture.json("ytm/new-releases-albums.\(language)"), browseId: "FEmusic_new_releases_albums")
        let albums = shelves.flatMap(\.items).compactMap { item -> AlbumItem? in
            if case .album(let album) = item { return album }
            return nil
        }
        #expect(albums.count > 100)
        #expect(albums.allSatisfy { $0.browseId.hasPrefix("MPREb_") && $0.typeText != nil })
    }

    @Test func albumPage() throws {
        let album = try YouTubeMusic.parseAlbum(try Fixture.json("ytm/album.ru"), browseId: "MPREb_OLmD8O5IYNS")
        #expect(album.album.title == "Группа крови")
        #expect(album.album.year == "1988")
        #expect(album.album.typeText == "Альбом")
        #expect(album.album.artists == [ArtistRef(id: "UCL9NQ06h7I0CRUcGxPWMtkQ", name: "Кино")])
        #expect(album.album.playlistId == "OLAK5uy_nRndsUhiMCq2wRW3JCnDgDwD33CUalJZU")
        #expect(album.countText == "11\u{00A0}треков • 47 минут")
        #expect(album.description?.hasPrefix("«Гру́ппа кро́ви»") == true)
        #expect(album.tracks.count == 11)
        let first = try #require(album.tracks.first)
        #expect(first.videoId == "xtxjm7ciwmc")
        #expect(first.durationMs == 285_000)
        // Исполнитель строки пустой — берётся исполнитель альбома, а не «119 млн прослушиваний».
        #expect(first.artistsText == "Кино")
        #expect(first.albumId == "MPREb_OLmD8O5IYNS")
        #expect(first.videoType == VideoType.song)
        #expect(album.tracks.allSatisfy { $0.thumbnailUrl == album.album.thumbnailUrl })
        #expect(album.shelves.count == 1)
        #expect(album.shelves.first?.title == "Релизы для вас")
    }

    @Test func albumEnglish() throws {
        let album = try YouTubeMusic.parseAlbum(try Fixture.json("ytm/album.en"), browseId: "MPREb_OLmD8O5IYNS")
        #expect(album.tracks.count == 11)
        #expect(album.album.year == "1988")
    }

    @Test func userPlaylist() throws {
        let page = try YouTubeMusic.parsePlaylist(try Fixture.json("ytm/playlist.ru"), browseId: "VLPLtest")
        #expect(page.playlist.playlistId == "PLtest")
        #expect(page.playlist.title.hasPrefix("Кино - Группа крови"))
        #expect(page.authorText == "Gavrik's Archive")
        #expect(page.tracks.count == 11)
        #expect(page.continuation == nil)
        #expect(page.tracks.allSatisfy { $0.durationMs != nil })
    }

    @Test func editorialPlaylist() throws {
        let page = try YouTubeMusic.parsePlaylist(try Fixture.json("ytm/playlist-editorial.ru"), browseId: "VLRDCLAK5uy_x")
        #expect(page.playlist.title == "Позитивный рэп и R&B")
        #expect(page.authorText == "YouTube\u{00A0}Music")
        #expect(page.tracks.count == 100)
        #expect(page.continuation != nil)
    }

    /// Длинный плейлист: продолжение в новом формате (`continuationItemRenderer` последним, ответ
    /// `onResponseReceivedActions`) — раньше такие плейлисты обрывались на первой сотне (REWRITE §3.8.2).
    @Test func longPlaylistContinuesInNewFormat() throws {
        let first = try YouTubeMusic.parsePlaylist(try Fixture.json("ytm/playlist-long.p00.ru"), browseId: "VLPL85973FA7E35D0D96")
        #expect(first.tracks.count == 100)
        #expect(first.countText?.contains("2\u{00A0}067") == true)
        #expect(first.continuation != nil)
        let next = YouTubeMusic.parsePlaylistContinuation(try Fixture.json("ytm/playlist-long.p01.ru"))
        #expect(next.items.compactMap(\.track).count == 100)
        #expect(next.continuation != nil)
        #expect(next.continuation != first.continuation)
        let overlap = Set(first.tracks.map(\.videoId)).intersection(next.items.compactMap(\.track).map(\.videoId))
        #expect(overlap.count < 5)
    }

    @Test func artistPage() throws {
        let artist = try #require(YouTubeMusic.parseArtist(try Fixture.json("ytm/artist.ru"), browseId: "UCL9NQ06h7I0CRUcGxPWMtkQ"))
        #expect(artist.name == "Кино")
        #expect(!artist.isChannel)
        #expect(artist.subscribersText == "735\u{00A0}тыс. подписчиков")
        #expect(artist.songsPlaylistId == "OLAK5uy_lB2w-20VusOYPlLbR99M7Xj6wE9Fj-7-w")
        #expect(artist.radioPlaylistId == "RDEM3rKydSTjuLx2Ffhg_if83A")
        #expect(artist.description?.isEmpty == false)
        #expect(artist.shelves.first?.tracks.count == 5)
        let albums = try #require(artist.shelves.first { $0.moreBrowseId?.hasPrefix("MPAD") == true })
        #expect(albums.items.count == 10)
        #expect(albums.moreParams != nil)
        // Подкасты и выпуски подкастов не попадают в полки.
        #expect(artist.shelves.count == 8)
    }

    /// Канал без музыкального профиля (одни видео и плейлисты) читается как канал YouTube (REWRITE §3.7.2).
    @Test(arguments: ["ru", "en"])
    func ugcChannelFallsBackToChannel(language: String) throws {
        #expect(YouTubeMusic.parseArtist(try Fixture.json("ytm/artist-ugc-channel.\(language)"), browseId: "UCy_vnPBNh9FqtyH9Qc-aiSA") == nil)
    }

    @Test func channelVideosWithContinuation() throws {
        let page = WebParsers.channelPage(channelId: "UCy_vnPBNh9FqtyH9Qc-aiSA", response: try Fixture.json("web/channel-videos.ru"))
        #expect(page.name == "Gavrik's Archive")
        #expect(page.subscribersText == "367 подписчиков")
        #expect(page.videos.count == 30)
        #expect(page.videos.allSatisfy { $0.artistsText == "Gavrik's Archive" && $0.isVideo })
        let token = try #require(page.continuation)
        #expect(!token.isEmpty)
        let next = WebParsers.gridPage(try Fixture.json("web/channel-videos.p01.ru")
            .at("onResponseReceivedActions", 0, "appendContinuationItemsAction", "continuationItems"))
        #expect(next.items.count == 30)
        #expect(next.continuation != nil)
    }

    @Test func resolveURL() throws {
        #expect(YouTubeMusic.parseResolvedURL(try Fixture.json("web/resolve-url-handle-direct.ru")) == .browse("UCKHFvArwRwQU2VbRjMpaVGw"))
        #expect(YouTubeMusic.parseResolvedURL(try Fixture.json("web/resolve-url-vanity.ru")) == .browse("UC_kRDKYrUlrbtrSiyu5Tflg"))
        #expect(YouTubeMusic.parseResolvedURL(try Fixture.json("web/resolve-url-legacy-c.en")) == .browse("UC_kRDKYrUlrbtrSiyu5Tflg"))
        #expect(YouTubeMusic.parseResolvedURL(try Fixture.json("web/resolve-url-handle.ru")) == .redirect("https://www.youtube.com/daftpunk"))
        #expect(YouTubeMusic.parseResolvedURL(try Fixture.json("web/resolve-url-not-found.ru")) == .notFound)
    }

    @Test func relatedShelves() throws {
        let shelves = MusicParsers.shelves(try Fixture.json("ytm/related.ru").at("contents", "sectionListRenderer", "contents"))
        #expect(shelves.first?.tracks.count == 20)
        #expect(shelves.contains { $0.items.contains { if case .artist = $0 { true } else { false } } })
    }
}
