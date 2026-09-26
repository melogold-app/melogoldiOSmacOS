import Foundation

/// LRC и расширенный LRC (A2): `[мм:сс.xx]строка`, несколько меток у строки, `[offset:±мс]`, метки слов `<мм:сс.xx>`
/// и дуэты «walaoke» `M:`, `F:`, `D:` (`spec/lyrics.md`, Android `LrcFormat.kt`, Windows `LyricsFormats.cs`).
public enum LrcFormat {
    private static let lastLineMs: Int64 = 5_000

    /// Похоже на LRC: хотя бы одна строка начинается с метки времени.
    public static func matches(_ text: String) -> Bool {
        lines(text).contains { lineTag($0.trimmingCharacters(in: .whitespaces)) != nil }
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// `[мм:сс.xx]` в начале строки: время и длина метки.
    private static func lineTag(_ line: String) -> (ms: Int64, length: Int)? {
        guard let match = line.prefixMatch(of: /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/) else { return nil }
        return (millis(match.output.1, match.output.2, match.output.3), line.distance(from: line.startIndex, to: match.range.upperBound))
    }

    private struct RawLine {
        var startMs: Int64
        var text: String
        var words: [SyncedWord]?
        var agent: String?
    }

    /// Разбор LRC; `nil`, если ни одна строка не размечена временем.
    public static func parse(_ text: String) -> SyncedLyrics? {
        var offsetMs: Int64 = 0
        var agent: String?
        var raw: [RawLine] = []
        for source in lines(text) {
            var line = source.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let meta = line.wholeMatch(of: /\[([a-zA-Z#]+):(.*)\]\s*/) {
                if meta.output.1.lowercased() == "offset" {
                    var value = meta.output.2.trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("+") { value.removeFirst() }
                    offsetMs = Int64(value) ?? 0
                }
                continue
            }
            // Все метки перед текстом
            var starts: [Int64] = []
            while let tag = lineTag(line) {
                starts.append(tag.ms)
                line = String(line.dropFirst(tag.length))
            }
            if starts.isEmpty { continue }
            if let duet = line.prefixMatch(of: /\s*([MFD]):\s?/) {
                agent = String(duet.output.1)
                line = String(line[duet.range.upperBound...])
            }
            let words = parseWords(line)
            let lineText = words.map { $0.isEmpty ? line.trimmingCharacters(in: .whitespaces) : $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
                ?? line.trimmingCharacters(in: .whitespaces)
            for start in starts {
                raw.append(RawLine(startMs: max(0, start - offsetMs), text: lineText,
                                   words: words.map { shiftWords($0, tagBase: start, lineStart: start - offsetMs) }, agent: agent))
            }
        }

        let sorted = raw.enumerated().sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }.map(\.element)
        if sorted.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { return nil }
        let agents = SyncedLyrics.assignSides(sorted.compactMap(\.agent))
        let sides = Dictionary(agents.map { ($0.id, $0.side) }, uniquingKeysWith: { first, _ in first })
        let wordTimed = sorted.contains { !($0.words ?? []).isEmpty }

        var result: [SyncedLine] = []
        for (index, line) in sorted.enumerated() {
            // Пустая строка с меткой только отмечает конец предыдущей
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let next = index + 1 < sorted.count ? sorted[index + 1].startMs : nil
            let words = (line.words ?? []).filter { !$0.text.isEmpty }
            // Последняя метка без текста («…слово<00:13.20>») — конец строки
            let explicitEnd: Int64? = if let all = line.words, let last = all.last, last.text.isEmpty { last.startMs } else { nil }
            let end: Int64 = if let explicitEnd, explicitEnd > line.startMs {
                explicitEnd
            } else if let next, next > line.startMs {
                next
            } else {
                line.startMs + lastLineMs
            }
            result.append(SyncedLine(
                startMs: line.startMs, endMs: end, text: line.text,
                words: words.map { SyncedWord(startMs: $0.startMs, endMs: $0.endMs > $0.startMs ? $0.endMs : end, text: $0.text) },
                agent: line.agent, side: line.agent.flatMap { sides[$0] } ?? .start
            ))
        }
        return SyncedLyrics(lines: result, timing: wordTimed ? .word : .line, agents: agents)
    }

    /// LRC: расширенный (с метками слов), если текст размечен по словам; дуэт из 2–3 исполнителей — walaoke.
    public static func write(_ lyrics: SyncedLyrics, enhanced: Bool = true) -> String {
        var output = ""
        let walaoke = (2...3).contains(lyrics.agents.count)
        let prefixes = Dictionary(lyrics.agents.prefix(3).enumerated().map { ($0.element.id, Array("MFD")[$0.offset]) },
                                  uniquingKeysWith: { first, _ in first })
        var lastAgent: String?
        for (index, line) in lyrics.lines.enumerated() {
            output += "[\(timestamp(line.startMs))]"
            if walaoke, let agent = line.agent, agent != lastAgent, let prefix = prefixes[agent] {
                output += "\(prefix): "
                lastAgent = agent
            }
            if enhanced, let lastWord = line.words.last {
                for word in line.words { output += "<\(timestamp(word.startMs))>\(word.text)" }
                output += "<\(timestamp(lastWord.endMs))>"
            } else {
                output += line.text
            }
            output += "\n"
            // Пауза перед следующей строкой — закрыть эту пустой строкой
            if index + 1 >= lyrics.lines.count || lyrics.lines[index + 1].startMs > line.endMs {
                output += "[\(timestamp(line.endMs))]\n"
            }
        }
        return output
    }

    private static func parseWords(_ line: String) -> [SyncedWord]? {
        let tags = line.matches(of: /<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>/)
        guard !tags.isEmpty else { return nil }
        return tags.enumerated().map { index, tag in
            let textEnd = index + 1 < tags.count ? tags[index + 1].range.lowerBound : line.endIndex
            let text = String(line[tag.range.upperBound..<textEnd])
            let start = millis(tag.output.1, tag.output.2, tag.output.3)
            return SyncedWord(startMs: start, endMs: start, text: text)
        }
    }

    /// Слово кончается там, где начинается следующее; пустая метка в конце заканчивает последнее.
    private static func shiftWords(_ words: [SyncedWord], tagBase: Int64, lineStart: Int64) -> [SyncedWord] {
        let delta = lineStart - tagBase
        return words.enumerated().map { index, word in
            let end = index + 1 < words.count ? words[index + 1].startMs : word.startMs
            return SyncedWord(startMs: max(0, word.startMs + delta), endMs: max(0, end + delta), text: word.text)
        }
    }

    private static func millis(_ minutes: Substring, _ seconds: Substring, _ fraction: Substring?) -> Int64 {
        let fractionText = fraction.map(String.init) ?? ""
        let fractionMs: Int64 = switch fractionText.count {
        case 0: 0
        case 1: (Int64(fractionText) ?? 0) * 100
        case 2: (Int64(fractionText) ?? 0) * 10
        default: Int64(fractionText.prefix(3)) ?? 0
        }
        return ((Int64(minutes) ?? 0) * 60 + (Int64(seconds) ?? 0)) * 1000 + fractionMs
    }

    /// `мм:сс.xx`, или `мм:сс.xxx`, если сотые потеряли бы время.
    static func timestamp(_ ms: Int64) -> String {
        let total = max(0, ms)
        let minutes = total / 60_000, seconds = total / 1000 % 60, millis = total % 1000
        return millis % 10 == 0
            ? String(format: "%02lld:%02lld.%02lld", minutes, seconds, millis / 10)
            : String(format: "%02lld:%02lld.%03lld", minutes, seconds, millis)
    }
}

/// Парсер файла текста по содержимому.
public enum LyricsFormats {
    public enum Format: Sendable {
        case ttml, lrc, plain
    }

    public static func detect(_ text: String) -> Format {
        TtmlFormat.matches(text) ? .ttml : LrcFormat.matches(text) ? .lrc : .plain
    }

    /// Синхронный текст из TTML или LRC; `nil` для простого текста или битого файла.
    public static func parseSynced(_ text: String) -> SyncedLyrics? {
        switch detect(text) {
        case .ttml: TtmlFormat.parse(text)
        case .lrc: LrcFormat.parse(text)
        case .plain: nil
        }
    }
}
