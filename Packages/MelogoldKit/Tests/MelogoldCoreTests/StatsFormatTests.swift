import Foundation
import Testing
@testable import MelogoldCore

@Suite("Итоги — подписи")
struct StatsFormatTests {
    let ru = Locale(identifier: "ru_RU")
    let en = Locale(identifier: "en_US")
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.firstWeekday = 2
        return calendar
    }()

    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func signedPercent() {
        #expect(StatsFormat.signedPercent(12, language: "en") == "+12%")
        #expect(StatsFormat.signedPercent(-8, language: "ru") == "\u{2212}8\u{00A0}%")
        #expect(StatsFormat.signedPercent(0, language: "ru") == "0\u{00A0}%")
    }

    @Test func listeningTime() {
        #expect(StatsFormat.listeningTime(ms: (38 * 3600 + 12 * 60) * 1000, locale: ru) == "38 ч 12 мин")
        #expect(StatsFormat.listeningTime(ms: 40 * 60 * 1000, locale: ru) == "40 мин")
        #expect(StatsFormat.listeningTime(ms: 5_000, locale: ru) == "1 мин")
        #expect(StatsFormat.listeningTime(ms: 90 * 60 * 1000, locale: en).hasPrefix("1 hr"))
    }

    @Test func windowTitles() {
        let today = date(2026, 9, 30)
        let month = StatsWindow.make(.month, offset: -1, today: today, calendar: calendar)
        #expect(StatsFormat.windowTitle(month, today: today, calendar: calendar, locale: ru) == "Август 2026")
        #expect(StatsFormat.windowTitle(StatsWindow.make(.year, today: today, calendar: calendar), today: today, calendar: calendar, locale: ru) == "2026")
        // Неделя с понедельника: 28 сентября — 4 октября 2026 (через границу месяцев)
        let cross = StatsWindow.make(.week, today: today, calendar: calendar)
        let crossTitle = StatsFormat.windowTitle(cross, today: today, calendar: calendar, locale: ru)
        #expect(crossTitle.contains("28") && crossTitle.contains("4") && crossTitle.contains("окт"), "\(crossTitle)")
        let inside = StatsWindow.make(.week, offset: -1, today: today, calendar: calendar)
        let insideTitle = StatsFormat.windowTitle(inside, today: today, calendar: calendar, locale: ru)
        #expect(insideTitle.contains("21") && insideTitle.contains("27") && insideTitle.contains("сентября"), "\(insideTitle)")
        // Год другой — год в названии
        let old = StatsWindow.make(.month, offset: -10, today: today, calendar: calendar)
        #expect(StatsFormat.windowTitle(old, today: today, calendar: calendar, locale: ru) == "Ноябрь 2025")
        #expect(StatsFormat.windowTitle(.make(.allTime), today: today, calendar: calendar, locale: ru, allTime: "Всё время") == "Всё время")
    }

    @Test func barLabels() {
        let today = date(2026, 9, 30)
        let week = StatsWindow.make(.week, today: today, calendar: calendar)
        let bar = StatsBar(date: date(2026, 9, 28), ms: 0)
        #expect(StatsFormat.barLabel(week, bar, index: 0, count: 7, calendar: calendar, locale: ru)?.lowercased().hasPrefix("пн") == true)
        let month = StatsWindow.make(.month, today: today, calendar: calendar)
        #expect(StatsFormat.barLabel(month, StatsBar(date: date(2026, 9, 8), ms: 0), index: 7, count: 30, calendar: calendar, locale: ru) == "8")
        #expect(StatsFormat.barLabel(month, StatsBar(date: date(2026, 9, 9), ms: 0), index: 8, count: 30, calendar: calendar, locale: ru) == nil)
        let year = StatsWindow.make(.year, today: today, calendar: calendar)
        #expect(StatsFormat.barLabel(year, StatsBar(date: date(2026, 1, 1), ms: 0), index: 0, count: 12, calendar: calendar, locale: ru) == "Я")
        #expect(StatsFormat.barTitle(month, StatsBar(date: date(2026, 9, 14), ms: 0), calendar: calendar, locale: ru) == "14 сентября")
        #expect(StatsFormat.barTitle(year, StatsBar(date: date(2026, 9, 1), ms: 0), calendar: calendar, locale: ru) == "Сентябрь")
        #expect(StatsFormat.hourLabel(7) == "07:00")
    }
}

@Suite("Итоги года — карточки")
struct WrappedCardsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }()

    func track(_ id: String, album: String? = nil) -> Track {
        Track(videoId: id, title: id, artists: [ArtistRef(id: "UC_\(id)", name: "A \(id)")], artistsText: "A \(id)", albumTitle: album)
    }

    func year(events: [StatEvent], tracks: [Track], firstPlays: [String: Date]? = nil) -> ListeningStats {
        let today = calendar.date(from: DateComponents(year: 2026, month: 12, day: 5, hour: 12))!
        let window = StatsWindow.make(.year, today: today, calendar: calendar)
        return computeStats(
            StatsInput(events: events, tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.videoId, $0) }),
                       firstPlays: firstPlays ?? Dictionary(events.map { ($0.videoId, $0.playedAt) }, uniquingKeysWith: min)),
            window: window, calendar: calendar, today: today
        )
    }

    func at(_ m: Int, _ d: Int, hour: Int = 21) -> Date { calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: hour))! }

    @Test func emptyYearHasNoCards() {
        #expect(year(events: [], tracks: []).wrappedCards.isEmpty)
        #expect(year(events: [], tracks: []).totalMinutes == 0)
    }

    @Test func cardsFollowTheData() {
        let events = [
            StatEvent(videoId: "aaaaaaaaaaa", playedAt: at(3, 1), playTimeMs: 200_000, deviceId: nil),
            StatEvent(videoId: "bbbbbbbbbbb", playedAt: at(3, 2), playTimeMs: 100_000, deviceId: nil),
        ]
        let stats = year(events: events, tracks: [track("aaaaaaaaaaa"), track("bbbbbbbbbbb")])
        #expect(stats.wrappedCards == [.minutes, .trackOfYear, .topArtists, .topTracks, .favoriteTime, .discoveries])
        #expect(stats.totalMinutes == 5)
        #expect(calendar.component(.month, from: stats.favoriteMonth!) == 3, "любимый месяц — март")
        #expect(stats.peakHour == 21 && stats.favoriteDayPart == .evening)
        // Ни одного нового трека в году (слушал раньше): карточки открытий нет
        let old = year(events: events, tracks: [track("aaaaaaaaaaa"), track("bbbbbbbbbbb")],
                       firstPlays: ["aaaaaaaaaaa": at(1, 1).addingTimeInterval(-365 * 86400), "bbbbbbbbbbb": at(1, 1).addingTimeInterval(-365 * 86400)])
        #expect(!old.wrappedCards.contains(.discoveries))
    }

    @Test func aShortPlayIsStillOneMinute() {
        let stats = year(events: [StatEvent(videoId: "aaaaaaaaaaa", playedAt: at(3, 1), playTimeMs: 20_000, deviceId: nil)], tracks: [track("aaaaaaaaaaa")])
        #expect(stats.totalMinutes == 1)
    }
}
