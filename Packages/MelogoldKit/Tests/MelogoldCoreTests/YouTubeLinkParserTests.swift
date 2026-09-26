import Foundation
import Testing
@testable import MelogoldCore

/// Общие векторы ссылок YouTube (`spec/youtube-links.vectors.json`): те же случаи у Android и Windows.
@Suite("Ссылки YouTube — векторы")
struct YouTubeLinkParserTests {
    struct Vectors: Decodable {
        let cases: [Case]
    }

    struct Case: Decodable, CustomTestStringConvertible {
        let id: String
        let input: String?
        let expected: [String: JSONValue]
        var testDescription: String { id }
    }

    /// Значение ожидаемого JSON: строка, число или null — сравнивается строкой, как в тестах Windows.
    enum JSONValue: Decodable, Equatable {
        case text(String)
        case null

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let number = try? container.decode(Int64.self) {
                self = .text(String(number))
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        var string: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    static let cases: [Case] = (try? SpecFiles.decode(Vectors.self, from: "youtube-links.vectors.json").cases) ?? []

    @Test func vectorsLoaded() {
        #expect(Self.cases.count >= 60)
    }

    @Test(arguments: cases)
    func vector(_ vector: Case) {
        let actual = Self.describe(YouTubeLinkParser.parse(vector.input))
        for (key, value) in vector.expected {
            #expect(actual[key] ?? nil == value.string, "\(vector.id): \(key)")
        }
    }

    static func describe(_ target: LinkTarget) -> [String: String?] {
        switch target {
        case .video(let videoId, let playlistId, let index, let startMs):
            ["type": "Video", "videoId": videoId, "playlistId": playlistId, "index": index.map(String.init),
             "startMs": startMs.map(String.init)]
        case .playlist(let id): ["type": "Playlist", "playlistId": id]
        case .album(let id): ["type": "Album", "browseId": id]
        case .channel(let id): ["type": "Channel", "channelId": id]
        case .handle(let name): ["type": "Handle", "handle": name]
        case .legacyChannel(let url): ["type": "LegacyChannel", "url": url]
        case .search(let query): ["type": "Search", "query": query]
        case .external(let service, let url): ["type": "External", "service": service, "url": url]
        case .unsupported(let reason): ["type": "Unsupported", "reason": reason.rawValue]
        }
    }
}
