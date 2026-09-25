import CryptoKit
import Foundation

/// Откуда текст — словарь сервера (API §4.10) и `melogold`, общий текст сообщества.
public enum LyricsSources {
    public static let youtubeMusic = "youtube_music"
    public static let lrclib = "lrclib"
    public static let kugou = "kugou"
    public static let file = "file"
    public static let user = "user"
    /// Общий текст другого пользователя с сервера: показывается, но своим не становится.
    public static let melogold = "melogold"
}

/// Строка таблицы `lyrics`: синхронная и обычная стороны со своими источниками (`source` — синхронной),
/// сдвиг синхронного текста и язык. Пустая сторона — «искали, нет».
public struct StoredLyrics: Equatable, Sendable {
    public var synced: String?
    public var plain: String?
    public var syncedSource: String?
    public var plainSource: String?
    public var offsetMs: Int64
    public var language: String?

    public init(synced: String?, plain: String?, syncedSource: String?, plainSource: String?, offsetMs: Int64 = 0, language: String? = nil) {
        self.synced = synced
        self.plain = plain
        self.syncedSource = syncedSource
        self.plainSource = plainSource
        self.offsetMs = offsetMs
        self.language = language
    }
}

/// Текст в форме сервера (`LyricsPut` и `LyricsText`, API §4.10).
public struct LyricsPayload: Equatable, Sendable {
    public var plain: String?
    public var plainSource: String?
    public var synced: String?
    public var syncedFormat: String?
    public var syncedSource: String?
    public var startTimeMs: Int64?
    public var language: String?

    public init(
        plain: String?, plainSource: String?, synced: String?, syncedFormat: String?, syncedSource: String?,
        startTimeMs: Int64?, language: String?
    ) {
        self.plain = plain
        self.plainSource = plainSource
        self.synced = synced
        self.syncedFormat = syncedFormat
        self.syncedSource = syncedSource
        self.startTimeMs = startTimeMs
        self.language = language
    }
}

/// Что снимок знает о своей версии на сервере: `rev` и хэш содержимого. `rev` −1 — сервер отказал (413, 400)
/// или текст длиннее лимита: не отправлять, пока текст не изменится.
public struct LyricsSnapshot: Equatable, Sendable {
    public static let rejected: Int64 = -1

    public var rev: Int64
    public var hash: String

    public init(rev: Int64, hash: String) {
        self.rev = rev
        self.hash = hash
    }
}

/// Что отправить на сервер по итогам сравнения со снимком.
public enum LyricsSend: Equatable, Sendable {
    /// Своего текста нет в снимке или он изменился: `PUT`.
    case put(videoId: String, payload: LyricsPayload, hash: String)
    /// Свой текст был на сервере, а здесь его больше нет: `DELETE`.
    case delete(videoId: String)
    /// Текст сервер не принял, и здесь его больше нет: просто забыть.
    case forget(videoId: String)
}

/// Правила синхронизации текстов (задание 0001 §3), одинаковые с Android и Windows (`LyricsSyncRules.cs`).
/// Свой текст — строка, у которой хотя бы одна сторона из источника `user` или `file`; он уходит на сервер целиком,
/// обеими сторонами. Найденные провайдерами тексты и общий текст сообщества (`melogold`) своими не считаются.
public enum LyricsSyncRules {
    /// Лимиты сервера (API §4.10), в единицах UTF-16.
    public static let plainMax = 50_000
    public static let syncedMax = 200_000
    public static let languageMax = 35
    public static let startTimeMaxMs: Int64 = 86_400_000

    private static func isOwnSource(_ source: String?) -> Bool {
        source == LyricsSources.user || source == LyricsSources.file
    }

    /// Источники, которые принимает сервер; общий текст (`melogold`) уходит без источника.
    private static func serverSource(_ source: String?) -> String? {
        switch source {
        case LyricsSources.user, LyricsSources.file, LyricsSources.youtubeMusic, LyricsSources.lrclib, LyricsSources.kugou: source
        default: nil
        }
    }

    private static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public static func isOwn(_ lyrics: StoredLyrics) -> Bool {
        (isOwnSource(lyrics.syncedSource) && text(lyrics.synced) != nil) || (isOwnSource(lyrics.plainSource) && text(lyrics.plain) != nil)
    }

    /// Содержимое для `PUT`: пустые стороны не отправляются, источник — только со своей стороной, формат — по
    /// содержимому (LRC или TTML), сдвиг «раньше» — как `startTimeMs`. Сдвиг «позже» сервер не хранит.
    public static func payload(_ lyrics: StoredLyrics) -> LyricsPayload {
        var synced = text(lyrics.synced)
        let format = synced.flatMap(syncedFormat)
        // Синхронный текст, который не разбирается ни как LRC, ни как TTML, серверу не нужен
        if format == nil { synced = nil }
        let plain = text(lyrics.plain)
        let language = text(lyrics.language).flatMap { $0.utf16.count <= languageMax ? $0 : nil }
        return LyricsPayload(
            plain: plain,
            plainSource: plain == nil ? nil : serverSource(lyrics.plainSource),
            synced: synced,
            syncedFormat: format,
            syncedSource: synced == nil ? nil : serverSource(lyrics.syncedSource),
            startTimeMs: synced == nil || lyrics.offsetMs >= 0 ? nil : min(-lyrics.offsetMs, startTimeMaxMs),
            language: language
        )
    }

