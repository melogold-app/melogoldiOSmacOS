import Foundation

/// Время API §1.5: сервер отдаёт `YYYY-MM-DDTHH:mm:ss.sssZ`, принимает то же с дробной частью до 9 знаков.
public enum IsoTime {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
    }

    /// `2026-09-23T10:00:00.000Z` — всегда с миллисекундами (ближайшая миллисекунда).
    public static func string(_ date: Date) -> String {
        string(epochMs: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    /// Время базы (epoch-мс UTC, API §1.5) → строка API. Миллисекунды — из целых: через `Double` половина значений
    /// уходила бы на 1 мс раньше (двоичная дробь обрезается при форматировании).
    public static func string(epochMs: Int64) -> String {
        var seconds = epochMs / 1000
        var millis = epochMs % 1000
        if millis < 0 {
            seconds -= 1
            millis += 1000
        }
        // Целые секунды двоичная дробь не портит: `…:00Z` → `…:00.mmmZ`
        let whole = withoutFraction.format(Date(timeIntervalSince1970: TimeInterval(seconds)))
        let fraction = String(millis)
        return whole.dropLast() + "." + String(repeating: "0", count: 3 - fraction.count) + fraction + "Z"
    }

    /// Строка API → epoch-мс; `nil` — не время.
    public static func epochMs(_ text: String?) -> Int64? {
        date(text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}
