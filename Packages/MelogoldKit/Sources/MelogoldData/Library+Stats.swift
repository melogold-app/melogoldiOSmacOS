import Foundation
import GRDB
import MelogoldCore

extension Library {
    /// «Итоги» периода (задание 0018): события Истории этого периода и прошлого (для сравнения), их треки и первое
    /// прослушивание каждого трека. Без сети; 50 000 событий укладываются в 300 мс. Звать не с главного потока.
    public func listeningStats(
        window: StatsWindow,
        device: HistoryDeviceFilter = .all,
        overrides: [String: StatOverride] = [:],
        calendar: Calendar = .current,
        today: Date = Date()
    ) -> ListeningStats {
        let from = window.previous(calendar: calendar)?.start ?? window.start
        let condition = device.condition
        let fromMs = Self.epochMs(from)
        let toMs = Self.epochMs(window.end)
        let input: StatsInput = read { db in
            let events = try Row.fetchAll(db, sql: """
                SELECT video_id, played_at, play_time_ms, device_id FROM play_events
                WHERE played_at >= ? AND played_at < ? AND \(condition.sql)
                """, arguments: [fromMs, toMs] + condition.arguments).map { row in
                StatEvent(videoId: row["video_id"], playedAt: Date(timeIntervalSince1970: Double(row["played_at"] as Int64) / 1000),
                          playTimeMs: row["play_time_ms"], deviceId: row["device_id"])
            }
            let windowStart = Self.epochMs(window.start)
            let tracks = try Row.fetchAll(db, sql: """
                SELECT \(Self.trackColumns) FROM tracks WHERE video_id IN (
                    SELECT DISTINCT video_id FROM play_events WHERE played_at >= ? AND played_at < ? AND \(condition.sql)
                )
                """, arguments: [windowStart, toMs] + condition.arguments).map(Self.track)
            let firstPlays = try Row.fetchAll(db, sql: "SELECT video_id, MIN(played_at) AS first FROM play_events GROUP BY video_id").map { row in
                (row["video_id"] as String, Date(timeIntervalSince1970: Double(row["first"] as Int64) / 1000))
            }
            return StatsInput(
                events: events,
                tracks: Dictionary(tracks.map { ($0.videoId, $0) }, uniquingKeysWith: { first, _ in first }),
                overrides: overrides,
                firstPlays: Dictionary(firstPlays, uniquingKeysWith: min)
            )
        } ?? StatsInput(events: [], tracks: [:], firstPlays: [:])
        // Фильтр устройства уже в запросе
        return computeStats(input, window: window, calendar: calendar, today: today)
    }

    private static func epochMs(_ date: Date) -> Int64 {
        if date == .distantPast { return Int64.min }
        if date == .distantFuture { return Int64.max }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
