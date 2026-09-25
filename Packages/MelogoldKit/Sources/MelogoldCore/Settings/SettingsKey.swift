/// Ключи настроек — реестр Android (REWRITE §4.11.5). Имена общие для всех клиентов, значения — в `UserDefaults`.
///
/// Сюда попадают только настройки, которые есть на Android (плюс платформенные), — каждая настройка множится
/// на все клиенты (docs/PROMPT.md §5.9).
public enum SettingsKey {
    public static let themeMode = "theme.mode"
    public static let lastTab = "shell.lastTab"
    public static let searchTipDismissed = "search.tipDismissed"
    public static let playbackNormalization = "playback.normalization"
    public static let playbackAutoplay = "playback.autoplay"
    public static let playbackSpeed = "playback.speed"
    public static let lyricsKeepScreenOn = "lyrics.keepScreenOn"
    public static let lyricsView = "lyrics.view"
    public static let historyPaused = "history.paused"
    public static let historyPeriod = "history.period"
    public static let hideExplicit = "filter.hideExplicit"
    public static let downloadsWifiOnly = "downloads.wifiOnly"
    public static let cacheStreamLimit = "cache.streamLimit"
    public static let serverURL = "server.url"

    /// Сортировка списка: `sort.favorites`, `sort.downloads`, `sort.playlistItems` и т. д.
    /// Значение — «Поле:asc» или «Поле:desc», как на Android (`SortPreferences.kt`).
    public static func sort(_ list: String) -> String { "sort.\(list)" }
}

/// Тема: «Как в системе · Светлая · Тёмная» (docs/PROMPT.md §5.1). Значения — как `theme.mode` Android.
public enum ThemeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

/// Показ текста в плеере: синхронный или обычный (`lyrics.view`).
public enum LyricsView: String, Codable, Sendable {
    case synced
    case plain
}

/// Период «Чаще всего» в Истории: 7 дней · 30 дней · Год · Всё время (`history.period`).
public enum HistoryPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case days7 = "7d"
    case days30 = "30d"
    case year = "1y"
    case allTime = "all"

    public var id: String { rawValue }
}
