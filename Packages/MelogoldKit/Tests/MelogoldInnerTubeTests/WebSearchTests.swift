import Foundation
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

private func webPage(_ name: String) throws -> ItemsPage {
    let response = try Fixture.json(name)
    let primary = response.at("contents", "twoColumnSearchResultsRenderer", "primaryContents", "sectionListRenderer", "contents")
    if primary.exists { return WebParsers.searchPage(primary) }
    return WebParsers.searchPage(response.at("onResponseReceivedCommands", 0, "appendContinuationItemsAction", "continuationItems"))
}

@Suite("Выдача обычного YouTube — фикстуры Android")
struct WebSearchTests {
    @Test(arguments: ["ru", "en"])
    func videos(language: String) throws {
        let page = try webPage("web/search-videos.\(language)")
        let tracks = page.items.compactMap(\.track)
        #expect(tracks.count >= 10)
        #expect(tracks.allSatisfy { $0.isVideo && $0.artistsText != nil })
        #expect(tracks.allSatisfy { $0.artists.first?.id?.hasPrefix("UC") == true })
        #expect(page.continuation != nil)
    }

    @Test(arguments: ["ru", "en"])
    func videosContinuation(language: String) throws {
        let page = try webPage("web/search-videos.p01.\(language)")
        #expect(!page.items.compactMap(\.track).isEmpty)
    }

    @Test(arguments: ["ru", "en"])
    func channels(language: String) throws {
        let page = try webPage("web/search-channels.\(language)")
        let channels = page.items.compactMap { if case .artist(let artist) = $0 { artist } else { nil } }
        #expect(!channels.isEmpty)
        #expect(channels.allSatisfy { $0.isChannel && $0.browseId.hasPrefix("UC") })
        #expect(channels.allSatisfy { $0.thumbnailUrl?.hasPrefix("https:") ?? true })
    }

    @Test(arguments: ["ru", "en"])
    func live(language: String) throws {
        let page = try webPage("web/search-live.\(language)")
        let tracks = page.items.compactMap(\.track)
        #expect(tracks.contains { $0.videoType == VideoType.live })
        #expect(tracks.filter { $0.videoType == VideoType.live }.allSatisfy { $0.durationMs == nil })
    }

    @Test(arguments: ["ru", "en"])
    func playlists(language: String) throws {
        let page = try webPage("web/search-playlists.\(language)")
        let playlists = page.items.compactMap { if case .playlist(let playlist) = $0 { playlist } else { nil } }
        #expect(!playlists.isEmpty)
        #expect(!playlists.contains { $0.playlistId.hasPrefix("RD") && !$0.playlistId.hasPrefix("RDCLAK") })
    }
}
