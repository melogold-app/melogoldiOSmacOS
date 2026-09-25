import Foundation
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

/// Живые запросы к YouTube — только с `MELOGOLD_LIVE=1` (как у Windows): CI их не гоняет.
@Suite("Живой YouTube", .enabled(if: ProcessInfo.processInfo.environment["MELOGOLD_LIVE"] == "1"))
struct LiveYouTubeTests {
    let catalog = YouTubeMusic(client: InnerTubeClient(preferredLanguages: ["ru-RU"]))

    @Test func searchSongs() async throws {
        let page = try await catalog.search("кино группа крови", filter: .songs)
        #expect(page.items.compactMap(\.track).count >= 5)
    }

    @Test func searchWebVideos() async throws {
        let page = try await catalog.searchWeb("кино группа крови live", filter: .videos)
        #expect(page.items.compactMap(\.track).count >= 5)
    }

    @Test func suggestions() async throws {
        let suggestions = try await catalog.suggestions("кино")
        #expect(!suggestions.isEmpty)
    }

    @Test func streamThroughVisionOSClient() async throws {
        try await catalog.client.ensureVisitorData()
        let visitor = await catalog.client.visitorData
        #expect(visitor != nil)
        let player = try await catalog.player(videoId: "xtxjm7ciwmc", profile: .visionOS)
        #expect(player.status == "OK", "\(player.status) \(player.reason ?? "")")
        let format = try #require(player.audioFormats.first { $0.itag == 140 })
        var request = URLRequest(url: try #require(URL(string: format.url)))
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(data.count == 65_536)
        // m4a DASH: первые байты — бокс ftyp
        #expect(String(decoding: data[4..<8], as: UTF8.self) == "ftyp")
        print("itag 140:", format.mimeType, format.contentLength ?? -1, "loudness", player.loudnessDb ?? .nan)
    }
}
