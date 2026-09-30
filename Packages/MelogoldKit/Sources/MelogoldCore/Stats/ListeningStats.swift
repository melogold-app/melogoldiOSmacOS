import Foundation

// «Итоги» (задание 0018, как `data/stats` Android): статистика прослушиваний за неделю, месяц, год и всё время. Всё
// считается на устройстве из Истории (с событиями других устройств, пришедшими синком), без сети.

public enum StatsPeriod: String, CaseIterable, Sendable {
    case week, month, year, allTime
}

/// Период и где он: `offset` 0 — текущий, −1 — предыдущий. От `start` (включительно) до `end` (не включая), границы —
/// местные полуночи календаря устройства; неделя — с понедельника, что бы ни говорила локаль.
public struct StatsWindow: Equatable, Sendable {
    public let period: StatsPeriod
    public let offset: Int
    /// Первый день периода (полночь); у «Всё время» — `nil`.
    public let firstDay: Date?
    public let start: Date
    public let end: Date

    public var isCurrent: Bool { offset == 0 }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Дней в периоде: 7, 28…31, 365 или 366; у «Всё время» — 0.
    public func days(calendar: Calendar) -> Int {
        guard let firstDay else { return 0 }
        return calendar.dateComponents([.day], from: firstDay, to: end).day ?? 0
    }

    /// Тот же период на шаг назад — для «+12 % к августу»; у «Всё время» — нет.
    public func previous(calendar: Calendar) -> StatsWindow? {
        guard period != .allTime, let firstDay else { return nil }
        let window = StatsWindow.make(period, offset: -1, today: firstDay, calendar: calendar)
        return StatsWindow(period: period, offset: offset - 1, firstDay: window.firstDay, start: window.start, end: window.end)
    }

    /// Период `period` на `offset` шагов от того, в котором `today`.
    public static func make(_ period: StatsPeriod, offset: Int = 0, today: Date = Date(), calendar: Calendar = .current) -> StatsWindow {
        guard period != .allTime else {
            return StatsWindow(period: period, offset: 0, firstDay: nil, start: .distantPast, end: .distantFuture)
        }
        let day = calendar.startOfDay(for: today)
        let first: Date
        let end: Date
        switch period {
        case .week:
            // Понедельник — день недели 2 в григорианском календаре
            let weekday = calendar.component(.weekday, from: day)
            let back = (weekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -back, to: day)!
            first = calendar.date(byAdding: .weekOfYear, value: offset, to: monday)!
            end = calendar.date(byAdding: .weekOfYear, value: 1, to: first)!
        case .month:
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
            first = calendar.date(byAdding: .month, value: offset, to: month)!
            end = calendar.date(byAdding: .month, value: 1, to: first)!
        case .year, .allTime:
            let year = calendar.date(from: calendar.dateComponents([.year], from: day))!
            first = calendar.date(byAdding: .year, value: offset, to: year)!
            end = calendar.date(byAdding: .year, value: 1, to: first)!
        }
        return StatsWindow(period: period, offset: offset, firstDay: first, start: first, end: end)
    }
}

/// Год, итоги которого показывает карточка «Итоги 2026 готовы»: с 1 декабря по 31 января; в остальное время — `nil`.
public func wrappedSeasonYear(today: Date = Date(), calendar: Calendar = .current) -> Int? {
    let components = calendar.dateComponents([.year, .month], from: today)
    switch components.month {
    case 12: return components.year
    case 1: return components.year.map { $0 - 1 }
    default: return nil
    }
}

/// Прослушивание из Истории: что, когда, сколько играло, на каком устройстве (`nil` — это).
public struct StatEvent: Equatable, Sendable {
    public let videoId: String
    public let playedAt: Date
    public let playTimeMs: Int64
    public let deviceId: String?

    public init(videoId: String, playedAt: Date, playTimeMs: Int64, deviceId: String?) {
        self.videoId = videoId
        self.playedAt = playedAt
        self.playTimeMs = playTimeMs
        self.deviceId = deviceId
    }
}

