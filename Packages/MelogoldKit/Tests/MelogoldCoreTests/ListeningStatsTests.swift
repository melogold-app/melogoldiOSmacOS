import Foundation
import Testing
@testable import MelogoldCore

/// «Итоги» (задание 0018): границы недели, месяца и года в часовом поясе устройства, исполнитель без карты, свой
/// альбом, фильтр устройства, сравнение с прошлым периодом, открытия, столбцы.
@Suite("Итоги — подсчёт статистики")
struct ListeningStatsTests {
    /// Москва, григорианский календарь — как на устройстве пользователя.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.locale = Locale(identifier: "ru_RU")
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func track(_ id: String, title: String? = nil, artists: [ArtistRef] = [], artistsText: String? = nil, albumId: String? = nil, albumTitle: String? = nil) -> Track {
        Track(videoId: id, title: title ?? id, artists: artists, artistsText: artistsText, albumId: albumId, albumTitle: albumTitle,
              thumbnailUrl: "https://i.ytimg.com/\(id).jpg")
    }

    static func event(_ id: String, _ date: Date, minutes: Int64 = 3, device: String? = nil) -> StatEvent {
        StatEvent(videoId: id, playedAt: date, playTimeMs: minutes * 60_000, deviceId: device)
    }

    // MARK: - Периоды

    @Test func weekStartsOnMondayInTheLocalZone() {
        // Среда, 30 сентября 2026
        let window = StatsWindow.make(.week, today: Self.date(2026, 9, 30), calendar: Self.calendar)
        #expect(window.start == Self.date(2026, 9, 28, 0))
        #expect(window.end == Self.date(2026, 10, 5, 0))
        #expect(window.days(calendar: Self.calendar) == 7)
        // Воскресенье — ещё та же неделя
        #expect(StatsWindow.make(.week, today: Self.date(2026, 10, 4, 23, 59), calendar: Self.calendar).start == window.start)
        let previous = window.previous(calendar: Self.calendar)
        #expect(previous?.start == Self.date(2026, 9, 21, 0) && previous?.offset == -1)
    }

    @Test func monthAndYearBoundaries() {
        let september = StatsWindow.make(.month, today: Self.date(2026, 9, 30), calendar: Self.calendar)
        #expect(september.start == Self.date(2026, 9, 1, 0) && september.end == Self.date(2026, 10, 1, 0))
        #expect(september.days(calendar: Self.calendar) == 30)
        let february = StatsWindow.make(.month, offset: -7, today: Self.date(2026, 9, 30), calendar: Self.calendar)
        #expect(february.start == Self.date(2026, 2, 1, 0) && february.days(calendar: Self.calendar) == 28)
        let year = StatsWindow.make(.year, today: Self.date(2026, 9, 30), calendar: Self.calendar)
        #expect(year.start == Self.date(2026, 1, 1, 0) && year.end == Self.date(2027, 1, 1, 0))
        #expect(year.previous(calendar: Self.calendar)?.start == Self.date(2025, 1, 1, 0))
        #expect(StatsWindow.make(.allTime).previous(calendar: Self.calendar) == nil)
    }

    @Test func playJustBeforeLocalMidnightBelongsToThatDay() {
        let window = StatsWindow.make(.month, today: Self.date(2026, 9, 30), calendar: Self.calendar)
        let input = StatsInput(
            events: [Self.event("a1aaaaaaaaa", Self.date(2026, 9, 30, 23, 59)), Self.event("a1aaaaaaaaa", Self.date(2026, 10, 1, 0, 1))],
            tracks: ["a1aaaaaaaaa": Self.track("a1aaaaaaaaa")], firstPlays: [:]
        )
        let stats = computeStats(input, window: window, calendar: Self.calendar)
        #expect(stats.plays == 1)
        #expect(stats.bars.count == 30 && stats.bars[29].ms == 180_000)
        #expect(stats.hours[23] == 180_000)
    }

    @Test func seasonOfYearInsights() {
        #expect(wrappedSeasonYear(today: Self.date(2026, 12, 1), calendar: Self.calendar) == 2026)
        #expect(wrappedSeasonYear(today: Self.date(2027, 1, 31), calendar: Self.calendar) == 2026)
        #expect(wrappedSeasonYear(today: Self.date(2026, 11, 30), calendar: Self.calendar) == nil)
    }

