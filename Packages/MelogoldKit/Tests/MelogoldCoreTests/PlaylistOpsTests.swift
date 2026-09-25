import Foundation
import Testing
@testable import MelogoldCore

/// Порядок плейлиста — векторы сервера `spec/playlist-ops.vectors.json` (ключи порядка, наибольшая возрастающая
/// подпоследовательность, якоря) и ops по снимку (`PlaylistDiff`, как у Windows и Android).
@Suite("Ключи порядка, LIS, якоря и PlaylistDiff")
struct PlaylistOpsTests {
    struct Vectors: Decodable {
        let sortKeys: SortKeysSection
        let lis: [LisCase]
        let anchors: AnchorsSection
    }

    struct SortKeysSection: Decodable {
        let alphabet: String
        let maxLength: Int
        let keyBetween: [KeyCase]
        let appendChainFromNull: [String]
        let prependChainToA0: [String]
        let bisectChainBetweenA0AndA1: [String]
        let keysBetween: [KeysCase]
        let errors: [ErrorCase]
        let compareOrdinal: [CompareCase]
    }

    struct KeyCase: Decodable { let a: String?; let b: String?; let key: String }
    struct KeysCase: Decodable { let a: String?; let b: String?; let n: Int; let keys: [String] }
    struct ErrorCase: Decodable { let a: String?; let b: String? }
    struct CompareCase: Decodable { let a: String; let b: String; let cmp: Int }
    struct LisCase: Decodable { let values: [Int]; let indices: [Int] }

    struct AnchorsSection: Decodable {
        let anchorIndex: [AnchorIndexCase]
        let applyAdd: [AddCase]
        let applyRemove: [RemoveCase]
        let applyMove: [MoveCase]
        let applyReplace: [ListCase]
        let applyImport: [ListCase]
        let applyCreate: [ListCase]
    }

    struct Anchors: Decodable { let after: String?; let before: String? }
    struct AnchorIndexCase: Decodable { let list: [String]; let anchors: Anchors; let index: Int }
    struct AddCase: Decodable { let list: [String]; let ids: [String]; let anchors: Anchors; let result: [String] }
    struct RemoveCase: Decodable { let list: [String]; let videoId: String; let result: [String] }
    struct MoveCase: Decodable { let list: [String]; let videoId: String; let anchors: Anchors; let result: [String] }
    struct ListCase: Decodable { let list: [String]; let ids: [String]; let result: [String] }

    let vectors: Vectors

    init() throws {
        vectors = try SpecFiles.decode(Vectors.self, from: "playlist-ops.vectors.json")
    }

    // MARK: - sortKeys

    @Test func alphabetAndLimit() {
        #expect(vectors.sortKeys.alphabet == SortKeys.alphabet)
        #expect(vectors.sortKeys.maxLength == SortKeys.maxLength)
    }

    @Test func keyBetween() throws {
        for item in vectors.sortKeys.keyBetween {
            #expect(try SortKeys.keyBetween(item.a, item.b) == item.key, "\(item.a ?? "nil") … \(item.b ?? "nil")")
        }
    }

    @Test func chains() throws {
        var appended: [String] = []
        for _ in vectors.sortKeys.appendChainFromNull { appended.append(try SortKeys.keyBetween(appended.last, nil)) }
        #expect(appended == vectors.sortKeys.appendChainFromNull)

        var prepended: [String] = []
        for _ in vectors.sortKeys.prependChainToA0 { prepended.append(try SortKeys.keyBetween(nil, prepended.last ?? "a0")) }
        #expect(prepended == vectors.sortKeys.prependChainToA0)

        var bisected: [String] = []
        for _ in vectors.sortKeys.bisectChainBetweenA0AndA1 { bisected.append(try SortKeys.keyBetween(bisected.last ?? "a0", "a1")) }
        #expect(bisected == vectors.sortKeys.bisectChainBetweenA0AndA1)
    }

    @Test func keysBetween() throws {
        for item in vectors.sortKeys.keysBetween {
            #expect(try SortKeys.keysBetween(item.a, item.b, count: item.n) == item.keys, "\(item.a ?? "nil") … \(item.b ?? "nil") × \(item.n)")
        }
    }

    @Test func invalidBoundsThrow() {
        for item in vectors.sortKeys.errors {
            #expect(throws: SortKeys.KeyError.self, "\(item.a ?? "nil") … \(item.b ?? "nil")") { try SortKeys.keyBetween(item.a, item.b) }
        }
    }

