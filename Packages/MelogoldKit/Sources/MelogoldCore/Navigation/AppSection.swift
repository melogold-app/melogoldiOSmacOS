/// Разделы приложения — везде в одном порядке, на часах тоже (решение пользователя, docs/PROMPT.md §5.1).
///
/// Сырые значения хранятся в `shell.lastTab`: приложение открывается в разделе, где пользователь был при выходе,
/// а при первом запуске — в «Трендах» (REWRITE §2.3).
public enum AppSection: String, CaseIterable, Codable, Sendable, Identifiable {
    case trends
    case new
    case library
    case search
    case settings

    public var id: String { rawValue }

    /// Раздел первого запуска и стартовый для правила «Назад».
    public static let firstLaunch: AppSection = .trends

    /// Раздел из сохранённого значения; неизвестное или пустое значение — раздел первого запуска.
    public init(storedValue: String?) {
        self = storedValue.flatMap(AppSection.init(rawValue:)) ?? .firstLaunch
    }
}