    // MARK: - Подсчёт

    @Test func topsCountsComparisonAndDiscoveries() {
        let window = StatsWindow.make(.month, today: Self.date(2026, 9, 15), calendar: Self.calendar)
        let kino = ArtistRef(id: "UCkino", name: "Кино")
        let tracks = [
            "blood000000": Self.track("blood000000", title: "Группа крови", artists: [kino], artistsText: "Кино", albumId: "MPREb_blood", albumTitle: "Группа крови"),
            "star0000000": Self.track("star0000000", title: "Звезда по имени Солнце", artists: [kino], artistsText: "Кино", albumId: "MPREb_star", albumTitle: "Звезда по имени Солнце"),
            "noize000000": Self.track("noize000000", title: "Выдыхай", artistsText: "Noize MC feat. Oxxxymiron"),
        ]
        let events = [
            Self.event("blood000000", Self.date(2026, 9, 2), minutes: 5),
            Self.event("blood000000", Self.date(2026, 9, 3), minutes: 5),
            Self.event("star0000000", Self.date(2026, 9, 3), minutes: 4),
            Self.event("noize000000", Self.date(2026, 9, 10, 8), minutes: 3),
            // Август — прошлый период для сравнения
            Self.event("blood000000", Self.date(2026, 8, 20), minutes: 10),
            // Другое устройство, фильтр его исключит
            Self.event("noize000000", Self.date(2026, 9, 11), minutes: 3, device: "pixel"),
        ]
        let first = ["blood000000": Self.date(2026, 8, 20), "star0000000": Self.date(2026, 9, 3), "noize000000": Self.date(2026, 9, 10)]
        let input = StatsInput(events: events, tracks: tracks, firstPlays: first)
        let stats = computeStats(input, window: window, calendar: Self.calendar) { $0 != "pixel" }

        #expect(stats.plays == 4 && stats.totalMs == 17 * 60_000)
        #expect(stats.tracks == 3 && stats.artists == 2 && stats.albums == 2)
        #expect(stats.topTracks.map(\.track.videoId) == ["blood000000", "star0000000", "noize000000"])
        #expect(stats.topArtists.map(\.name) == ["Кино", "Noize MC"])
        #expect(stats.topArtists[0].browseId == "UCkino" && stats.topArtists[0].tracks == 2 && stats.topArtists[0].plays == 3)
        #expect(stats.topArtists[1].browseId == nil, "исполнитель из строки — без страницы")
        #expect(stats.topAlbums.map(\.browseId) == ["MPREb_blood", "MPREb_star"])
        #expect(stats.previousMs == 10 * 60_000 && stats.changePercent == 70)
        #expect(stats.discoveries?.count == 2 && stats.discoveries?.top.map(\.track.videoId) == ["star0000000", "noize000000"])
        #expect(stats.hours[8] == 3 * 60_000 && stats.favoriteDayPart == .afternoon && stats.peakHour == 12)
        #expect(stats.busiestBar?.date == Self.date(2026, 9, 3, 0))
        #expect(stats.earliest == Self.date(2026, 8, 20) && stats.hasEarlier)

        let all = computeStats(input, window: window, calendar: Self.calendar)
        #expect(all.plays == 5, "без фильтра — и другое устройство")
    }

