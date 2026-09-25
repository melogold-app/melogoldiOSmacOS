import Foundation
@testable import MelogoldInnerTube

enum Fixture {
    static func json(_ name: String) throws -> JSON {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try JSON.parse(Data(contentsOf: url))
    }

    enum FixtureError: Error { case missing(String) }
}
