import Foundation

/// Итог поиска текста (цепочка `LyricsFetcher`): сторона `nil` — её не искали или сеть не ответила, пустая строка —
/// искали и не нашли. Стороны, которые уже были в строке, приходят как есть.
public struct FoundLyrics: Equatable, Sendable {
    public var synced: String?
    public var plain: String?
    public var syncedSource: String?
    public var plainSource: String?
    /// Сдвиг найденного синхронного текста, мс, если источник его знает (общий текст сервера).
    public var offsetMs: Int64?
    public var language: String?
    /// Текст взят из своей версии пользователя на сервере: он выбран, остаётся своим (задание 0011).
    public var chosen: Bool
    /// Ссылка на найденный текст у поставщика (задание 0015).
    public var syncedRef: String?
    public var plainRef: String?

    public init(
        synced: String?, plain: String?, syncedSource: String? = nil, plainSource: String? = nil, offsetMs: Int64? = nil,
        language: String? = nil, chosen: Bool = false, syncedRef: String? = nil, plainRef: String? = nil
    ) {
        self.synced = synced
        self.plain = plain
        self.syncedSource = syncedSource
        self.plainSource = plainSource
        self.offsetMs = offsetMs
        self.language = language
        self.chosen = chosen
        self.syncedRef = syncedRef
        self.plainRef = plainRef
    }
}

/// Правила записи текстов трека в базу (audit 4.2, задания 0001 и 0011). Чистые функции от строки, какой она лежит
/// сейчас, к строке, какой она должна стать: хранилище вызывает их внутри одной транзакции, поэтому запись не
/// затирает то, что появилось между чтением и записью (поиск в полёте, редактор, синк).
public enum LyricsRules {
    /// Итог поиска поверх строки. `baseline` — строка в начале поиска, `current` — какая она теперь. Сторона, которую
    /// нашёл поиск, записывается, только если с начала поиска её никто не менял (ни пользователь — импорт, редактор,
    /// выбор, — ни синк); иначе остаётся то, что есть. Свой (набранный, импортированный), выбранный и пришедший с
    /// сервера текст поиском не заменяется никогда, даже если поиск вернул для его стороны другой. `nil` — записывать
    /// нечего.
    public static func mergeFetched(baseline: StoredLyrics?, current: StoredLyrics?, found: FoundLyrics) -> StoredLyrics? {
        var merged = current ?? .empty
        var takenSynced = false
        var takenPlain = false
        /// Сторона с текстом, которую сделал пользователь или выбрал он же (свой источник, выбранная строка).
        func isProtected(_ text: String?, _ source: String?) -> Bool {
            guard let text, !text.isEmpty else { return false }
            return current?.chosen == true || LyricsSources.isOwn(source)
        }
        // Тот же текст, но теперь с известной ссылкой (закрепление, задание 0015), тоже записывается: без этого текст,
        // найденный до ссылок, искался бы заново при каждом показе
        if let side = found.synced, side != baseline?.synced || found.syncedRef != baseline?.syncedRef,
           current?.synced == baseline?.synced, !isProtected(current?.synced, current?.syncedSource) {
            merged.synced = side
            merged.syncedSource = found.syncedSource
            merged.syncedRef = side.isEmpty ? nil : found.syncedRef
            takenSynced = true
        }
        if let side = found.plain, side != baseline?.plain || found.plainRef != baseline?.plainRef,
           current?.plain == baseline?.plain, !isProtected(current?.plain, current?.plainSource) {
            merged.plain = side
            merged.plainSource = found.plainSource
            merged.plainRef = side.isEmpty ? nil : found.plainRef
            takenPlain = true
        }
        guard takenSynced || takenPlain else { return current }
        if takenSynced, let offset = found.offsetMs, current?.offsetMs == baseline?.offsetMs { merged.offsetMs = offset }
        if let language = found.language, current?.language == baseline?.language { merged.language = language }
        if found.chosen { merged.chosen = true }
        return merged
    }

    /// «Искать заново»: найденное забывается, свой текст остаётся. Своя сторона — набранная или импортированная (`user`,
    /// `file`, не пустая); выбранный текст (`chosen`) свой целиком. `nil` — своего ничего нет, строку можно удалить.
    public static func forgetFound(_ row: StoredLyrics?) -> StoredLyrics? {
        guard var row else { return nil }
        if row.chosen { return row }
        let keepSynced = LyricsSources.isOwn(row.syncedSource) && !(row.synced ?? "").isEmpty
        let keepPlain = LyricsSources.isOwn(row.plainSource) && !(row.plain ?? "").isEmpty
        guard keepSynced || keepPlain else { return nil }
        if !keepSynced {
            row.synced = nil
            row.syncedSource = nil
            row.syncedRef = nil
            row.offsetMs = 0
        }
        if !keepPlain {
            row.plain = nil
            row.plainSource = nil
            row.plainRef = nil
        }
        return row
    }

    /// Свой текст: импорт файла (`file`) или редактор (`user`). Сторона, которой нет (`nil`), остаётся как была;
    /// новый синхронный текст сбрасывает сдвиг. Флаг «выбран» сохраняется.
    public static func saveOwn(
        current: StoredLyrics?, synced: String?, plain: String?, source: String, language: String?
    ) -> StoredLyrics {
        StoredLyrics(
            synced: synced ?? current?.synced,
            plain: plain ?? current?.plain,
            syncedSource: synced == nil ? current?.syncedSource : source,
            plainSource: plain == nil ? current?.plainSource : source,
            offsetMs: synced == nil ? (current?.offsetMs ?? 0) : 0,
            language: language ?? current?.language,
            chosen: current?.chosen ?? false,
            syncedRef: synced == nil ? current?.syncedRef : nil,
            plainRef: plain == nil ? current?.plainRef : nil
        )
    }

    /// Текст, выбранный в «Найти текст», заменяет обе стороны (то, чего у результата нет, — «нет»): выбор должен быть
    /// виден. Набранный и импортированный текст без явного `replacingTyped` не заменяется — `nil`.
    public static func choose(
        current: StoredLyrics?, synced: String?, plain: String?, source: String, replacingTyped: Bool
    ) -> StoredLyrics? {
        if let current, current.hasTypedText, !replacingTyped { return nil }
        let synced = synced.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let plain = plain.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return StoredLyrics(
            synced: synced ?? "", plain: plain ?? "",
            syncedSource: synced == nil ? nil : source, plainSource: plain == nil ? nil : source,
            chosen: true
        )
    }

    /// Сдвиг синхронного текста: `delta` прибавляется, `nil` — сбросить. Нет строки — нет и сдвига.
    public static func shifted(_ row: StoredLyrics?, by delta: Int64?) -> StoredLyrics? {
        guard var row else { return nil }
        row.offsetMs = delta.map { row.offsetMs + $0 } ?? 0
        return row
    }
}
