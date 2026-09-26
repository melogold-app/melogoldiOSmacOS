import Foundation

/// Остаток таймера сна для меню, чипа плеера и часов.
enum SleepFormat {
    /// «23 мин» до срабатывания (не меньше минуты).
    static func remaining(_ end: Date) -> String {
        let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
