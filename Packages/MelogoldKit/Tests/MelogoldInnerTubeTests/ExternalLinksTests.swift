import Foundation
import Testing
@testable import MelogoldInnerTube

/// Ссылки других сервисов (задание 0019): какой сервис и что за ссылка, слова для поиска из заголовка страницы,
/// ответ song.link.
@Suite("Ссылки других музыкальных сервисов")
struct ExternalLinksTests {
    @Test(arguments: [
        ("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=x", MusicService.spotify, MusicLinkKind.track),
        ("https://open.spotify.com/intl-de/album/6N9PS4QXF1D0OWPk0Sxtb4", .spotify, .album),
        ("https://open.spotify.com/artist/0gxyHStUsqpMadRV0Di1Qt", .spotify, .artist),
        ("https://spotify.link/abc", .spotify, .unknown),
        ("https://music.apple.com/ru/album/never-gonna/1558533900?i=1558534271", .appleMusic, .track),
        ("https://music.apple.com/ru/album/never-gonna/1558533900", .appleMusic, .album),
        ("https://music.yandex.ru/album/1/track/2", .yandexMusic, .track),
        ("https://music.yandex.com/users/x/playlists/3", .yandexMusic, .playlist),
        ("https://www.deezer.com/fr/track/3135556", .deezer, .track),
        ("https://tidal.com/browse/track/1", .tidal, .track),
        ("https://soundcloud.com/rick-astley-official/never-gonna", .soundCloud, .track),
    ])
    func parses(_ text: String, _ service: MusicService, _ kind: MusicLinkKind) throws {
        let link = try #require(MusicServiceLink.parse("Послушай: \(text)."))
        #expect(link.service == service)
        #expect(link.kind == kind)
        #expect(!link.url.absoluteString.hasSuffix("."))
    }

    @Test func ignoresOtherLinks() {
        #expect(MusicServiceLink.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(MusicServiceLink.parse("https://open.spotify.com/show/1") == nil)
        #expect(MusicServiceLink.parse("просто текст") == nil)
    }

    static func link(_ text: String) -> MusicServiceLink { MusicServiceLink.parse(text)! }

    @Test func spotifyTitle() {
        let html = #"<html><head><title>Never Gonna Give You Up - song and lyrics by Rick Astley | Spotify</title>"#
        #expect(PageTitles.searchText(Self.link("https://open.spotify.com/track/x"), html: html) == "Never Gonna Give You Up Rick Astley")
        let og = #"<meta property="og:title" content="Never Gonna Give You Up"/><meta content="Rick Astley · Whenever You Need Somebody · Song · 1987" property="og:description">"#
        #expect(PageTitles.searchText(Self.link("https://open.spotify.com/track/x"), html: og) == "Never Gonna Give You Up Rick Astley")
    }

    @Test func appleYandexTidalDeezerSoundCloudTitles() {
        #expect(PageTitles.searchText(Self.link("https://music.apple.com/ru/album/x/1?i=2"),
                                      html: "<title>Never Gonna Give You Up - Song with Lyrics by Rick Astley - Apple Music</title>") == "Never Gonna Give You Up Rick Astley")
        #expect(PageTitles.searchText(Self.link("https://music.yandex.ru/album/1/track/2"),
                                      html: #"<meta property="og:title" content="Группа крови"><meta property="og:description" content="Кино • Трек • 1988">"#) == "Группа крови Кино")
        #expect(PageTitles.searchText(Self.link("https://music.yandex.ru/album/1/track/2"),
                                      html: "<title>Группа крови Кино слушать онлайн на Яндекс Музыке</title>") == "Группа крови Кино")
        #expect(PageTitles.searchText(Self.link("https://tidal.com/browse/track/1"),
                                      html: "<title>Never Gonna Give You Up by Rick Astley on TIDAL</title>") == "Never Gonna Give You Up Rick Astley")
        #expect(PageTitles.searchText(Self.link("https://www.deezer.com/track/1"),
                                      html: "<title>Daft Punk - Harder, Better, Faster, Stronger | Deezer</title>") == "Daft Punk Harder, Better, Faster, Stronger")
        #expect(PageTitles.searchText(Self.link("https://soundcloud.com/a/b"), html: "<title>SoundCloud - Hear the world’s sounds</title>") == nil)
    }

    @Test func entitiesAndInvisibleMarks() {
        #expect(PageTitles.clean("Rock &amp; Roll&#39;s &#x41;\u{200E}\u{00A0}") == "Rock & Roll's A")
    }

    @Test func songLinkAnswer() {
        let both = #"{"linksByPlatform":{"youtube":{"url":"https://www.youtube.com/watch?v=a"},"youtubeMusic":{"url":"https://music.youtube.com/watch?v=b"}}}"#
        #expect(ExternalLinks.youTubeURL(in: Data(both.utf8))?.absoluteString == "https://music.youtube.com/watch?v=b")
        #expect(ExternalLinks.youTubeURL(in: Data(#"{"linksByPlatform":{"spotify":{}}}"#.utf8)) == nil)
    }

    @Test func playlistsAreNotResolved() async {
        #expect(await ExternalLinks.resolve(Self.link("https://open.spotify.com/playlist/1")) == .notFound)
    }
}
