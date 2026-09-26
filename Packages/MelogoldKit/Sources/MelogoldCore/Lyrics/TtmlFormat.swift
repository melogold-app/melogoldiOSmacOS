import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// TTML, как пишут Apple Music и база AMLL TTML: строки `p` со словами `span`, исполнители `ttm:agent`, подпевка
/// `x-bg`, перевод и транскрипция, `xml:lang`. В нём Melogold хранит тексты и делится ими (Windows `TtmlFormat`).
public enum TtmlFormat {
    static let nsTtml = "http://www.w3.org/ns/ttml"
    static let nsTtm = "http://www.w3.org/ns/ttml#metadata"
    static let nsItunes = "http://music.apple.com/lyric-ttml-internal"
    static let nsXml = "http://www.w3.org/XML/1998/namespace"

    public static func matches(_ text: String) -> Bool {
        let head = String(text.drop { $0.isWhitespace }.prefix(512))
        return (head.hasPrefix("<?xml") || head.hasPrefix("<tt")) && head.contains("<tt")
    }

    /// Разбор TTML; `nil`, если это не TTML или в нём нет строк со временем.
    public static func parse(_ text: String) -> SyncedLyrics? {
        // Без DTD и внешних сущностей: файлы текстов приходят откуда угодно.
        if text.contains("<!DOCTYPE") || text.contains("<!ENTITY") { return nil }
        guard let root = XMLTree.parse(text), root.local == "tt" else { return nil }

        let declared: [(id: String, name: String?)] = root.descendants.filter { $0.local == "agent" }.compactMap { agent in
            guard let id = agent.attribute(nsXml, "id") else { return nil }
            let name = agent.descendants.first { $0.local == "name" }?.innerText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (id, name?.isEmpty == false ? name : nil)
        }
        let parsed = root.descendants.filter { $0.local == "p" }.compactMap(parseLine)
            .enumerated().sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }.map(\.element)
        guard !parsed.isEmpty else { return nil }

