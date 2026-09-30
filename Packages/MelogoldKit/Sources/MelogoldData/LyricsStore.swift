import Foundation
import GRDB
import MelogoldCore
import Synchronization

/// Тексты треков на устройстве (таблица `lyrics`, колонки как у Windows): найденные в сети — кэш, свои (источник
/// `user` или `file`) и выбранные (`chosen`, задание 0011) — библиотека, их синк отправляет на сервер (задание 0001).
/// О правке синк узнаёт по наблюдению таблицы `lyrics` (`SyncStore.observedRegion`): любая запись отсюда, в том числе
/// сдвиг, поднимает цикл синка, а тот по хэшу решает, что уходит. Кроме того, о правке своего текста можно узнать в той
/// же транзакции через `setOwnLyricsRecorder`.
///
/// Каждая запись — «прочитать строку, применить правило `LyricsRules`, записать» одной транзакцией, а не запись строки,
/// собранной раньше по устаревшим данным: поиск в полёте, редактор и синк не затирают друг друга.
public final class LyricsStore: Sendable {
    public let database: AppDatabase
    private let recorderBox = OwnLyricsRecorderBox()

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Отметка «свой текст трека изменился или удалён» (`videoId`), в той же транзакции, что и запись. Своим считается
    /// и выбранный текст, и сдвиг своего текста.
    public func setOwnLyricsRecorder(_ recorder: (@Sendable (Database, String) throws -> Void)?) {
        recorderBox.set(recorder)
    }

    /// Итог «Выбрать» в «Найти текст».
    public enum Choice: Equatable, Sendable {
        /// Записано; строка после записи.
        case chosen(StoredLyrics?)
        /// Здесь набранный или импортированный текст: без подтверждения он не заменяется.
        case typedTextKept
    }

    /// Текст из кэша: `nil` у стороны — ещё не искали, пустая строка — искали и не нашли.
    public func lyrics(_ videoId: String) -> StoredLyrics? {
        (try? database.writer.read { db in try Self.read(db, videoId) }) ?? nil
    }

    /// Записать строку целиком, как есть (без правил слияния): для импорта копии и тестов.
    public func save(_ videoId: String, _ lyrics: StoredLyrics) {
        _ = transact(videoId) { _ in lyrics }
    }

    /// Итог поиска (`baseline` — строка в начале поиска): пишется только то, что за время поиска никто не менял;
    /// свой, выбранный и пришедший с сервера текст не затирается. Возвращает строку после записи.
    @discardableResult
    public func saveFetched(_ videoId: String, baseline: StoredLyrics?, found: FoundLyrics) -> StoredLyrics? {
        transact(videoId) { current in LyricsRules.mergeFetched(baseline: baseline, current: current, found: found) }
    }

    /// Свой текст: импорт файла (`file`) или редактор (`user`) — синк отправит его на сервер. Пишется в трек `videoId`,
    /// а не в тот, что играет сейчас.
    @discardableResult
    public func saveOwn(_ videoId: String, synced: String?, plain: String?, source: String, language: String? = nil) -> StoredLyrics? {
        transact(videoId) { current in
            LyricsRules.saveOwn(current: current, synced: synced, plain: plain, source: source, language: language)
        }
    }

    /// Текст, выбранный в «Найти текст»: свой для синка, хотя источник — `lrclib`. Набранный или импортированный текст
    /// без `replacingTyped` не заменяется.
    @discardableResult
    public func choose(_ videoId: String, synced: String?, plain: String?, source: String = LyricsSources.lrclib, replacingTyped: Bool = false) -> Choice {
        var refused = false
        let row = transact(videoId) { current in
            guard let next = LyricsRules.choose(current: current, synced: synced, plain: plain, source: source, replacingTyped: replacingTyped) else {
                refused = true
                return current
            }
            return next
        }
        return refused ? .typedTextKept : .chosen(row)
    }

    /// «Искать заново»: найденное забывается, свой и выбранный текст остаются. Возвращает то, что осталось.
    @discardableResult
    public func forgetFound(_ videoId: String) -> StoredLyrics? {
        transact(videoId) { current in LyricsRules.forgetFound(current) }
    }

