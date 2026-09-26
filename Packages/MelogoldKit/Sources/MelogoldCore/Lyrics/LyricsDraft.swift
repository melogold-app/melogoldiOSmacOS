import Foundation

/// Строка в редакторе текста (`spec/lyrics.md`, «Редактор»; Android `DraftLine`, Windows `DraftLine`).
public struct DraftLine: Hashable, Sendable {
    public var text: String
    /// Начало строки в треке; `nil` — ещё не отмечена.
    public var startMs: Int64?
    /// Свой конец строки — пауза до следующей; `nil` — строку заканчивает следующая.
    public var endMs: Int64?
    /// Начала слов `text` (`LyricsDraft.splitWords`) в режиме слов; пусто — не отмечены.
    public var wordStarts: [Int64?]
    public var side: VocalSide
    /// Подпевка под строкой, в скобках: «(у-у)».
    public var backing: String?
    public var language: String?

    public init(text: String, startMs: Int64? = nil, endMs: Int64? = nil, wordStarts: [Int64?] = [], side: VocalSide = .start,
                backing: String? = nil, language: String? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.wordStarts = wordStarts
        self.side = side
        self.backing = backing
        self.language = language
    }

    public var words: [String] { LyricsDraft.splitWords(text) }

    /// У каждого слова есть начало (режим слов для строки закончен).
    public var wordsTimed: Bool {
        let count = words.count
        return count > 0 && wordStarts.count == count && wordStarts.allSatisfy { $0 != nil }
    }

    /// Текст, как его показывает редактор: строка, затем подпевка.
    public var fullText: String { backing.map { "\(text) \($0)" } ?? text }
}

/// Черновик редактора текста (Android `LyricsDraft`, Windows `LyricsDraft`, те же правила): строки, строка (и в режиме
/// слов — слово), которую отметит следующее нажатие, и что отмечается — строки или слова. Каждая операция возвращает
/// новый черновик, поэтому редактор хранит прежние для «Отменить».
public struct LyricsDraft: Hashable, Sendable {
    /// Строка без своего конца и без следующей длится столько (как в LRC).
    public static let defaultLineMs: Int64 = 5_000
    /// Человек нажимает чуть позже, чем слышит: редактор вычитает это из позиции.
    public static let reactionMs: Int64 = 150

    public var lines: [DraftLine]
    public var cursor: Int
    public var wordCursor: Int
    public var timing: LyricsTiming
    public var language: String?

    public init(lines: [DraftLine], cursor: Int = 0, wordCursor: Int = 0, timing: LyricsTiming = .line, language: String? = nil) {
        self.lines = lines
        self.cursor = cursor
        self.wordCursor = wordCursor
        self.timing = timing
        self.language = language
    }

    /// Слова строки, как их отмечает редактор: через пробел, знаки препинания — при слове.
    public static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Отмечена хотя бы одна строка — черновик даёт синхронный текст.
    public var hasTiming: Bool { lines.contains { $0.startMs != nil } }

    /// Отмечены все строки.
    public var complete: Bool { !lines.isEmpty && lines.allSatisfy { $0.startMs != nil } }

    /// Черновик обычным текстом: строка на строку, подпевка в конце своей строки.
    public func toText() -> String { lines.map(\.fullText).joined(separator: "\n") }

    /// Отметить следующую строку (или слово) временем `positionMs` и перейти дальше. Начавшаяся строка заканчивает
    /// предыдущую, если у той нет своего конца (`markEnd`).
    public func mark(_ positionMs: Int64) -> LyricsDraft {
        guard cursor >= 0, cursor < lines.count else { return self }
        let line = lines[cursor]
        let position = max(0, positionMs)
        var copy = self

        if timing == .line || line.words.isEmpty {
            var updated = line
            updated.startMs = position
            updated.wordStarts = []
            copy.lines[cursor] = updated
            copy.lines = Self.endingPrevious(copy.lines, before: cursor, at: position)
            return copy.moved(to: cursor + 1)
        }

        let words = line.words
        var starts = (0..<words.count).map { $0 < line.wordStarts.count ? line.wordStarts[$0] : nil }
        let word = min(max(wordCursor, 0), words.count - 1)
        starts[word] = position
        var marked = line
        marked.startMs = word == 0 ? position : (line.startMs ?? position)
        marked.wordStarts = starts
        copy.lines[cursor] = marked
        if word == 0 { copy.lines = Self.endingPrevious(copy.lines, before: cursor, at: position) }
        if word < words.count - 1 {
            copy.wordCursor = word + 1
            return copy
        }
        return copy.moved(to: cursor + 1)
    }

