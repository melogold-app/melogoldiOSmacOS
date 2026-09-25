import Foundation
import Testing
@testable import MelogoldPlayback

@Suite("Поток: адреса и ошибки")
struct StreamRulesTests {
    @Test func expiryIsFiveMinutesBeforeExpire() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let url = "https://rr1---sn-x.googlevideo.com/videoplayback?expire=1790021600&itag=140"
        #expect(StreamInfo.expiry(of: url, now: now) == Date(timeIntervalSince1970: 1_790_021_600 - 300))
        #expect(StreamInfo.expiry(of: "https://x/videoplayback?itag=140", now: now) == now.addingTimeInterval(5 * 3600))
    }

    @Test func errorClassesFollowRewrite() {
        #expect(StreamError.classify("LOGIN_REQUIRED Sign in to confirm you’re not a bot") == .botCheck)
        #expect(StreamError.classify("UNPLAYABLE The uploader has not made this video available in your country") == .geo)
        #expect(StreamError.classify("ERROR Video unavailable") == .unavailable)
        #expect(StreamError.classify("AGE_CHECK_REQUIRED Sign in to confirm your age") == .age)
        #expect(StreamError(.network, "").retries == 2)
        #expect(StreamError(.geo, "").isFinal)
    }

    @Test func streamClientsConfigInRepository() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/stream-clients.json")
        let clients = try #require(StreamClients.parse(try Data(contentsOf: file)))
        #expect(clients.map(\.name) == ["VISIONOS"])
        #expect(StreamClients.parse(Data("{\"schema\":2,\"clients\":[]}".utf8)) == nil)
        #expect(StreamClients.parse(Data("{\"schema\":1,\"clients\":[{\"name\":\"X\"}]}".utf8)) == nil)
    }
}