    /// Сдвиг синхронного текста трека (±0,1 и ±0,5 с в меню текста): `delta` прибавляется к тому, что лежит в базе, `nil` —
    /// сбросить.
    @discardableResult
    public func shift(_ videoId: String, by delta: Int64?) -> StoredLyrics? {
        let row = transact(videoId) { current in LyricsRules.shifted(current, by: delta) }
        // Сдвиг «позже» закреплённого текста обновляет закрепление (задание 0015)
        if let row, let pin = pin(videoId), let updated = LyricsPinRules.shifted(pin, row: row) { setPin(videoId, updated) }
        return row
    }

    // MARK: - Закреплённый текст (задание 0015)

    /// Закрепление трека: ссылка на текст у поставщика, одинаковая на всех устройствах аккаунта.
    public func pin(_ videoId: String) -> LyricsPin? {
        (try? database.writer.read { db in try Self.readPin(db, videoId) }) ?? nil
    }

    public func setPin(_ videoId: String, _ pin: LyricsPin?) {
        _ = try? database.writer.write { db in
            if let pin {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO lyrics_pins (video_id, source, ref, start_time_ms, updated_at) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [videoId, pin.source, pin.ref, pin.startTimeMs, EpochMs.now()])
            } else {
                try db.execute(sql: "DELETE FROM lyrics_pins WHERE video_id = ?", arguments: [videoId])
            }
        }
    }

    /// Трек проиграл 30 с (`LyricsPinRules.pinAfterMs`): текст, найденный автоматически и не изменённый, закрепляется.
    /// Уже закреплённый текст не перезакрепляется — первое закрепление общее для всех устройств. Своего текста нет →
    /// закреплять нечего. Одной транзакцией: строка не успеет измениться между чтением и записью. Возвращает `true`,
    /// если закрепление записано.
    @discardableResult
    public func pinPlayed(_ videoId: String) -> Bool {
        (try? database.writer.write { db -> Bool in
            guard try Self.readPin(db, videoId) == nil, let row = try Self.read(db, videoId),
                  let pin = LyricsPinRules.pin(of: row) else { return false }
            try db.execute(sql: """
                INSERT INTO lyrics_pins (video_id, source, ref, start_time_ms, updated_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [videoId, pin.source, pin.ref, pin.startTimeMs, EpochMs.now()])
            return true
        }) ?? false
    }

    /// Следить за закреплением трека (его может принести синк с другого устройства): `onChange` — на главном акторе, со
    /// значением сразу и после каждой правки.
    @MainActor
    public func observePin(_ videoId: String, onChange: @escaping @MainActor (LyricsPin?) -> Void) -> LyricsObservation {
        let cancellable = ValueObservation.tracking { db in try Self.readPin(db, videoId) }.removeDuplicates().start(
            in: database.writer,
            scheduling: .immediate,
            onError: { error in Log.warning("lyrics", "Наблюдение за закреплением \(videoId): \(error)") },
            onChange: onChange
        )
        return LyricsObservation(cancellable)
    }

    private static func readPin(_ db: Database, _ videoId: String) throws -> LyricsPin? {
        try Row.fetchOne(db, sql: "SELECT source, ref, start_time_ms FROM lyrics_pins WHERE video_id = ?", arguments: [videoId]).flatMap {
            LyricsPin(source: $0["source"], ref: $0["ref"], startTimeMs: $0["start_time_ms"])
        }
    }

    /// Удалить текст трека (свой — сервер получит надгробие при ближайшем синке).
    public func delete(_ videoId: String) {
        _ = transact(videoId) { _ in nil }
    }

    /// Следить за строкой трека: `onChange` зовётся на главном акторе — со строкой (или `nil`) сразу, при запуске
    /// наблюдения (иначе запоздавшее первое значение могло бы затереть то, что экран уже получил), затем после каждой её
    /// правки, в том числе синком (запись других треков наблюдателя не будит).
    @MainActor
    public func observe(_ videoId: String, onChange: @escaping @MainActor (StoredLyrics?) -> Void) -> LyricsObservation {
        let cancellable = ValueObservation.tracking { db in try Self.read(db, videoId) }.removeDuplicates().start(
            in: database.writer,
            scheduling: .immediate,
            onError: { error in Log.warning("lyrics", "Наблюдение за текстом \(videoId): \(error)") },
            onChange: onChange
        )
        return LyricsObservation(cancellable)
    }

    /// Выбранные тексты — как свои: очистка кэша их не трогает.
    private static let fetchedOnly = """
        COALESCE(source, '') NOT IN ('file', 'user') AND COALESCE(plain_source, '') NOT IN ('file', 'user') AND chosen = 0
        """

    /// Размер найденных в сети текстов, байт (кэш: их можно найти снова).
    public func fetchedSize() -> Int64 {
        ((try? database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(COALESCE(synced, '')) + LENGTH(COALESCE(plain, ''))), 0) FROM lyrics WHERE \(Self.fetchedOnly)")
        }) ?? nil) ?? 0
    }

    /// Очистка кэша: найденные в сети тексты забываются, свои, импортированные и выбранные остаются.
    public func clearFetched() {
        _ = try? database.writer.write { db in try db.execute(sql: "DELETE FROM lyrics WHERE \(Self.fetchedOnly)") }
    }

    // MARK: - Транзакция

    /// Правило переводит строку, какой она лежит сейчас, в строку, какой она должна стать (`nil` — строки нет). Та же —
    /// ничего не пишется. Возвращает строку после правила; при ошибке базы — то, что там лежит.
    private func transact(_ videoId: String, _ rule: (StoredLyrics?) -> StoredLyrics?) -> StoredLyrics? {
        let recorder = recorderBox
        do {
            return try database.writer.write { db in
                let current = try Self.read(db, videoId)
                let next = rule(current)
                if next != current {
                    try Self.write(db, videoId, next)
                    if current?.isOwn == true || next?.isOwn == true { try recorder.record(db, videoId) }
                }
                return next
            }
        } catch {
            Log.warning("lyrics", "Текст \(videoId) не записан: \(error)")
            return lyrics(videoId)
        }
    }

    private static let columns = "synced, plain, source, plain_source, offset_ms, language, chosen, synced_ref, plain_ref"

    private static func read(_ db: Database, _ videoId: String) throws -> StoredLyrics? {
        try Row.fetchOne(db, sql: "SELECT \(columns) FROM lyrics WHERE video_id = ?", arguments: [videoId]).map { row in
            StoredLyrics(synced: row["synced"], plain: row["plain"], syncedSource: row["source"], plainSource: row["plain_source"],
                         offsetMs: row["offset_ms"] ?? 0, language: row["language"], chosen: (row["chosen"] as Int64? ?? 0) != 0,
                         syncedRef: row["synced_ref"], plainRef: row["plain_ref"])
        }
    }

    private static func write(_ db: Database, _ videoId: String, _ lyrics: StoredLyrics?) throws {
        guard let lyrics else {
            try db.execute(sql: "DELETE FROM lyrics WHERE video_id = ?", arguments: [videoId])
            return
        }
        try db.execute(sql: """
            INSERT OR REPLACE INTO lyrics (video_id, synced, plain, source, plain_source, offset_ms, language, chosen, fetched_at,
                                           synced_ref, plain_ref)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [videoId, lyrics.synced, lyrics.plain, lyrics.syncedSource, lyrics.plainSource, lyrics.offsetMs,
                             lyrics.language, lyrics.chosen ? 1 : 0, EpochMs.now(), lyrics.syncedRef, lyrics.plainRef])
    }
}

/// Наблюдение за строкой текста; `cancel()` останавливает его.
public final class LyricsObservation: Sendable {
    private let cancellable: Mutex<AnyDatabaseCancellable?>

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = Mutex(cancellable)
    }

    public func cancel() {
        cancellable.withLock { $0?.cancel(); $0 = nil }
    }

    deinit { cancel() }
}

private final class OwnLyricsRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: (@Sendable (Database, String) throws -> Void)?

    func set(_ value: (@Sendable (Database, String) throws -> Void)?) {
        lock.withLock { recorder = value }
    }

    func record(_ db: Database, _ videoId: String) throws {
        let current = lock.withLock { recorder }
        try current?(db, videoId)
    }
}