    /// Закончить последнюю отмеченную строку в `positionMs`: до следующей — пауза (проигрыш, если долгая).
    public func markEnd(_ positionMs: Int64) -> LyricsDraft {
        let index = min(cursor - 1, lines.count - 1)
        guard index >= 0, let start = lines[index].startMs else { return self }
        var copy = self
        copy.lines[index].endMs = max(positionMs, start + 1)
        return copy
    }

    /// Сдвинуть начало строки `index` (и её слова) на `deltaMs`; время не меньше 0.
    public func nudge(_ index: Int, by deltaMs: Int64) -> LyricsDraft {
        guard lines.indices.contains(index), let start = lines[index].startMs else { return self }
        func moved(_ value: Int64) -> Int64 { max(0, value + deltaMs) }
        var copy = self
        copy.lines[index].startMs = moved(start)
        copy.lines[index].endMs = lines[index].endMs.map(moved)
        copy.lines[index].wordStarts = lines[index].wordStarts.map { $0.map(moved) }
        return copy
    }

    /// Всё время на `deltaMs`: текст со сдвигом начала становится временем трека.
    public func shifted(by deltaMs: Int64) -> LyricsDraft {
        guard deltaMs != 0 else { return self }
        func moved(_ value: Int64) -> Int64 { max(0, value + deltaMs) }
        var copy = self
        copy.lines = lines.map { line in
            var updated = line
            updated.startMs = line.startMs.map(moved)
            updated.endMs = line.endMs.map(moved)
            updated.wordStarts = line.wordStarts.map { $0.map(moved) }
            return updated
        }
        return copy
    }

    /// Забыть время строки `index`.
    public func clearingTiming(_ index: Int) -> LyricsDraft {
        update(index) { $0.startMs = nil; $0.endMs = nil; $0.wordStarts = [] }
    }

    /// Следующая отметка — строка `index` (с первого слова).
    public func moved(to index: Int) -> LyricsDraft {
        var copy = self
        copy.cursor = min(max(index, 0), lines.count)
        copy.wordCursor = 0
        return copy
    }

    public func withSide(_ index: Int, _ side: VocalSide) -> LyricsDraft { update(index) { $0.side = side } }

    public func withBacking(_ index: Int, _ backing: String?) -> LyricsDraft {
        update(index) { line in
            let text = backing?.trimmingCharacters(in: .whitespaces) ?? ""
            line.backing = text.isEmpty ? nil : Self.inParentheses(text)
        }
    }

    public func withLineLanguage(_ index: Int, _ language: String?) -> LyricsDraft { update(index) { $0.language = language } }

    public func withTiming(_ timing: LyricsTiming) -> LyricsDraft {
        var copy = self
        copy.timing = timing
        copy.wordCursor = 0
        return copy
    }

    /// Черновик с новым текстом (строка на строку, подпевка в скобках в конце): у строк, текст которых не изменился
    /// (наибольшая общая подпоследовательность), остаются время, сторона и язык; следующая отметка — первая неотмеченная.
    public func withText(_ text: String) -> LyricsDraft {
        let fresh = Self.linesOf(text)
        let matches = Self.matchUnchanged(lines.map(\.fullText), fresh.map(\.fullText))
        let merged = fresh.enumerated().map { index, line -> DraftLine in
            guard let old = matches[index] else { return line }
            var kept = lines[old]
            kept.text = line.text
            kept.backing = line.backing
            return kept
        }
        var copy = self
        copy.lines = merged
        return copy.moved(to: merged.firstIndex { $0.startMs == nil } ?? merged.count)
    }

    /// Синхронный текст отмеченных строк по времени; `nil` — не отмечено ничего. Строка без своего конца длится до
    /// начала следующей (последняя — `defaultLineMs`).
    public func toSyncedLyrics() -> SyncedLyrics? {
        let timed = lines.filter { $0.startMs != nil }.enumerated()
            .sorted { ($0.element.startMs!, $0.offset) < ($1.element.startMs!, $1.offset) }.map(\.element)
        guard !timed.isEmpty else { return nil }
        let duet = timed.contains { $0.side == .end }
        let wordTimed = timing == .word && timed.allSatisfy(\.wordsTimed)
        let result = timed.enumerated().map { index, line -> SyncedLine in
            let start = line.startMs!
            let next = index + 1 < timed.count ? timed[index + 1].startMs : nil
            let end = max(line.endMs ?? next ?? start + Self.defaultLineMs, start + 1)
            return SyncedLine(
                startMs: start, endMs: end, text: line.text, words: wordTimed ? Self.wordsOf(line, end: end) : [],
                agent: duet ? Self.agent(line.side) : nil, side: line.side, language: line.language,
                background: line.backing.map { BackingVocals(startMs: start, endMs: end, words: [SyncedWord(startMs: start, endMs: end, text: $0)]) }
            )
        }
        return SyncedLyrics(
            lines: result, timing: wordTimed ? .word : .line,
            agents: duet ? [LyricsAgent(id: Self.agent(.start), side: .start), LyricsAgent(id: Self.agent(.end), side: .end)] : [],
            language: language
        )
    }

