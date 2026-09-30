import Foundation

/// Подписи «Итогов» (задание 0018, как `StatsScreen.kt` Android): что между стрелками, подписи столбцов, «+12 %», «38 ч 12 мин».
/// Всё с явными календарём и языком — чтобы проверять `swift test`, а не полагаться на систему.
public enum StatsFormat {
    /// «+12 %», «−8 %», «0 %»: настоящий минус, а в русском — неразрывный пробел перед знаком процента.
    public static func signedPercent(_ percent: Int, language: String) -> String {
        let sign = percent > 0 ? "+" : (percent < 0 ? "\u{2212}" : "")
        let space = language == "ru" ? "\u{00A0}" : ""
        return "\(sign)\(abs(percent))\(space)%"
    }

    /// «38 ч 12 мин» (от часа) или «40 мин»; меньше минуты — «1 мин».
    public static func listeningTime(ms: Int64, locale: Locale) -> String {
        let seconds = max(60, ms / 1000)
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: allowed, width: .abbreviated).locale(locale))
    }

    /// Между стрелками: «Сентябрь 2026», «21–27 сентября» («28 сент. – 4 окт.» через границу месяцев; с годом, когда он не
    /// этот), «2026»; у «Всё время» — `allTime`.
    public static func windowTitle(_ window: StatsWindow, today: Date, calendar: Calendar, locale: Locale, allTime: String = "") -> String {
        guard let first = window.firstDay, window.period != .allTime,
              let last = calendar.date(byAdding: .day, value: -1, to: window.end) else { return allTime }
        let thisYear = calendar.component(.year, from: today)
        let withYear = calendar.component(.year, from: first) != thisYear || calendar.component(.year, from: last) != thisYear
        switch window.period {
        case .allTime:
            return allTime
        case .year:
            return String(calendar.component(.year, from: first))
        case .month:
            // Без «г.» русского шаблона: месяц сам по себе и год цифрами, как на Android
            let name = first.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide))
            return capitalized(name, locale) + " " + String(calendar.component(.year, from: first))
        case .week:
            let sameMonth = calendar.component(.month, from: first) == calendar.component(.month, from: last)
            var style = Date.IntervalFormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day()
            style = sameMonth ? style.month(.wide) : style.month(.abbreviated)
            if withYear { style = style.year() }
            return (first ..< last.addingTimeInterval(1)).formatted(style)
        }
    }

    /// Что за столбец: «14 сентября», «Сентябрь», «2026».
    public static func barTitle(_ window: StatsWindow, _ bar: StatsBar, calendar: Calendar, locale: Locale) -> String {
        switch window.period {
        case .week, .month: bar.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).day().month(.wide))
        case .year: capitalized(bar.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide)), locale)
        case .allTime: String(calendar.component(.year, from: bar.date))
        }
    }

    /// Подпись под столбцом: день недели, каждый 7-й день месяца, первая буква месяца, год; `nil` — без подписи.
    public static func barLabel(_ window: StatsWindow, _ bar: StatsBar, index: Int, count: Int, calendar: Calendar, locale: Locale) -> String? {
        switch window.period {
        case .week:
            bar.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated))
        case .month:
            index % 7 == 0 ? String(calendar.component(.day, from: bar.date)) : nil
        case .year:
            bar.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.narrow)).uppercased(with: locale)
        case .allTime:
            count <= 6 || index % 2 == 0 ? String(calendar.component(.year, from: bar.date)) : nil
        }
    }

    /// «21:00» — час суток «Времени суток».
    public static func hourLabel(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    /// «Март» — месяц отдельно, с большой буквы («Любимый месяц» в итогах года).
    public static func capitalizedMonth(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        capitalized(date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide)), locale)
    }

    /// Месяц в подписи «прошлый месяц» — с большой буквы, как в русском заголовке.
    static func capitalized(_ text: String, _ locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }
}
