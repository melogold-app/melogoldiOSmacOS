import Foundation
@testable import MelogoldInnerTube

enum Fixture {
    static func json(_ name: String) throws -> JSON {
        try JSON.parse(data(name))
    }

    /// Ответ как его отдал YouTube — для заглушки сети.
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error { case missing(String) }
}
