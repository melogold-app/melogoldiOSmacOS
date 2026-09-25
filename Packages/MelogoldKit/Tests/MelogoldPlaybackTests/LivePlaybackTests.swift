import AVFoundation
import Foundation
import Testing
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Живое воспроизведение (только `MELOGOLD_LIVE=1`): поток через загрузчик ресурсов, кэш, конец трека.
@Suite("Живой плеер", .enabled(if: ProcessInfo.processInfo.environment["MELOGOLD_LIVE"] == "1"), .serialized)
@MainActor
struct LivePlaybackTests {
    @Test func playsThroughResourceLoaderAndCaches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AudioCache(database: try AppDatabase.inMemory(), directory: directory, limit: { 0 })
        Log.configure(directory: FileManager.default.temporaryDirectory.appendingPathComponent("melogold-live-log"))
        let catalog = YouTubeMusic(client: InnerTubeClient(preferredLanguages: ["ru-RU"]))
        let engine = PlayerEngine(catalog: catalog, resolver: StreamResolver(catalog: catalog), cache: cache)
        engine.volume = 0
        engine.autoplayEnabled = false
        engine.play(tracks: [Track(videoId: "xtxjm7ciwmc", title: "Группа крови", durationMs: 285_000)], startAt: 0)
        let started = Date()
        while engine.phase != .playing, engine.phase != .failed, Date().timeIntervalSince(started) < 25 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(engine.phase == .playing, "phase \(engine.phase), failure \(String(describing: engine.failure))")
        print("latency", engine.lastStartLatency ?? -1, "duration", engine.duration)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(500))
            print("t", engine.position, engine.phase, "rate", engine.pipeline.rate, "cached", cache.entry("xtxjm7ciwmc")?.cachedBytes ?? 0)
        }
        #expect(engine.position > 2)
        // Перемотка в середину: звук продолжается с нового места.
        engine.seek(to: 150)
        let seekStarted = Date()
        while engine.phase != .playing, Date().timeIntervalSince(seekStarted) < 15 {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1.5))
        print("after seek", engine.position, engine.phase)
        #expect(engine.position > 150 && engine.position < 160)
        #expect(abs(engine.duration - 284) < 1.5)
        #expect((cache.entry("xtxjm7ciwmc")?.cachedBytes ?? 0) > 0)
        engine.stop()
    }
}