/// Своё название, исполнитель и альбом трека (задание 0014): учитываются в топах.
public struct StatOverride: Equatable, Sendable {
    public let title: String?
    public let artistsText: String?
    public let albumTitle: String?

    public init(title: String?, artistsText: String?, albumTitle: String?) {
        self.title = title
        self.artistsText = artistsText
        self.albumTitle = albumTitle
    }
}

public struct StatsInput: Sendable {
    public var events: [StatEvent]
    public var tracks: [String: Track]
    public var overrides: [String: StatOverride]
    /// Когда трек впервые играл на любом устройстве.
    public var firstPlays: [String: Date]

    public init(events: [StatEvent], tracks: [String: Track], overrides: [String: StatOverride] = [:], firstPlays: [String: Date]) {
        self.events = events
        self.tracks = tracks
        self.overrides = overrides
        self.firstPlays = firstPlays
    }
}

public struct TopTrack: Equatable, Sendable, Identifiable {
    public let track: Track
    /// Со своим названием и исполнителем поверх.
    public let title: String
    public let artist: String?
    public let plays: Int
    public let ms: Int64

    public var id: String { track.videoId }
}

/// Исполнитель или альбом топа. `browseId` — страница YouTube Music; у своего названия без такой страницы — `nil`.
public struct TopGroup: Equatable, Sendable, Identifiable {
    public let key: String
    public let browseId: String?
    public let name: String
    /// Обложка самого слушаемого трека группы.
    public let thumbnailUrl: String?
    public let plays: Int
    public let ms: Int64
    public let tracks: Int

    public var id: String { key }
}

/// Столбец «Когда слушал»: день, месяц или год, начинающийся с `date`.
public struct StatsBar: Equatable, Sendable {
    public let date: Date
    public let ms: Int64
}

public struct Discoveries: Equatable, Sendable {
    public let count: Int
    public let top: [TopTrack]
}

/// Части суток «Время суток».
public enum DayPart: String, CaseIterable, Sendable {
    case night, morning, afternoon, evening

    public var hours: ClosedRange<Int> {
        switch self {
        case .night: 0 ... 5
        case .morning: 6 ... 11
        case .afternoon: 12 ... 17
        case .evening: 18 ... 23
        }
    }
}

/// Статистика одного периода (задание 0018).
public struct ListeningStats: Equatable, Sendable {
    public let window: StatsWindow
    public let totalMs: Int64
    public let plays: Int
    public let tracks: Int
    public let artists: Int
    public let albums: Int
    /// Сколько играло в прошлом таком же периоде; у «Всё время» — `nil`.
    public let previousMs: Int64?
    public let topTracks: [TopTrack]
    public let topArtists: [TopGroup]
    public let topAlbums: [TopGroup]
    /// Дни недели или месяца, 12 месяцев года, годы «Всё время».
    public let bars: [StatsBar]
    /// 24 часа суток.
    public let hours: [Int64]
    /// У «Всё время» — `nil`: когда-то новым было всё.
    public let discoveries: Discoveries?
    /// Самое первое прослушивание в Истории.
    public let earliest: Date?

    public var isEmpty: Bool { plays == 0 }

    /// Есть ли что листать назад: История начинается раньше этого периода.
    public var hasEarlier: Bool {
        guard window.period != .allTime, let earliest else { return false }
        return window.start > earliest
    }

    /// «+12 %» к прошлому периоду; `nil`, когда сравнивать не с чем.
    public var changePercent: Int? { ListeningStats.percentChange(totalMs, previousMs) }

    public var busiestBar: StatsBar? { bars.max { $0.ms < $1.ms }.flatMap { $0.ms > 0 ? $0 : nil } }