    /// Сторона длиннее лимита сервера: такой текст не отправляется, он остаётся только здесь.
    public static func tooLarge(_ payload: LyricsPayload) -> Bool {
        (payload.plain?.utf16.count ?? 0) > plainMax || (payload.synced?.utf16.count ?? 0) > syncedMax
    }

    /// Версия с сервера совпадает с тем, что уже лежит здесь (в том числе эхо своей же отправки): строку не
    /// перезаписывать, чтобы не потерять то, что сервер не хранит.
    public static func sameContent(_ local: StoredLyrics?, _ incoming: StoredLyrics) -> Bool {
        guard let local else { return false }
        return hash(payload(local)) == hash(payload(incoming))
    }

    /// Версия с сервера — как строка здесь: отсутствующая сторона пустая, источники как есть.
    public static func stored(_ payload: LyricsPayload) -> StoredLyrics {
        StoredLyrics(
            synced: payload.synced ?? "",
            plain: payload.plain ?? "",
            syncedSource: payload.synced == nil ? nil : payload.syncedSource,
            plainSource: payload.plain == nil ? nil : payload.plainSource,
            offsetMs: -(payload.startTimeMs ?? 0),
            language: payload.language
        )
    }

    /// SHA-256 полей `LyricsPayload` в постоянном порядке, как у Windows: разделитель U+001F, пустое поле — U+0000.
    public static func hash(_ payload: LyricsPayload) -> String {
        func field(_ value: String?) -> String { value ?? "\u{0}" }
        let text = [
            field(payload.plain), field(payload.plainSource), field(payload.synced), field(payload.syncedFormat),
            field(payload.syncedSource), payload.startTimeMs.map(String.init) ?? "\u{0}", field(payload.language),
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Отправка (задание 0001 §3.3.1): свой текст, которого нет в снимке или чей хэш изменился, — `PUT`; строка
    /// снимка, у которой больше нет своего текста, — `DELETE`. Отклонённый текст повторно не уходит, пока не изменится.
    public static func planSends(own: [String: StoredLyrics], snapshot: [String: LyricsSnapshot]) -> [LyricsSend] {
        var sends: [LyricsSend] = []
        for videoId in own.keys.sorted(by: SortKeys.precedes) {
            guard let lyrics = own[videoId] else { continue }
            let payload = payload(lyrics)
            if payload.plain == nil && payload.synced == nil { continue }
            let hash = hash(payload)
            if snapshot[videoId]?.hash == hash { continue }
            sends.append(.put(videoId: videoId, payload: payload, hash: hash))
        }
        for videoId in snapshot.keys.sorted(by: SortKeys.precedes) where own[videoId] == nil {
            sends.append(snapshot[videoId]?.rev == LyricsSnapshot.rejected ? .forget(videoId: videoId) : .delete(videoId: videoId))
        }
        return sends
    }

    /// Надгробие с сервера (§3.3.2): свой текст здесь удаляется, только если он не менялся с прошлого синка (хэш равен
    /// снимку). Изменённый остаётся и уйдёт на сервер следующей отправкой.
    public static func deleteOnTombstone(_ local: StoredLyrics?, _ snapshot: LyricsSnapshot?) -> Bool {
        guard let local, isOwn(local), let snapshot else { return false }
        return hash(payload(local)) == snapshot.hash
    }

    /// `ttml` или `lrc` по содержимому; `nil` — обычный текст (как `LyricsFormats.Detect` Windows).
    public static func syncedFormat(_ text: String) -> String? {
        if looksLikeTtml(text) { return "ttml" }
        if looksLikeLrc(text) { return "lrc" }
        return nil
    }

    private static func looksLikeTtml(_ text: String) -> Bool {
        let head = String(text.drop { $0.isWhitespace }.prefix(512))
        return (head.hasPrefix("<?xml") || head.hasPrefix("<tt")) && head.contains("<tt")
    }

    /// Хотя бы одна строка начинается с метки времени `[m:ss]`, `[mm:ss.xx]`, `[mmm:ss:xxx]`.
    private static func looksLikeLrc(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            var bytes = Substring(line).trimmingCharacters(in: .whitespaces).utf8[...]
            func digits(_ range: ClosedRange<Int>) -> Bool {
                let count = bytes.prefix { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }.count
                guard range.contains(count) else { return false }
                bytes = bytes.dropFirst(count)
                return true
            }
            func take(_ char: Character) -> Bool {
                guard bytes.first == char.asciiValue else { return false }
                bytes = bytes.dropFirst()
                return true
            }
            guard take("["), digits(1 ... 3), take(":"), digits(1 ... 2) else { return false }
            if take(".") || take(":") { guard digits(1 ... 3) else { return false } }
            return take("]")
        }
    }
}
