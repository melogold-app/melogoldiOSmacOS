import Foundation
import Testing
@testable import MelogoldCore

@Suite("Ссылки melogold:// — API §7.2")
struct MelogoldLinkTests {
    private let sid = "6f1c2c0e-8a3b-4f7e-9c1d-2b5e7a9f0c11"
    private let token = "q3JdV0hZxK2mP9sT4uW7yB1cE5fH8jL0nR3vX6zA2dG"

    @Test func serverLink() throws {
        let url = try #require(URL(string: "melogold://server?v=1&url=https%3A%2F%2FMusic.Example.com%2F&sid=\(sid)"))
        #expect(MelogoldLink.parse(url) == .success(.server(url: "https://music.example.com", insecure: false, serverId: sid)))
    }

    @Test func serverLinkWithoutSid() throws {
        let url = try #require(URL(string: "melogold://server?v=1&url=http%3A%2F%2F192.168.1.50%3A8080"))
        #expect(MelogoldLink.parse(url) == .success(.server(url: "http://192.168.1.50:8080", insecure: true, serverId: nil)))
    }

    @Test func serverLinkPublicHttpIsRefused() throws {
        let url = try #require(URL(string: "melogold://server?v=1&url=http%3A%2F%2Fexample.com"))
        #expect(MelogoldLink.parse(url) == .failure(.badServer(.httpsRequired)))
    }

    @Test func serverLinkBadSid() throws {
        let url = try #require(URL(string: "melogold://server?v=1&url=example.com&sid=NOT-A-UUID"))
        #expect(MelogoldLink.parse(url) == .failure(.badParameters))
    }

    @Test func inviteLink() throws {
        let url = try #require(URL(string: "melogold://link?v=1&mode=invite&server=https%3A%2F%2Fexample.com&sid=\(sid)&token=\(token)"))
        #expect(MelogoldLink.parse(url) == .success(.link(mode: .invite, server: "https://example.com", serverId: sid, token: token)))
    }

    @Test func requestLinkParameterOrderDoesNotMatter() throws {
        let url = try #require(URL(string: "melogold://link?token=\(token)&sid=\(sid)&server=example.com&mode=request&v=1&extra=1"))
        #expect(MelogoldLink.parse(url) == .success(.link(mode: .request, server: "https://example.com", serverId: sid, token: token)))
    }

    @Test func wrongVersionOrHost() throws {
        #expect(MelogoldLink.parse(try #require(URL(string: "melogold://server?v=2&url=example.com"))) == .failure(.unsupportedVersion))
        #expect(MelogoldLink.parse(try #require(URL(string: "melogold://other?v=1"))) == .failure(.notMelogold))
        #expect(MelogoldLink.parse(try #require(URL(string: "https://example.com"))) == .failure(.notMelogold))
    }

    @Test func badToken() throws {
        let url = try #require(URL(string: "melogold://link?v=1&mode=invite&server=example.com&sid=\(sid)&token=short"))
        #expect(MelogoldLink.parse(url) == .failure(.badParameters))
    }
}
