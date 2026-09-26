import Foundation
import Testing
@testable import MelogoldCore

/// Векторы `spec/import-ids.vectors.json`: те же id у Android, Windows и Apple.
@Suite("ImportIds — векторы")
struct ImportIdsTests {
    struct Vectors: Decodable {
        struct Case: Decodable, CustomTestStringConvertible {
            struct Input: Decodable {
                let videoId: String
                let timestampMs: Int64
                let playTimeMs: Int64
            }
            let id: String
            let input: Input
            let expected: String
            var testDescription: String { id }
        }
        let cases: [Case]
    }

    static let cases: [Vectors.Case] = (try? SpecFiles.decode(Vectors.self, from: "import-ids.vectors.json").cases) ?? []

    @Test func allVectorsLoaded() {
        #expect(Self.cases.count == 4)
    }

    @Test(arguments: cases)
    func vector(_ item: Vectors.Case) {
        #expect(ImportIds.eventId(videoId: item.input.videoId, timestampMs: item.input.timestampMs, playTimeMs: item.input.playTimeMs)
            == item.expected)
    }
}