    public var favoriteDayPart: DayPart? {
        let sums = DayPart.allCases.map { part in (part, part.hours.reduce(Int64(0)) { $0 + (hours.indices.contains($1) ? hours[$1] : 0) }) }
        guard let best = sums.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    public var peakHour: Int? {
        guard let best = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[best] > 0 else { return nil }
        return best
    }

    public static let topLimit = 50
    static let discoveriesShown = 5

    public static func percentChange(_ current: Int64, _ previous: Int64?) -> Int? {
        guard let previous, previous > 0 else { return nil }
        return Int((Double(current - previous) * 100 / Double(previous)).rounded())
    }
}

/// Первый исполнитель строки: «Noize MC feat. Oxxxymiron» → «Noize MC».
public func firstArtist(_ artistsText: String?) -> String? {
    let text = (artistsText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    var end = text.endIndex
    for separator in [", ", " & ", " feat. ", " ft. "] {
        if let range = text.range(of: separator, options: .caseInsensitive), range.lowerBound > text.startIndex, range.lowerBound < end {
            end = range.lowerBound
        }
    }
    let first = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    return first.isEmpty ? nil : first
}

private func groupKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private final class Tally {
    var plays = 0
    var ms: Int64 = 0
}

private final class Group {
    var browseId: String?
    let name: String
    var plays = 0
    var ms: Int64 = 0
    var tracks = 0
    var thumbnailUrl: String?

    init(browseId: String?, name: String) {
        self.browseId = browseId
        self.name = name
    }

    func add(_ track: TopTrack, browseId: String?) {
        plays += track.plays
        ms += track.ms
        tracks += 1
        if self.browseId == nil { self.browseId = browseId }
        if thumbnailUrl == nil { thumbnailUrl = track.track.thumbnailUrl }
    }
}

/// Считает прослушивания `window` на устройствах, которые пропускает `includes`. Прослушивание — в том периоде, куда
/// попадает его время; прошлый период для сравнения считается из тех же событий.
///
/// Исполнитель трека: свой (задание 0014), иначе первый из карты исполнителей, иначе первый из `artistsText`. Альбом:
/// свой, иначе альбом трека, иначе трек в топ альбомов не идёт. Своё имя, совпавшее с именем YouTube, получает его
/// страницу.
public func computeStats(
    _ input: StatsInput,
    window: StatsWindow,
    calendar: Calendar = .current,
    today: Date = Date(),
    includes: (String?) -> Bool = { _ in true }
) -> ListeningStats {
    let previousWindow = window.previous(calendar: calendar)
    var previousMs: Int64 = 0
    var totalMs: Int64 = 0
    var plays = 0
    var perTrack: [String: Tally] = [:]
    var hours = [Int64](repeating: 0, count: 24)
    let days = window.days(calendar: calendar)
    var byIndex = [Int64](repeating: 0, count: window.period == .year ? 12 : (window.period == .allTime ? 0 : days))
    var byYear: [Int: Int64] = [:]

    for event in input.events where includes(event.deviceId) {
        let time = max(0, event.playTimeMs)
        if let previousWindow, previousWindow.contains(event.playedAt) {
            previousMs += time
            continue
        }
        guard window.contains(event.playedAt) else { continue }
        totalMs += time
        plays += 1
        let tally = perTrack[event.videoId] ?? Tally()
        tally.plays += 1
        tally.ms += time
        perTrack[event.videoId] = tally

        let parts = calendar.dateComponents([.hour, .month, .year], from: event.playedAt)
        if let hour = parts.hour { hours[hour] += time }
        switch window.period {
        case .week, .month:
            if let first = window.firstDay,
               let day = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: event.playedAt)).day,
               byIndex.indices.contains(day) {
                byIndex[day] += time
            }
        case .year:
            if let month = parts.month { byIndex[month - 1] += time }
        case .allTime:
            if let year = parts.year { byYear[year, default: 0] += time }
        }
    }

    let ranked: [TopTrack] = perTrack.compactMap { videoId, tally in
        guard let track = input.tracks[videoId] else { return nil }
        let override = input.overrides[videoId]
        return TopTrack(track: track, title: override?.title ?? track.title, artist: override?.artistsText ?? track.artistsText,
                        plays: tally.plays, ms: tally.ms)
    }
    .sorted { ($0.ms, $0.plays, $1.title) > ($1.ms, $1.plays, $0.title) }

