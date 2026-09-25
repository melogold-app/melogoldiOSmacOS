import Foundation
import Observation
import MelogoldCore

/// Настройки устройства — `UserDefaults` с ключами реестра Android (REWRITE §4.11.5, `SettingsKey`).
///
/// Значение по умолчанию в `UserDefaults` не пишется: если пользователь сам не выбирал, новое значение по умолчанию
/// из следующей версии действует и для него (так решено для размера кэша, задание 0003, и так же для остальных).
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Размер кэша музыки по умолчанию — 4 ГБ (задание 0003). `0` — «Без ограничений».
    public static let defaultCacheLimit: Int64 = 4 * 1024 * 1024 * 1024

    public var theme: ThemeMode {
        didSet { store(theme.rawValue, SettingsKey.themeMode, isDefault: theme == .system) }
    }

    /// Раздел при выходе: приложение открывается в нём.
    public var lastTab: AppSection {
        didSet { defaults.set(lastTab.rawValue, forKey: SettingsKey.lastTab) }
    }

    public var normalization: Bool {
        didSet { store(normalization, SettingsKey.playbackNormalization, isDefault: normalization) }
    }

    public var autoplay: Bool {
        didSet { store(autoplay, SettingsKey.playbackAutoplay, isDefault: autoplay) }
    }

    /// Скорость 0,5–2× — одна глобальная настройка (docs/PROMPT.md §4). Выбор — из `AppSettings.speeds`.
    public var speed: Double {
        didSet { store(speed, SettingsKey.playbackSpeed, isDefault: speed == 1.0) }
    }

    /// Значения скорости в «Настройки › Воспроизведение».
    public static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public var lyricsKeepScreenOn: Bool {
        didSet { store(lyricsKeepScreenOn, SettingsKey.lyricsKeepScreenOn, isDefault: !lyricsKeepScreenOn) }
    }

    public var lyricsView: LyricsView {
        didSet { store(lyricsView.rawValue, SettingsKey.lyricsView, isDefault: lyricsView == .synced) }
    }

    /// «Не сохранять историю».
    public var historyPaused: Bool {
        didSet { store(historyPaused, SettingsKey.historyPaused, isDefault: !historyPaused) }
    }

    public var historyPeriod: HistoryPeriod {
        didSet { store(historyPeriod.rawValue, SettingsKey.historyPeriod, isDefault: historyPeriod == .days30) }
    }

    /// «Скрывать треки с пометкой E».
    public var hideExplicit: Bool {
        didSet { store(hideExplicit, SettingsKey.hideExplicit, isDefault: !hideExplicit) }
    }

    public var downloadsWifiOnly: Bool {
        didSet { store(downloadsWifiOnly, SettingsKey.downloadsWifiOnly, isDefault: !downloadsWifiOnly) }
    }

    /// Размер кэша музыки в байтах; `0` — «Без ограничений».
    public var cacheLimit: Int64 {
        didSet { defaults.set(cacheLimit, forKey: SettingsKey.cacheStreamLimit) }
    }

    /// Адрес сервера (уже нормализованный `ServerAddressPolicy`).
    public var serverURL: String {
        didSet { store(serverURL, SettingsKey.serverURL, isDefault: serverURL == ServerDefaults.baseURL) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = ThemeMode(rawValue: defaults.string(forKey: SettingsKey.themeMode) ?? "") ?? .system
        lastTab = AppSection(storedValue: defaults.string(forKey: SettingsKey.lastTab))
        normalization = defaults.object(forKey: SettingsKey.playbackNormalization) as? Bool ?? true
        autoplay = defaults.object(forKey: SettingsKey.playbackAutoplay) as? Bool ?? true
        speed = min(max(defaults.object(forKey: SettingsKey.playbackSpeed) as? Double ?? 1.0, 0.5), 2.0)
        lyricsKeepScreenOn = defaults.bool(forKey: SettingsKey.lyricsKeepScreenOn)
        lyricsView = LyricsView(rawValue: defaults.string(forKey: SettingsKey.lyricsView) ?? "") ?? .synced
        historyPaused = defaults.bool(forKey: SettingsKey.historyPaused)
        historyPeriod = HistoryPeriod(rawValue: defaults.string(forKey: SettingsKey.historyPeriod) ?? "") ?? .days30
        hideExplicit = defaults.bool(forKey: SettingsKey.hideExplicit)
        downloadsWifiOnly = defaults.bool(forKey: SettingsKey.downloadsWifiOnly)
        cacheLimit = (defaults.object(forKey: SettingsKey.cacheStreamLimit) as? NSNumber)?.int64Value ?? Self.defaultCacheLimit
        serverURL = ServerAddressPolicy.normalize(defaults.string(forKey: SettingsKey.serverURL)).url ?? ServerDefaults.baseURL
    }

    /// Сортировка списка (`sort.<list>`): «Поле:asc» или «Поле:desc»; пусто — сортировка экрана по умолчанию.
    public func sort(for list: String) -> String {
        defaults.string(forKey: SettingsKey.sort(list)) ?? ""
    }

    public func setSort(_ value: String, for list: String) {
        defaults.set(value, forKey: SettingsKey.sort(list))
    }

    private func store(_ value: Any, _ key: String, isDefault: Bool) {
        if isDefault {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }
}
