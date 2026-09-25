import Foundation

/// Время API §1.5: сервер отдаёт `YYYY-MM-DDTHH:mm:ss.sssZ`, принимает то же с дробной частью до 9 знаков.
public enum IsoTime {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
    }

    /// `2026-09-23T10:00:00.000Z` — всегда с миллисекундами.
    public static func string(_ date: Date) -> String {
        withFraction.format(date)
    }

    /// Время базы (epoch-мс UTC, API §1.5) → строка API.
    public static func string(epochMs: Int64) -> String {
        string(Date(timeIntervalSince1970: Double(epochMs) / 1000))
    }

    /// Строка API → epoch-мс; `nil` — не время.
    public static func epochMs(_ text: String?) -> Int64? {
        date(text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}