    @Test func ownNamesJoinAndMoveTracks() {
        let window = StatsWindow.make(.year, today: Self.date(2026, 9, 15), calendar: Self.calendar)
        let tracks = [
            "cut10000000": Self.track("cut10000000", title: "Нарезка 1", artistsText: "Some Channel"),
            "cut20000000": Self.track("cut20000000", title: "Нарезка 2", artistsText: "Other Channel"),
            "orig0000000": Self.track("orig0000000", title: "Оригинал", artists: [ArtistRef(id: "UCband", name: "Группа")], albumId: "MPREb_x", albumTitle: "Альбом"),
        ]
        let overrides = [
            "cut10000000": StatOverride(title: "Песня 1", artistsText: "Группа", albumTitle: "Альбом"),
            "cut20000000": StatOverride(title: nil, artistsText: "группа", albumTitle: "альбом"),
        ]
        let events = [
            Self.event("cut10000000", Self.date(2026, 3, 1)),
            Self.event("cut20000000", Self.date(2026, 3, 2)),
            Self.event("orig0000000", Self.date(2026, 7, 1), minutes: 10),
        ]
        let stats = computeStats(StatsInput(events: events, tracks: tracks, overrides: overrides, firstPlays: [:]), window: window, calendar: Self.calendar)
        #expect(stats.artists == 1 && stats.topArtists[0].tracks == 3)
        #expect(stats.topArtists[0].browseId == "UCband", "своё имя, совпавшее с именем YouTube, получает его страницу")
        #expect(stats.albums == 1 && stats.topAlbums[0].browseId == "MPREb_x" && stats.topAlbums[0].tracks == 3)
        #expect(stats.topTracks.first { $0.track.videoId == "cut10000000" }?.title == "Песня 1")
        #expect(stats.bars.count == 12 && stats.bars[2].ms == 6 * 60_000 && stats.bars[6].ms == 10 * 60_000)
    }

    @Test func allTimeHasYearsAndNoDiscoveries() {
        let window = StatsWindow.make(.allTime)
        let input = StatsInput(
            events: [Self.event("a1aaaaaaaaa", Self.date(2024, 5, 1)), Self.event("a1aaaaaaaaa", Self.date(2026, 5, 1))],
            tracks: ["a1aaaaaaaaa": Self.track("a1aaaaaaaaa")], firstPlays: ["a1aaaaaaaaa": Self.date(2024, 5, 1)]
        )
        let stats = computeStats(input, window: window, calendar: Self.calendar, today: Self.date(2026, 9, 30))
        #expect(stats.bars.map(\.ms) == [180_000, 0, 180_000])
        #expect(stats.discoveries == nil && stats.previousMs == nil && stats.changePercent == nil && !stats.hasEarlier)
    }

    @Test func emptyPeriod() {
        let stats = computeStats(StatsInput(events: [], tracks: [:], firstPlays: [:]), window: StatsWindow.make(.week, calendar: Self.calendar), calendar: Self.calendar)
        #expect(stats.isEmpty && stats.topTracks.isEmpty && stats.favoriteDayPart == nil && stats.busiestBar == nil)
    }

    @Test func firstArtistOfALine() {
        #expect(firstArtist("Noize MC feat. Oxxxymiron") == "Noize MC")
        #expect(firstArtist("Би-2 & Земфира") == "Би-2")
        #expect(firstArtist("A, B и C") == "A")
        #expect(firstArtist("Artist FT. Other") == "Artist")
        #expect(firstArtist("  ") == nil)
        #expect(firstArtist(nil) == nil)
    }

    @Test func fiftyThousandEventsAreFast() {
        let window = StatsWindow.make(.allTime)
        let tracks = Dictionary(uniqueKeysWithValues: (0 ..< 2000).map { index -> (String, Track) in
            let id = String(format: "t%010d", index)
            return (id, Self.track(id, artists: [ArtistRef(id: "UC\(index % 300)", name: "Artist \(index % 300)")], albumId: "MPREb_\(index % 500)", albumTitle: "Album \(index % 500)"))
        })
        let ids = Array(tracks.keys)
        let base = Self.date(2025, 1, 1)
        let events = (0 ..< 50_000).map { index in
            Self.event(ids[index % ids.count], base.addingTimeInterval(Double(index) * 600))
        }
        let started = ContinuousClock.now
        let stats = computeStats(StatsInput(events: events, tracks: tracks, firstPlays: [:]), window: window, calendar: Self.calendar)
        let elapsed = ContinuousClock.now - started
        #expect(stats.plays == 50_000 && stats.topTracks.count == ListeningStats.topLimit)
        // Задание: 300 мс на устройстве в выпускной сборке; отладочная сборка тестов медленнее — запас втрое
        #expect(elapsed < .milliseconds(900), "\(elapsed)")
    }
}
