import Foundation

/// Файлы общих векторов лежат в `spec/` в корне репозитория (копии из Android и сервера, `spec/README.md`).
enum SpecFiles {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MelogoldCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MelogoldKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // корень репозитория
            .appendingPathComponent("spec", isDirectory: true)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
