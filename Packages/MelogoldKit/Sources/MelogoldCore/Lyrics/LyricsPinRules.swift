import Foundation

/// Правила закреплённого текста (задание 0015, как `data/lyrics/LyricsPins.kt` Android): прослушал трек 30 с с найденным
/// автоматически текстом и не менял — текст закрепляется на сервере ссылкой у поставщика, и все устройства показывают
/// его, а не ищут свой.
public enum LyricsPinRules {
    /// Столько играл трек с найденным текстом — тогда он закрепляется (тот же момент, что запись в историю).
    public static let pinAfterMs: Int64 = 30_000

    /// Показывает ли строка тот текст, на который указывает закрепление (любая сторона).
    public static func shows(_ row: StoredLyrics?, _ pin: LyricsPin) -> Bool {
        guard let row else { return false }
        let syncedShown = !(row.synced ?? "").isEmpty && row.syncedRef == pin.ref && row.syncedSource == pin.source
        let plainShown = !(row.plain ?? "").isEmpty && row.plainRef == pin.ref && row.plainSource == pin.source
        return syncedShown || plainShown
    }

    /// Закрепление найденного автоматически текста строки: показанная сторона (синхронная, иначе обычная), её поставщик
    /// и номер у него; сдвиг «позже» синхронного текста. `nil` — свой (набранный, из файла, выбранный) текст или текст
    /// без ссылки: закреплять нечего.
    public static func pin(of row: StoredLyrics) -> LyricsPin? {
        guard !row.isOwn else { return nil }
        let hasSynced = !(row.synced ?? "").isEmpty
        let hasPlain = !(row.plain ?? "").isEmpty
        guard hasSynced || hasPlain else { return nil }
        let source = hasSynced ? row.syncedSource : row.plainSource
        let ref = hasSynced ? row.syncedRef : row.plainRef
        guard let source, let ref else { return nil }
        return LyricsPin(source: source, ref: ref, startTimeMs: hasSynced && row.offsetMs < 0 ? -row.offsetMs : nil)
    }

    /// Текст сдвинут: закрепление, которое его показывает, берёт сдвиг «позже»; «раньше» остаётся на устройстве. `nil` —
    /// закрепление этот текст не показывает или менять нечего.
    public static func shifted(_ pin: LyricsPin, row: StoredLyrics?) -> LyricsPin? {
        guard let row, shows(row, pin) else { return nil }
        let start: Int64? = row.offsetMs < 0 ? -row.offsetMs : nil
        guard let updated = LyricsPin(source: pin.source, ref: pin.ref, startTimeMs: start), updated != pin else { return nil }
        return updated
    }
}
