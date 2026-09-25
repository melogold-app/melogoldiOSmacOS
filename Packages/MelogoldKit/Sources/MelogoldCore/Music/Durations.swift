import Foundation

/// Длительности: «3:45» ↔ миллисекунды (GLOSSARY §1.3: «3:45 · 1:02:10»).
public enum Durations {
    /// «3:45», «1:02:10» → мс; другое — `nil`.
    public static func parse(_ text: String?) -> Int64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total: Int64 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let value = Int64(part) else { return nil }
            total = total * 60 + value
        }
        return total * 1000
    }

    /// мс → «3:45» или «1:02:10».
    public static func format(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
            : String(format: "%lld:%02lld", minutes, seconds)
    }

    /// Секунды (`TimeInterval`) → «3:45».
    public static func format(seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return format(Int64(seconds * 1000))
    }
}
