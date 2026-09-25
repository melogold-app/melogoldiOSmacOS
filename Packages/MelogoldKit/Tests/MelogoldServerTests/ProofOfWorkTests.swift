import CryptoKit
import Foundation
import Testing
@testable import MelogoldServer

struct PowVectors: Decodable {
    struct Solution: Decodable, Sendable, CustomTestStringConvertible {
        let challenge: String
        let bits: Int
        let nonce: String
        let sha256: String
        var testDescription: String { "\(bits) бит" }
    }

    struct ZeroBits: Decodable, Sendable, CustomTestStringConvertible {
        let sha256: String
        let bits: Int
        var testDescription: String { "\(bits)" }
    }

    let solutions: [Solution]
    let leadingZeroBits: [ZeroBits]
}

@Suite("Proof-of-work — векторы spec/pow.vectors.json")
struct ProofOfWorkTests {
    static let vectors = try? SpecFiles.decode(PowVectors.self, from: "pow.vectors.json")

    @Test func vectorsAreLoaded() {
        #expect((Self.vectors?.solutions.count ?? 0) >= 5)
    }

    @Test(arguments: vectors?.solutions ?? [])
    func firstNonce(_ solution: PowVectors.Solution) {
        #expect(ProofOfWork.firstNonce(challenge: solution.challenge, bits: solution.bits) == solution.nonce)
        let digest = SHA256.hash(data: Data("\(solution.challenge):\(solution.nonce)".utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == solution.sha256)
    }

    @Test(arguments: vectors?.leadingZeroBits ?? [])
    func leadingZeroBits(_ vector: PowVectors.ZeroBits) {
        #expect(ProofOfWork.leadingZeroBits(hexBytes(vector.sha256)) == vector.bits)
    }

    /// Параллельный поиск может найти другое число, но оно обязано подходить.
    @Test func parallelSolutionIsValid() async throws {
        let challenge = "mgpow1.eyJuIjoidGVzdCJ9.test"
        let nonce = try #require(await ProofOfWork.solve(challenge: challenge, bits: 16))
        let digest = SHA256.hash(data: Data("\(challenge):\(nonce)".utf8))
        #expect(ProofOfWork.leadingZeroBits(digest) >= 16)
    }

    private func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
