#if DEBUG
import Foundation
import MelogoldCore
import MelogoldPlayback

/// Только отладочная сборка: приёмка среза 2 — время от нажатия до звука по 10 разным трекам (docs/PROMPT.md §4:
/// медиана ≤ 3 с, p90 ≤ 6 с на Wi‑Fi). Вызов плеера тот же, что у нажатия по строке выдачи.
///
///     -MelogoldBenchmark "кино" [-MelogoldBenchmarkClearCache YES] [-MelogoldBenchmarkMute YES] [-MelogoldBenchmarkQuit YES]
enum DebugBenchmark {
    @MainActor
    static func runIfRequested(_ model: AppModel) {
        let defaults = UserDefaults.standard
        guard let query = defaults.string(forKey: "MelogoldBenchmark") else { return }
        Task {
            if defaults.bool(forKey: "MelogoldBenchmarkClearCache") { model.services.cache?.clear() }
            let tracks: [Track]
            do {
                tracks = Array(try await model.services.catalog.search(query, filter: .songs).items.compactMap(\.track).prefix(10))
            } catch {
                Log.error("bench", "Поиск не удался: \(error)")
                return
            }
            let player = model.services.player
            if defaults.bool(forKey: "MelogoldBenchmarkMute") { player.volume = 0 }
            var latencies: [Double] = []
            for track in tracks {
                model.play(single: track)
                let started = Date()
                while Date().timeIntervalSince(started) < 25, player.phase != .playing, player.phase != .failed {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if player.phase == .playing, let latency = player.lastStartLatency {
                    latencies.append(latency)
                } else {
                    Log.warning("bench", "«\(track.title)»: не заиграл (\(player.phase))")
                }
                try? await Task.sleep(for: .seconds(3))
            }
            let sorted = latencies.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            Log.info("bench", String(format: "Итог: %d из %d, медиана %.2f с, p90 %.2f с, все: %@", latencies.count, tracks.count, median, p90,
                                     sorted.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            player.stop()
            Log.flush()
            if defaults.bool(forKey: "MelogoldBenchmarkQuit") { exit(0) }
        }
    }
}
#endif