    @Test func ordinalComparison() {
        for item in vectors.sortKeys.compareOrdinal {
            #expect(SortKeys.compare(item.a, item.b).signum() == item.cmp, "\(item.a) ? \(item.b)")
        }
    }

    // MARK: - lis

    @Test func longestIncreasingSubsequence() {
        for item in vectors.lis {
            #expect(PlaylistDiff.longestIncreasingSubsequence(item.values) == item.indices, "\(item.values)")
        }
    }

    // MARK: - anchors

    @Test func anchorFunctions() {
        let a = vectors.anchors
        for item in a.anchorIndex {
            #expect(PlaylistAnchors.anchorIndex(item.list, after: item.anchors.after, before: item.anchors.before) == item.index)
        }
        for item in a.applyAdd {
            #expect(PlaylistAnchors.applyAdd(item.list, item.ids, after: item.anchors.after, before: item.anchors.before) == item.result)
        }
        for item in a.applyRemove { #expect(PlaylistAnchors.applyRemove(item.list, item.videoId) == item.result) }
        for item in a.applyMove {
            #expect(PlaylistAnchors.applyMove(item.list, item.videoId, after: item.anchors.after, before: item.anchors.before) == item.result)
        }
        for item in a.applyReplace { #expect(PlaylistAnchors.applyReplace(item.list, item.ids) == item.result) }
        for item in a.applyImport { #expect(PlaylistAnchors.applyImport(item.list, item.ids) == item.result) }
        for item in a.applyCreate { #expect(PlaylistAnchors.applyCreate(item.list, item.ids) == item.result) }
    }

    // MARK: - PlaylistDiff

    @Test func movingOneTrackIsOneOp() {
        #expect(PlaylistDiff.changes(before: ["a", "b", "c", "d"], after: ["a", "c", "d", "b"]) == [.move(videoId: "b", after: "d", before: nil)])
    }

    @Test func newTracksAtTheStartGoBeforeTheFirstStaying() {
        #expect(PlaylistDiff.changes(before: ["a", "b"], after: ["x", "y", "a", "b"]) == [.add(videoIds: ["x", "y"], after: nil, before: "a")])
    }

    @Test func removedTracksComeFirst() {
        #expect(PlaylistDiff.changes(before: ["a", "b", "c"], after: ["c", "d"]) == [
            .remove(videoId: "a"), .remove(videoId: "b"), .add(videoIds: ["d"], after: "c", before: nil),
        ])
    }

    @Test func bigAddsAreSplitIntoChainedBlocks() {
        let fresh = (0 ..< 1200).map { "n\($0)" }
        let changes = PlaylistDiff.changes(before: ["a"], after: ["a"] + fresh)
        #expect(changes.count == 3)
        #expect(changes.last == .add(videoIds: Array(fresh[1000...]), after: "n999", before: nil))
        #expect(PlaylistDiff.apply(["a"], changes) == ["a"] + fresh)
    }

    /// Как `PlaylistDiffTest` Android и `PlaylistDiffTests` Windows: случайные правки, применённые по правилам якорей,
    /// дают новый список.
    @Test func randomEditsRoundTrip() {
        var random = SplitMix64(seed: 20_260_925)
        for _ in 0 ..< 2000 {
            let pool = (0 ..< 30).map { String(format: "v%02d", $0) }
            var before = pool.shuffled(using: &random)
            before = Array(before.prefix(Int.random(in: 0 ..< 15, using: &random)))
            var after = before
            for _ in 0 ..< Int.random(in: 0 ..< 6, using: &random) {
                switch Int.random(in: 0 ..< 3, using: &random) {
                case 0 where !after.isEmpty:
                    after.remove(at: Int.random(in: 0 ..< after.count, using: &random))
                case 1:
                    let fresh = pool.filter { !after.contains($0) }
                    if let item = fresh.randomElement(using: &random) {
                        after.insert(item, at: Int.random(in: 0 ... after.count, using: &random))
                    }
                case 2 where after.count > 1:
                    let item = after.remove(at: Int.random(in: 0 ..< after.count, using: &random))
                    after.insert(item, at: Int.random(in: 0 ... after.count, using: &random))
                default:
                    break
                }
            }
            #expect(PlaylistDiff.apply(before, PlaylistDiff.changes(before: before, after: after)) == after, "\(before) → \(after)")
        }
    }
}

/// Детерминированный генератор для повторяемых случайных проверок.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
