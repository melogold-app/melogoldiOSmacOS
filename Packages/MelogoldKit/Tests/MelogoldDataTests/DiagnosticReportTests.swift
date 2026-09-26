import Foundation
import Testing
import MelogoldCore
@testable import MelogoldData

@Suite("Отчёт диагностики")
struct DiagnosticReportTests {
    @Test func settingsWithoutSecrets() throws {
        let defaults = try #require(UserDefaults(suiteName: "report-\(UUID().uuidString)"))
        defaults.set(true, forKey: "playback.normalization")
        defaults.set("https://example.org", forKey: "server.url")
        defaults.set("abc", forKey: "server.refreshToken")
        defaults.set("x", forKey: "AppleLanguages.custom")
        let keys = DiagnosticReport.settings(defaults).map(\.0)
        #expect(keys.contains("playback.normalization"))
        #expect(keys.contains("server.url"))
        #expect(!keys.contains("server.refreshToken"))
        #expect(!keys.contains("AppleLanguages.custom"))
    }

    @Test func zipWithLogsAndCounts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("строка журнала\n".utf8).write(to: logs.appendingPathComponent(Log.fileName))
        let database = try AppDatabase.inMemory()
        Library(database: database).setLiked(Track(videoId: "a1aaaaaaaaa", title: "Звезда"), true)

        let text = DiagnosticReport.report(summary: "Melogold 0.1.0", database: database, defaults: .standard)
        #expect(text.contains("tracks = 1"))
        #expect(text.hasPrefix("Melogold 0.1.0"))

        let zip = try DiagnosticReport.build(summary: "Melogold 0.1.0", logs: logs, database: database, into: root)
        let header = try Data(contentsOf: zip).prefix(2)
        #expect(header == Data("PK".utf8))
        #expect(zip.lastPathComponent.hasPrefix("Melogold-report-"))
    }
}
