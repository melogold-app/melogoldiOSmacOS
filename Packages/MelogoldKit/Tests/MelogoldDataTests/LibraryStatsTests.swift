import Foundation
import GRDB
import Testing
import MelogoldCore
@testable import MelogoldData

/// «Итоги» из базы (задание 0018): события периода и прошлого, треки, первое прослушивание, фильтр устройства.
@Suite("Итоги — чтение из библиотеки")
struct LibraryStatsTests {
    @Test func readsThePeriodAndTheDeviceFilter() throws {
        let database = try AppDatabase.inMemory()
        let library = Library(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        func ms(_ month: Int, _ day: Int) -> Int64 {
            Int64(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!.timeIntervalSince1970 * 1000)
        }
        library.save([
            Track(videoId: "blood000000", title: "Группа крови", artists: [ArtistRef(id: "UCkino", name: "Кино")], artistsText: "Кино",
                  albumId: "MPREb_blood", albumTitle: "Группа крови"),
            Track(videoId: "noize000000", title: "Выдыхай", artistsText: "Noize MC"),
        ])
        try database.writer.write { db in
            let rows: [(String, String, Int64, Int64, String?)] = [
                ("e1", "blood000000", ms(9, 2), 300_000, nil),
                ("e2", "blood000000", ms(9, 3), 300_000, "pixel"),
                ("e3", "noize000000", ms(9, 10), 180_000, nil),
                ("e4", "blood000000", ms(8, 20), 600_000, nil),
                ("e5", "noize000000", ms(7, 1), 60_000, nil),
            ]
            for row in rows {
                try db.execute(sql: "INSERT INTO play_events (event_id, video_id, played_at, play_time_ms, synced, device_id) VALUES (?, ?, ?, ?, 1, ?)",
                               arguments: [row.0, row.1, row.2, row.3, row.4])
            }
        }
        let window = StatsWindow.make(.month, today: calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!, calendar: calendar)

        let all = library.listeningStats(window: window, calendar: calendar)
        #expect(all.plays == 3 && all.totalMs == 780_000)
        #expect(all.previousMs == 600_000)
        #expect(all.topTracks.map(\.track.videoId) == ["blood000000", "noize000000"])
        #expect(all.topArtists.first?.browseId == "UCkino")
        #expect(all.discoveries?.count == 0, "оба трека впервые играли раньше сентября")
        #expect(all.earliest != nil && all.hasEarlier)

        let here = library.listeningStats(window: window, device: .thisDevice(currentDeviceId: nil), calendar: calendar)
        #expect(here.plays == 2 && here.totalMs == 480_000)
        let pixel = library.listeningStats(window: window, device: .device("pixel"), calendar: calendar)
        #expect(pixel.plays == 1 && pixel.previousMs == 0)
    }
}
