import Foundation
import Testing
@testable import MelogoldServer

struct HwidVectors: Decodable {
    struct Vector: Decodable, Sendable, CustomTestStringConvertible {
        let platform: String
        let platformId: String
        let serverId: String
        let hwid: String
        var testDescription: String { platform }
    }

    let vectors: [Vector]
}

@Suite("hwid — векторы spec/hwid.vectors.json")
struct HwidTests {
    static let vectors = (try? SpecFiles.decode(HwidVectors.self, from: "hwid.vectors.json").vectors) ?? []

    @Test func vectorsAreLoaded() {
        #expect(Self.vectors.count >= 4)
    }

    @Test(arguments: vectors)
    func hwid(_ vector: HwidVectors.Vector) {
        #expect(DeviceIdentity.hwid(platformId: vector.platformId, serverId: vector.serverId) == vector.hwid)
    }

    @Test func userAgentAndClip() {
        let long = String(repeating: "я", count: 70)
        let identity = DeviceIdentity(platform: "watchos", platformId: "id", name: long, osVersion: "26.0.0", model: "Watch7,5", clientVersion: "0.1.0")
        #expect(identity.userAgent == "melogold-watchos/0.1.0")
        #expect(identity.name.utf16.count == 64)
        // Суррогатная пара не рвётся: 63 единицы + пара не влезает
        let emoji = DeviceIdentity(platform: "ios", platformId: "id", name: String(repeating: "a", count: 63) + "😀", osVersion: "", model: "", clientVersion: "")
        #expect(emoji.name == String(repeating: "a", count: 63))
    }
}