    var artistGroups: [String: Group] = [:]
    var artistOrder: [String] = []
    var albumGroups: [String: Group] = [:]
    var albumOrder: [String] = []
    for top in ranked {
        let track = top.track
        let override = input.overrides[track.videoId]
        let mapped = track.artists.first { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let artistName = override?.artistsText.flatMap(firstArtist) ?? mapped?.name ?? firstArtist(track.artistsText)
        if let artistName {
            // Страница YouTube остаётся, только пока имя то же, что дал YouTube
            let browseId = mapped.flatMap { groupKey($0.name) == groupKey(artistName) ? $0.id : nil }
            let key = groupKey(artistName)
            if artistGroups[key] == nil {
                artistGroups[key] = Group(browseId: browseId, name: artistName)
                artistOrder.append(key)
            }
            artistGroups[key]?.add(top, browseId: browseId)
        }
        let albumTitle = override?.albumTitle ?? track.albumTitle.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if let albumTitle {
            let browseId = track.albumTitle.flatMap { groupKey($0) == groupKey(albumTitle) ? track.albumId : nil }
            let key = groupKey(albumTitle)
            if albumGroups[key] == nil {
                albumGroups[key] = Group(browseId: browseId, name: albumTitle)
                albumOrder.append(key)
            }
            albumGroups[key]?.add(top, browseId: browseId)
        }
    }
    func sortedTop(_ groups: [String: Group], _ order: [String]) -> [TopGroup] {
        order.compactMap { key in groups[key].map { (key, $0) } }
            .sorted { ($0.1.ms, $0.1.plays, $1.1.name) > ($1.1.ms, $1.1.plays, $0.1.name) }
            .map { key, group in
                TopGroup(key: key, browseId: group.browseId, name: group.name, thumbnailUrl: group.thumbnailUrl,
                         plays: group.plays, ms: group.ms, tracks: group.tracks)
            }
    }
    let artists = sortedTop(artistGroups, artistOrder)
    let albums = sortedTop(albumGroups, albumOrder)

    let discoveries: Discoveries? = window.period == .allTime ? nil : {
        let fresh = ranked.filter { input.firstPlays[$0.track.videoId].map(window.contains) ?? false }
        return Discoveries(count: fresh.count, top: Array(fresh.prefix(ListeningStats.discoveriesShown)))
    }()

    let bars: [StatsBar] = {
        switch window.period {
        case .week, .month:
            guard let first = window.firstDay else { return [] }
            return byIndex.indices.map { StatsBar(date: calendar.date(byAdding: .day, value: $0, to: first)!, ms: byIndex[$0]) }
        case .year:
            guard let first = window.firstDay else { return [] }
            return byIndex.indices.map { StatsBar(date: calendar.date(byAdding: .month, value: $0, to: first)!, ms: byIndex[$0]) }
        case .allTime:
            guard let firstYear = byYear.keys.min(), let lastYear = byYear.keys.max() else { return [] }
            let last = max(lastYear, calendar.component(.year, from: today))
            return (firstYear ... last).map { year in
                StatsBar(date: calendar.date(from: DateComponents(year: year, month: 1, day: 1))!, ms: byYear[year] ?? 0)
            }
        }
    }()

    return ListeningStats(
        window: window, totalMs: totalMs, plays: plays, tracks: ranked.count, artists: artists.count, albums: albums.count,
        previousMs: previousWindow == nil ? nil : previousMs,
        topTracks: Array(ranked.prefix(ListeningStats.topLimit)),
        topArtists: Array(artists.prefix(ListeningStats.topLimit)),
        topAlbums: Array(albums.prefix(ListeningStats.topLimit)),
        bars: bars, hours: hours, discoveries: discoveries, earliest: input.firstPlays.values.min()
    )
}
