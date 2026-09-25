import Foundation

/// Файлы общих векторов лежат в `spec/` в корне репозитория (копии из сервера, `spec/README.md`).
enum SpecFiles {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MelogoldServerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MelogoldKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // корень репозитория
            .appendingPathComponent("spec", isDirectory: true)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }
}
