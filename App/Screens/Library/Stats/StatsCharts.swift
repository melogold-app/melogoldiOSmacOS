import Accessibility
import Charts
import SwiftUI
import MelogoldCore

/// «Когда слушал»: столбцы по дням периода (у года — по месяцам, у «Всё время» — по годам), высота — время прослушивания.
struct StatsBarsChart: View {
    let stats: ListeningStats
    let calendar: Calendar
    let locale: Locale

    var body: some View {
        let bars = stats.bars
        let busiest = stats.busiestBar
        Chart(Array(bars.enumerated()), id: \.offset) { index, bar in
            BarMark(x: .value("stats.when", index), y: .value("stats.listeningTime", Double(bar.ms) / 60_000), width: .ratio(0.72))
                .foregroundStyle(bar.date == busiest?.date ? Color.accentColor : Color.accentColor.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .chartXScale(domain: -0.6 ... Double(max(bars.count, 1)) - 0.4)
        .chartXAxis {
            AxisMarks(values: Array(bars.indices)) { value in
                if let index = value.as(Int.self), bars.indices.contains(index),
                   let label = StatsFormat.barLabel(stats.window, bars[index], index: index, count: bars.count, calendar: calendar, locale: locale) {
                    AxisValueLabel { Text(verbatim: label).font(.caption2) }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 150)
        // VoiceOver: «Аудиограф» — столбцы по дням с подписями и временем, а не по номерам 0…30
        .accessibilityChartDescriptor(StatsBarsDescriptor(stats: stats, calendar: calendar, locale: locale, summary: summary(busiest)))
        .accessibilityIdentifier("stats.chart")
    }

    private func summary(_ busiest: StatsBar?) -> String {
        guard let busiest else { return "" }
        return String(localized: "stats.chartBusiest \(StatsFormat.barTitle(stats.window, busiest, calendar: calendar, locale: locale)) \(StatsFormat.listeningTime(ms: busiest.ms, locale: locale))")
    }
}

extension DayPart {
    var title: LocalizedStringResource {
        switch self {
        case .night: "stats.daypart.night"
        case .morning: "stats.daypart.morning"
        case .afternoon: "stats.daypart.afternoon"
        case .evening: "stats.daypart.evening"
        }
    }
}

/// «Время суток»: 24 столбца по часам.
struct StatsHoursChart: View {
    let stats: ListeningStats

    var body: some View {
        let peak = stats.peakHour
        Chart(Array(stats.hours.enumerated()), id: \.offset) { hour, ms in
            BarMark(x: .value("stats.timeOfDay", hour), y: .value("stats.listeningTime", Double(ms) / 60_000), width: .ratio(0.72))
                .foregroundStyle(hour == peak ? Color.accentColor : Color.accentColor.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .chartXScale(domain: -0.6 ... 23.6)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                if let hour = value.as(Int.self) {
                    AxisValueLabel { Text(verbatim: StatsFormat.hourLabel(hour)).font(.caption2) }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 110)
        .accessibilityChartDescriptor(StatsHoursDescriptor(stats: stats, summary: summary(peak)))
    }

    private func summary(_ peak: Int?) -> String {
        guard let peak, let part = stats.favoriteDayPart else { return "" }
        return String(localized: "stats.hoursBusiest \(StatsFormat.hourLabel(peak)) \(String(localized: part.title))")
    }
}

/// Описание «Когда слушал» для VoiceOver (аудиограф): по оси X — дни, месяцы или годы периода, по оси Y — время слушания.
private struct StatsBarsDescriptor: AXChartDescriptorRepresentable {
    let stats: ListeningStats
    let calendar: Calendar
    let locale: Locale
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let bars = stats.bars
        let titles = bars.map { StatsFormat.barTitle(stats.window, $0, calendar: calendar, locale: locale) }
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "stats.when"), categoryOrder: titles)
        let y = StatsAxis.minutes(bars.map { Double($0.ms) / 60_000 }, locale: locale)
        let points = zip(titles, bars).map { AXDataPoint(x: $0, y: Double($1.ms) / 60_000) }
        return AXChartDescriptor(title: String(localized: "stats.when"), summary: summary, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: String(localized: "stats.listeningTime"), isContinuous: false, dataPoints: points)])
    }
}

/// Описание «Времени суток» для VoiceOver: 24 часа по оси X.
private struct StatsHoursDescriptor: AXChartDescriptorRepresentable {
    let stats: ListeningStats
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let titles = stats.hours.indices.map(StatsFormat.hourLabel)
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "stats.timeOfDay"), categoryOrder: titles)
        let y = StatsAxis.minutes(stats.hours.map { Double($0) / 60_000 }, locale: .current)
        let points = zip(titles, stats.hours).map { AXDataPoint(x: $0, y: Double($1) / 60_000) }
        return AXChartDescriptor(title: String(localized: "stats.timeOfDay"), summary: summary, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: String(localized: "stats.listeningTime"), isContinuous: false, dataPoints: points)])
    }
}

private enum StatsAxis {
    /// Ось времени в минутах: значения читаются как «1 ч 20 мин», как везде в «Итогах».
    static func minutes(_ values: [Double], locale: Locale) -> AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(title: String(localized: "stats.listeningTime"), range: 0 ... max(1, values.max() ?? 1),
                                    gridlinePositions: []) { value in
            StatsFormat.listeningTime(ms: Int64(value * 60_000), locale: locale)
        }
    }
}
