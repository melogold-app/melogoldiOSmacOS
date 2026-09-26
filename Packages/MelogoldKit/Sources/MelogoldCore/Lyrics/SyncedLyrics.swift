import Foundation

/// Точность времени текста: строки целиком или каждое слово (слог).
public enum LyricsTiming: String, Sendable, Codable {
    case line = "Line"
    case word = "Word"
}

/// Сторона голоса в дуэте: первый исполнитель у начального края, второй — у конечного (в RTL зеркально).
public enum VocalSide: String, Sendable, Codable {
    case start = "Start"
    case end = "End"
}

/// Исполнитель дуэта (`ttm:agent`); сторона — по порядку объявления или появления.
public struct LyricsAgent: Hashable, Sendable, Codable {
    public var id: String
    public var side: VocalSide
    public var name: String?

    public init(id: String, side: VocalSide, name: String? = nil) {
        self.id = id
        self.side = side
        self.name = name
    }
}

/// Слово или слог со временем. Пробел после слова входит в текст: склейка слов строки даёт строку.
public struct SyncedWord: Hashable, Sendable, Codable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String

    public init(startMs: Int64, endMs: Int64, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// Подпевка строки (`ttm:role="x-bg"`): мельче, под основной строкой.
public struct BackingVocals: Hashable, Sendable, Codable {
    public var startMs: Int64
    public var endMs: Int64
    public var words: [SyncedWord]

    public init(startMs: Int64, endMs: Int64, words: [SyncedWord]) {
        self.startMs = startMs
        self.endMs = endMs
        self.words = words
    }

    public var text: String { words.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
}

/// Строка синхронного текста.
public struct SyncedLine: Hashable, Sendable, Codable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    /// Слова со временем; пусто, если время есть только у строки.
    public var words: [SyncedWord]
    /// Исполнитель (`SyncedLyrics.agents`); `nil`, если текст не говорит.
    public var agent: String?
    public var side: VocalSide
    /// BCP 47, если отличается от языка всего текста или уточняет его.
    public var language: String?
    public var background: BackingVocals?
    public var translation: String?
    public var transliteration: String?

    public init(startMs: Int64, endMs: Int64, text: String, words: [SyncedWord] = [], agent: String? = nil, side: VocalSide = .start,
                language: String? = nil, background: BackingVocals? = nil, translation: String? = nil, transliteration: String? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.words = words
        self.agent = agent
        self.side = side
        self.language = language
        self.background = background
        self.translation = translation
        self.transliteration = transliteration
    }
}

/// Синхронный текст в модели Melogold (`spec/lyrics.md`, Android `SyncedLyrics.kt`, Windows `SyncedLyrics.cs`): строки,
/// время слов, стороны дуэта, подпевка, языки, переводы. Читается из LRC, расширенного LRC и TTML, пишется в TTML и LRC.
public struct SyncedLyrics: Hashable, Sendable, Codable {
    public var lines: [SyncedLine]
    public var timing: LyricsTiming
    public var agents: [LyricsAgent]
    public var language: String?

    public init(lines: [SyncedLine], timing: LyricsTiming, agents: [LyricsAgent], language: String? = nil) {
        self.lines = lines
        self.timing = timing
        self.agents = agents
        self.language = language
    }

    public var isDuet: Bool { lines.contains { $0.side == .end } }

    /// Стороны по порядку появления: первый — у начала, второй — у конца, дальше по очереди.
    static func assignSides(_ ids: [String]) -> [LyricsAgent] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.enumerated().map {
            LyricsAgent(id: $0.element, side: $0.offset % 2 == 0 ? .start : .end)
        }
    }
}

/// Строка экрана синхронного текста: спетая строка или проигрыш (три точки).
public enum LyricRow: Hashable, Sendable {
    case sung(SyncedLine)
    /// `side` — сторона строки после паузы: туда смотрят дальше.
    case interlude(startMs: Int64, endMs: Int64, side: VocalSide)

    public var startMs: Int64 {
        switch self {
        case .sung(let line): line.startMs
        case .interlude(let start, _, _): start
        }
    }

    public var endMs: Int64 {
        switch self {
        case .sung(let line): line.endMs
        case .interlude(_, let end, _): end
        }
    }
}

/// Строки экрана текста (Android `LyricsModel.kt`, Windows `LyricRows.cs`): проигрыш — перед первой строкой и в паузах
/// от 4 с; строки-заполнители («♪», «…») становятся проигрышем или исчезают.
public enum LyricRows {
    public static let interludeMinGapMs: Int64 = 4_000
    private static let noteCharacters: Set<Character> = ["♪", "♫", "♬", "♩", "…", "."]

    static func isFiller(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).allSatisfy { noteCharacters.contains($0) || $0.isWhitespace }
    }

    public static func build(_ lyrics: SyncedLyrics) -> [LyricRow] {
        let sung = lyrics.lines.filter { !isFiller($0.text) }.sorted { $0.startMs < $1.startMs }
        guard let first = sung.first else { return [] }
        var rows: [LyricRow] = []
        if first.startMs >= interludeMinGapMs { rows.append(.interlude(startMs: 0, endMs: first.startMs, side: first.side)) }
        for (index, line) in sung.enumerated() {
            rows.append(.sung(line))
            guard index + 1 < sung.count else { continue }
            let next = sung[index + 1]
            // Строка-заполнитель между ними заканчивает спетую там, где начинается
            let filler = lyrics.lines.first { $0.startMs > line.startMs && $0.startMs < next.startMs && isFiller($0.text) }
            let gapStart = filler.map { min($0.startMs, line.endMs) } ?? line.endMs
            if next.startMs - gapStart >= interludeMinGapMs {
                rows.append(.interlude(startMs: gapStart, endMs: next.startMs, side: next.side))
            }
        }
        return rows
    }

    /// Индекс последней строки с началом не позже `positionMs`; −1 до первой.
    public static func activeIndex(_ rows: [LyricRow], at positionMs: Int64) -> Int {
        var low = 0, high = rows.count - 1, result = -1
        while low <= high {
            let mid = (low + high) / 2
            if rows[mid].startMs <= positionMs {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

extension StoredLyrics {
    /// Пустой итог поиска: стороны «искали, нет».
    public static let empty = StoredLyrics(synced: nil, plain: nil, syncedSource: nil, plainSource: nil)

    /// Свой текст — хотя бы одна сторона от пользователя или из файла (задание 0001 §3.2).
    public var isOwn: Bool { LyricsSyncRules.isOwn(self) }
}

extension LyricsSources {
    /// Свой текст — импорт файла или редактор: он уходит на сервер.
    public static func isOwn(_ source: String?) -> Bool { source == file || source == user }
}