        let order = declared.map(\.id) + parsed.compactMap(\.agent)
        var names: [String: String] = [:]
        for agent in declared where names[agent.id] == nil { if let name = agent.name { names[agent.id] = name } }
        let agents = SyncedLyrics.assignSides(order).map { LyricsAgent(id: $0.id, side: $0.side, name: names[$0.id]) }
        let sides = Dictionary(agents.map { ($0.id, $0.side) }, uniquingKeysWith: { first, _ in first })
        let timingText = root.attribute(nsItunes, "timing") ?? root.rawAttributes["itunes:timing"]
        let timing: LyricsTiming = switch timingText {
        case "Line": .line
        case "Word": .word
        default: parsed.contains { !$0.words.isEmpty } ? .word : .line
        }
        let lines = parsed.map { line -> SyncedLine in
            var copy = line
            copy.side = line.agent.flatMap { sides[$0] } ?? .start
            return copy
        }
        return SyncedLyrics(lines: lines, timing: timing, agents: agents, language: root.attribute(nsXml, "lang"))
    }

    /// TTML, совместимый с Apple и AMLL.
    public static func write(_ lyrics: SyncedLyrics) -> String {
        // Дуэт без объявленных исполнителей получает v1 (начало) и v2 (конец)
        let agents: [LyricsAgent] = !lyrics.agents.isEmpty ? lyrics.agents
            : lyrics.isDuet ? [LyricsAgent(id: "v1", side: .start), LyricsAgent(id: "v2", side: .end)] : []
        var agentBySide: [VocalSide: String] = [:]
        for agent in agents where agentBySide[agent.side] == nil { agentBySide[agent.side] = agent.id }
        let end = lyrics.lines.map(\.endMs).max() ?? 0
        var out = "<tt xmlns=\"\(nsTtml)\" xmlns:ttm=\"\(nsTtm)\" xmlns:itunes=\"\(nsItunes)\""
        out += " itunes:timing=\"\(lyrics.timing == .word ? "Word" : "Line")\""
        if let language = lyrics.language { out += " xml:lang=\"\(escape(language))\"" }
        out += "><head><metadata>"
        for agent in agents {
            out += "<ttm:agent type=\"person\" xml:id=\"\(escape(agent.id))\""
            if let name = agent.name {
                out += "><ttm:name type=\"full\">\(escape(name))</ttm:name></ttm:agent>"
            } else {
                out += "/>"
            }
        }
        out += "</metadata></head>"
        out += "<body dur=\"\(time(end))\"><div begin=\"\(time(lyrics.lines.first?.startMs ?? 0))\" end=\"\(time(end))\">"
        for line in lyrics.lines {
            out += "<p begin=\"\(time(line.startMs))\" end=\"\(time(line.endMs))\""
            if let agentId = line.agent ?? (agents.isEmpty ? nil : agentBySide[line.side]) { out += " ttm:agent=\"\(escape(agentId))\"" }
            if let language = line.language { out += " xml:lang=\"\(escape(language))\"" }
            out += ">"
            if line.words.isEmpty { out += escape(line.text) } else { appendWords(&out, line.words) }
            if let background = line.background {
                out += "<span ttm:role=\"x-bg\">"
                appendWords(&out, background.words)
                out += "</span>"
            }
            if let translation = line.translation { out += "<span ttm:role=\"x-translation\">\(escape(translation))</span>" }
            if let roman = line.transliteration { out += "<span ttm:role=\"x-roman\">\(escape(roman))</span>" }
            out += "</p>"
        }
        out += "</div></body></tt>"
        return out
    }

    private static func appendWords(_ out: inout String, _ words: [SyncedWord]) {
        for word in words {
            let trimmed = String(word.text.reversed().drop { $0.isWhitespace }.reversed())
            out += "<span begin=\"\(time(word.startMs))\" end=\"\(time(word.endMs))\">\(escape(trimmed))</span>"
            // Пробел между словами — текстовый узел между span, как пишет Apple
            if let last = word.text.last, last.isWhitespace { out += " " }
        }
    }

    private static func parseLine(_ p: XMLTree) -> SyncedLine? {
        var words: [SyncedWord] = []
        var backgroundWords: [SyncedWord] = []
        var backgroundText = ""
        var plain = ""
        var translation: String?
        var transliteration: String?

        func collect(_ parent: XMLTree, into target: inout [SyncedWord], plainText: Bool) {
            for child in parent.children {
                switch child {
                case .text(let value):
                    if !target.isEmpty, !value.isEmpty, value.allSatisfy(\.isWhitespace) {
                        if !target[target.count - 1].text.hasSuffix(" ") { target[target.count - 1].text += " " }
                    } else if plainText {
                        plain += value
                    }
                case .element(let element) where element.local == "span":
                    switch element.attribute(nsTtm, "role") {
                    case "x-bg":
                        collect(element, into: &backgroundWords, plainText: false)
                        if backgroundWords.isEmpty { backgroundText = element.innerText.trimmingCharacters(in: .whitespacesAndNewlines) }
                    case "x-translation":
                        let text = element.innerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        translation = text.isEmpty ? nil : text
                    case "x-roman":
                        let text = element.innerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        transliteration = text.isEmpty ? nil : text
                    default:
                        if let begin = element.attribute(nil, "begin").flatMap(parseTime),
                           let end = element.attribute(nil, "end").flatMap(parseTime) {
                            target.append(SyncedWord(startMs: begin, endMs: end, text: element.innerText))
                        } else {
                            collect(element, into: &target, plainText: plainText)
                        }
                    }
                case .element:
                    break
                }
            }
        }

        collect(p, into: &words, plainText: true)
        guard let start = p.attribute(nil, "begin").flatMap(parseTime) ?? words.first?.startMs,
              let stop = p.attribute(nil, "end").flatMap(parseTime) ?? words.last?.endMs else { return nil }
        let text = (words.isEmpty ? plain : words.map(\.text).joined()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let background: BackingVocals? = if let first = backgroundWords.first, let last = backgroundWords.last {
            BackingVocals(startMs: first.startMs, endMs: last.endMs, words: trimLast(backgroundWords))
        } else if !backgroundText.isEmpty {
            BackingVocals(startMs: start, endMs: stop, words: [SyncedWord(startMs: start, endMs: stop, text: backgroundText)])
        } else {
            nil
        }
        return SyncedLine(startMs: start, endMs: stop, text: text, words: trimLast(words), agent: p.attribute(nsTtm, "agent"),
                          language: p.attribute(nsXml, "lang"), background: background, translation: translation,
                          transliteration: transliteration)
    }

    /// У последнего слова нет пробела в конце.
    private static func trimLast(_ words: [SyncedWord]) -> [SyncedWord] {
        guard var last = words.last else { return words }
        last.text = String(last.text.reversed().drop { $0.isWhitespace }.reversed())
        return words.dropLast() + [last]
    }

    /// Время TTML: часы («1:02:03.450», «02:03.45», «3.5») или смещение («12.3s», «450ms», «2m», «1h»).
    public static func parseTime(_ value: String) -> Int64? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("ms") { return Double(text.dropLast(2)).map { Int64($0) } }
        if text.hasSuffix("s") { return Double(text.dropLast()).map { Int64($0 * 1000) } }
        if text.hasSuffix("m") { return Double(text.dropLast()).map { Int64($0 * 60_000) } }
        if text.hasSuffix("h") { return Double(text.dropLast()).map { Int64($0 * 3_600_000) } }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard let seconds = Double(parts[parts.count - 1]) else { return nil }
        var minutes: Int64 = 0, hours: Int64 = 0
        if parts.count >= 2 { guard let value = Int64(parts[parts.count - 2]) else { return nil }; minutes = value }
        if parts.count >= 3 { guard let value = Int64(parts[parts.count - 3]) else { return nil }; hours = value }
        return (hours * 3600 + minutes * 60) * 1000 + Int64((seconds * 1000).rounded(.toNearestOrAwayFromZero))
    }

    private static func time(_ ms: Int64) -> String {
        let total = max(0, ms)
        let hours = total / 3_600_000, minutes = total / 60_000 % 60, seconds = total / 1000 % 60, millis = total % 1000
        return hours > 0
            ? String(format: "%lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
            : String(format: "%02lld:%02lld.%03lld", minutes, seconds, millis)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Маленькое дерево XML поверх `XMLParser` (на watchOS и iOS нет `XMLDocument`): элементы с пространствами имён,
/// атрибуты и текстовые узлы, включая пробельные.
final class XMLTree {
    enum Node {
        case element(XMLTree)
        case text(String)
    }

    let local: String
    let namespace: String?
    /// Атрибуты как записаны: `qname → значение`.
    let rawAttributes: [String: String]
    /// Атрибуты с разрешёнными пространствами: `(uri, local) → значение`.
    private var resolved: [String: String] = [:]
    var children: [Node] = []

    init(local: String, namespace: String?, rawAttributes: [String: String]) {
        self.local = local
        self.namespace = namespace
        self.rawAttributes = rawAttributes
    }

    func attribute(_ namespace: String?, _ name: String) -> String? {
        let value = resolved[(namespace ?? "") + "|" + name]
        return value?.isEmpty == false ? value : nil
    }

    var innerText: String {
        children.map { node in
            switch node {
            case .text(let text): text
            case .element(let element): element.innerText
            }
        }.joined()
    }

    /// Все элементы ниже этого, в порядке документа.
    var descendants: [XMLTree] {
        children.flatMap { node -> [XMLTree] in
            if case .element(let element) = node { return [element] + element.descendants }
            return []
        }
    }

    static func parse(_ text: String) -> XMLTree? {
        guard let data = text.data(using: .utf8) else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), builder.failed == false else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var failed = false
        private var stack: [XMLTree] = []
        private var scopes: [[String: String]] = [["xml": TtmlFormat.nsXml]]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            var scope = scopes.last ?? [:]
            for (key, value) in attributes {
                if key == "xmlns" { scope[""] = value } else if key.hasPrefix("xmlns:") { scope[String(key.dropFirst(6))] = value }
            }
            scopes.append(scope)
            let (prefix, local) = Self.split(elementName)
            let element = XMLTree(local: local, namespace: scope[prefix ?? ""], rawAttributes: attributes)
            for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
                let (attributePrefix, attributeLocal) = Self.split(key)
                // Атрибут без префикса не принадлежит пространству элемента (как в DOM).
                let uri = attributePrefix.map { scope[$0] ?? "" } ?? ""
                element.resolved[uri + "|" + attributeLocal] = value
            }
            if let parent = stack.last {
                parent.children.append(.element(element))
            } else if root == nil {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
            _ = scopes.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string)
        }

        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
            append(whitespaceString)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            failed = true
        }

        private func append(_ text: String) {
            guard let current = stack.last else { return }
            // Соседние куски текста — один узел, как в DOM.
            if case .text(let previous)? = current.children.last {
                current.children[current.children.count - 1] = .text(previous + text)
            } else {
                current.children.append(.text(text))
            }
        }

        private static func split(_ name: String) -> (prefix: String?, local: String) {
            guard let colon = name.firstIndex(of: ":") else { return (nil, name) }
            return (String(name[..<colon]), String(name[name.index(after: colon)...]))
        }
    }
}
