import Foundation
import Testing
@testable import MelogoldCore

struct ServerAddressVectors: Decodable {
    struct Case: Decodable, CustomTestStringConvertible, Sendable {
        struct Expected: Decodable, Sendable {
            let url: String?
            let insecure: Bool?
            let error: String?
        }
        let id: String
        let input: String
        let expected: Expected
        var testDescription: String { id }
    }
    let cases: [Case]
}

@Suite("ServerAddressPolicy — векторы spec/server-address.vectors.json")
struct ServerAddressPolicyTests {
    static let cases: [ServerAddressVectors.Case] = (try? SpecFiles.decode(ServerAddressVectors.self, from: "server-address.vectors.json").cases) ?? []

    @Test func vectorsAreLoaded() {
        #expect(Self.cases.count >= 30)
    }

    @Test(arguments: cases)
    func vector(_ testCase: ServerAddressVectors.Case) {
        let result = ServerAddressPolicy.normalize(testCase.input)
        if let error = testCase.expected.error {
            #expect(result == .invalid(ServerAddressError(rawValue: error)!), "\(testCase.id)")
        } else {
            #expect(result == .valid(url: testCase.expected.url!, insecure: testCase.expected.insecure!), "\(testCase.id)")
        }
    }

    @Test func privateAddressesAfterDNS() {
        #expect(ServerAddressPolicy.isPrivateAddress([192, 168, 1, 1]))
        #expect(ServerAddressPolicy.isPrivateAddress([100, 64, 0, 1]))
        #expect(!ServerAddressPolicy.isPrivateAddress([8, 8, 8, 8]))
        let mappedPrivate: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 10, 0, 0, 1]
        #expect(ServerAddressPolicy.isPrivateAddress(mappedPrivate))
        let loopback: [UInt8] = Array(repeating: 0, count: 15) + [1]
        #expect(ServerAddressPolicy.isPrivateAddress(loopback))
    }

    @Test func ipv6Parsing() {
        #expect(IPv6.parse("::1") == Array(repeating: 0, count: 15) + [1])
        #expect(IPv6.parse("fe80::1")?.prefix(2) == [0xFE, 0x80])
        #expect(IPv6.parse("::ffff:10.0.0.1")?.suffix(4) == [10, 0, 0, 1])
        #expect(IPv6.parse("1::2::3") == nil)
        #expect(IPv6.parse("12345::") == nil)
        #expect(IPv6.parse("1:2:3:4:5:6:7:8") != nil)
        #expect(IPv6.parse("1:2:3:4:5:6:7") == nil)
    }
}
