import Foundation
import Testing
@testable import MelogoldCore

@Suite("Версия, разделы, журнал")
struct SupportTests {
    @Test func buildNumberFromVersion() {
        #expect(AppVersion.buildNumber(for: "0.1.0") == 100)
        #expect(AppVersion.buildNumber(for: "0.1.3") == 103)
        #expect(AppVersion.buildNumber(for: "1.2.3") == 10203)
        #expect(AppVersion.buildNumber(for: "1.2") == nil)
        #expect(AppVersion.buildNumber(for: "1.2.3-beta") == nil)
        #expect(AppVersion.buildNumber(for: "0.100.0") == nil)
    }

    @Test func sectionOrderAndFirstLaunch() {
        #expect(AppSection.allCases == [.trends, .new, .library, .search, .settings])
        #expect(AppSection(storedValue: nil) == .trends)
        #expect(AppSection(storedValue: "garbage") == .trends)
        #expect(AppSection(storedValue: "library") == .library)
    }

    @Test func logRotatesPreviousRunAtStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = FileLogSink()
        sink.configure(directory: directory)
        sink.append(level: .info, category: "test", message: "первый запуск")
        sink.flush()
        let current = directory.appendingPathComponent(Log.fileName)
        #expect(try String(contentsOf: current, encoding: .utf8).contains("первый запуск"))

        let second = FileLogSink()
        second.configure(directory: directory)
        second.append(level: .info, category: "test", message: "второй запуск")
        second.flush()
        let previous = directory.appendingPathComponent(Log.previousFileName)
        #expect(try String(contentsOf: previous, encoding: .utf8).contains("первый запуск"))
        let now = try String(contentsOf: current, encoding: .utf8)
        #expect(now.contains("второй запуск"))
        #expect(!now.contains("первый запуск"))
    }

    @Test func logRotatesWhenFull() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = FileLogSink()
        sink.configure(directory: directory)
        let chunk = String(repeating: "x", count: 64 * 1024)
        for index in 0..<40 {
            sink.append(level: .debug, category: "fill", message: "\(index) \(chunk)")
        }
        sink.flush()
        let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(Log.fileName).path)[.size] as? Int ?? 0
        #expect(size <= Log.maxFileBytes)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Log.previousFileName).path))
    }
}
