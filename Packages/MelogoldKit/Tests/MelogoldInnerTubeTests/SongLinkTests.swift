import Foundation
import Testing
@testable import MelogoldInnerTube

@Suite("song.link — ссылки других сервисов в YouTube")
struct SongLinkTests {
    @Test(arguments: [
        "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", "https://music.apple.com/ru/album/x/123?i=456",
        "https://music.yandex.ru/album/1/track/2", "https://music.yandex.com/track/2", "https://www.deezer.com/track/3",
        "https://spotify.link/abc",
    ])
    func foreign(_ text: String) {
        #expect(SongLink.isForeign(URL(string: text)!))
    }

    @Test(arguments: ["https://music.youtube.com/watch?v=dQw4w9WgXcQ", "https://example.com/spotify", "https://yandex.ru/music"])
    func notForeign(_ text: String) {
        #expect(!SongLink.isForeign(URL(string: text)!))
    }

    @Test func prefersYouTubeMusic() {
        let both = #"{"linksByPlatform":{"youtube":{"url":"https://www.youtube.com/watch?v=a"},"youtubeMusic":{"url":"https://music.youtube.com/watch?v=b"}}}"#
        #expect(SongLink.youTubeURL(in: Data(both.utf8))?.absoluteString == "https://music.youtube.com/watch?v=b")
        let youtube = #"{"linksByPlatform":{"youtube":{"url":"https://www.youtube.com/watch?v=a"}}}"#
        #expect(SongLink.youTubeURL(in: Data(youtube.utf8))?.absoluteString == "https://www.youtube.com/watch?v=a")
        #expect(SongLink.youTubeURL(in: Data(#"{"linksByPlatform":{"spotify":{}}}"#.utf8)) == nil)
    }
}