    /// Черновик из текста: строка на непустую строку, «(…)» в конце строки — подпевка.
    public static func fromText(_ text: String, language: String? = nil) -> LyricsDraft {
        LyricsDraft(lines: linesOf(text), language: language)
    }

    /// Черновик готового синхронного текста — чтобы его править.
    public static func from(_ lyrics: SyncedLyrics) -> LyricsDraft {
        var result = lyrics.lines.map { line in
            DraftLine(
                text: line.text, startMs: line.startMs, endMs: line.endMs,
                wordStarts: !line.words.isEmpty && line.words.count == splitWords(line.text).count ? line.words.map { $0.startMs } : [],
                side: line.side,
                backing: line.background.flatMap { $0.text.isEmpty ? nil : inParentheses($0.text) },
                language: line.language
            )
        }
        // Свой конец остаётся только там, где он оставляет паузу: в остальных местах строку заканчивает следующая
        for index in result.indices {
            if let end = result[index].endMs, index + 1 < result.count, let next = result[index + 1].startMs, end >= next {
                result[index].endMs = nil
            }
        }
        return LyricsDraft(lines: result, cursor: lyrics.lines.count, wordCursor: 0, timing: lyrics.timing, language: lyrics.language)
    }

    private func update(_ index: Int, _ transform: (inout DraftLine) -> Void) -> LyricsDraft {
        guard lines.indices.contains(index) else { return self }
        var copy = self
        transform(&copy.lines[index])
        return copy
    }

    private static func agent(_ side: VocalSide) -> String { side == .start ? "v1" : "v2" }

    private static func inParentheses(_ text: String) -> String {
        text.hasPrefix("(") && text.hasSuffix(")") ? text : "(\(text))"
    }

    private static func linesOf(_ text: String) -> [DraftLine] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if let match = line.wholeMatch(of: /(.*\S)\s+(\([^()]*\))\s*/) {
                    return DraftLine(text: String(match.output.1), backing: String(match.output.2))
                }
                return DraftLine(text: line)
            }
    }

    /// Слова строки: каждое до начала следующего, последнее — до `end`.
    private static func wordsOf(_ line: DraftLine, end: Int64) -> [SyncedWord] {
        let words = line.words
        return words.enumerated().map { index, word in
            let start = line.wordStarts[index]!
            let wordEnd = max(index + 1 < words.count ? line.wordStarts[index + 1]! : end, start + 1)
            return SyncedWord(startMs: start, endMs: wordEnd, text: index < words.count - 1 ? word + " " : word)
        }
    }

    /// Последняя отмеченная строка до `index` заканчивается в `position`, если у неё нет своего конца раньше.
    private static func endingPrevious(_ lines: [DraftLine], before index: Int, at position: Int64) -> [DraftLine] {
        var copy = lines
        var i = index - 1
        while i >= 0 {
            if copy[i].startMs == nil {
                i -= 1
                continue
            }
            if let end = copy[i].endMs, end <= position { return copy }
            copy[i].endMs = nil
            return copy
        }
        return copy
    }

    /// Для строк нового текста — индекс той же строки в старом, если она в наибольшей общей подпоследовательности.
    private static func matchUnchanged(_ old: [String], _ fresh: [String]) -> [Int: Int] {
        var lengths = Array(repeating: Array(repeating: 0, count: fresh.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: fresh.count - 1, through: 0, by: -1) {
                lengths[i][j] = old[i] == fresh[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var matches: [Int: Int] = [:]
        var a = 0, b = 0
        while a < old.count, b < fresh.count {
            if old[a] == fresh[b] {
                matches[b] = a
                a += 1
                b += 1
            } else if lengths[a + 1][b] >= lengths[a][b + 1] {
                a += 1
            } else {
                b += 1
            }
        }
        return matches
    }
}
