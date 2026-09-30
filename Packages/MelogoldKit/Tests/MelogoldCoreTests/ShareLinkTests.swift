import Foundation
import Testing
@testable import MelogoldCore

@Suite("Ссылки на снимки плейлистов — API §4.11, §7.2")
struct ShareLinkTests {
    @Test func deepLink() {
        let url = URL(string: "melogold://share?v=1&url=https%3A%2F%2Fmusic.example.com&id=Ab3dE5gH9k")!
        #expect(ShareLink.parse(url) == ShareLink(server: "https://music.example.com", shareId: "Ab3dE5gH9k"))
        #expect(ShareLink.parse(URL(string: "melogold://share?v=2&url=https%3A%2F%2Fa.b&id=Ab3dE5gH9k")!) == nil)
        #expect(ShareLink.parse(URL(string: "melogold://share?v=1&url=https%3A%2F%2Fa.b&id=short")!) == nil)
    }

    @Test func webPage() {
        #expect(ShareLink.parse(URL(string: "https://178-250-187-202.sslip.io/s/Ab3dE5gH9k")!)
            == ShareLink(server: "https://178-250-187-202.sslip.io", shareId: "Ab3dE5gH9k"))
        #expect(ShareLink.parse(URL(string: "https://example.org/melogold/s/Ab3dE5gH9k?utm=x")!)?.server == "https://example.org/melogold")
        #expect(ShareLink.parse(URL(string: "https://www.youtube.com/s/Ab3dE5gH9k")!) == nil)
        #expect(ShareLink.parse(URL(string: "https://example.org/s/Ab3dE5gH9")!) == nil)
        #expect(ShareLink.parse(URL(string: "https://example.org/x/Ab3dE5gH9k")!) == nil)
    }

    @Test func linkInsideText() {
        let text = "Слушай плейлист (https://example.org/s/Ab3dE5gH9k)."
        #expect(ShareLink.parse(text: text) == ShareLink(server: "https://example.org", shareId: "Ab3dE5gH9k"))
        #expect(ShareLink.parse(text: "melogold://share?v=1&url=https%3A%2F%2Fa.example&id=Ab3dE5gH9k, ура")?.server == "https://a.example")
        #expect(ShareLink.parse(text: "нет ссылки") == nil)
        #expect(ShareLink.parse(text: "https://example.org/about") == nil)
    }
}
