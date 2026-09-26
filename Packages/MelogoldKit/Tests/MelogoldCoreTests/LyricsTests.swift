import Foundation
import Testing
@testable import MelogoldCore

/// Общие векторы текстов (`spec/lyrics.vectors.json`): те же случаи у Android и Windows.
@Suite("Тексты — векторы")
struct LyricsVectorTests {
    struct Vectors: Decodable { let cases: [Case] }

    struct Case: Decodable, CustomTestStringConvertible {
        let id: String
        let input: String
        let expected: Expected?
        var testDescription: String { id }
    }

    struct Expected: Decodable {
        let timing: String
        let language: String?
        let agents: [Agent]
        let lines: [Line]
    }

    struct Agent: Decodable, Equatable {
        let id: String
        let side: String
        let name: String?
    }

    struct Background: Decodable {
        let startMs: Int64
        let endMs: Int64
        let words: [Word]
    }

    struct Line: Decodable {
        let startMs: Int64
        let endMs: Int64
        let text: String
        let words: [Word]
        let side: String
        let agent: String?
        let language: String?
        let background: Background?
        let translation: String?
        let transliteration: String?
    }

    /// `[startMs, endMs, text]`.
    struct Word: Decodable, Equatable {
        let startMs: Int64
        let endMs: Int64
        let text: String

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            startMs = try container.decode(Int64.self)
            endMs = try container.decode(Int64.self)
            text = try container.decode(String.self)
        }

        init(_ word: SyncedWord) {
            startMs = word.startMs
            endMs = word.endMs
            text = word.text
        }
    }

    static let cases: [Case] = (try? SpecFiles.decode(Vectors.self, from: "lyrics.vectors.json").cases) ?? []

    @Test func loaded() { #expect(Self.cases.count >= 10) }

    @Test(arguments: cases)
    func vector(_ vector: Case) {
        let parsed = LyricsFormats.parseSynced(vector.input)
        guard let expected = vector.expected else {
            #expect(parsed == nil, "\(vector.id): ждали отсутствие синхронного текста")
            return
        }
        guard let parsed else {
            Issue.record("\(vector.id): не разобрался")
            return
        }
        #expect(parsed.timing.rawValue == expected.timing)
        #expect(parsed.language == expected.language)
        #expect(parsed.agents.map { Agent(id: $0.id, side: $0.side.rawValue, name: $0.name) } == expected.agents)
        #expect(parsed.lines.count == expected.lines.count)
        for (line, want) in zip(parsed.lines, expected.lines) {
            #expect(line.startMs == want.startMs, "\(vector.id): начало «\(want.text)»")
            #expect(line.endMs == want.endMs, "\(vector.id): конец «\(want.text)»")
            #expect(line.text == want.text)
            #expect(line.words.map(Word.init) == want.words, "\(vector.id): слова «\(want.text)»")
            #expect(line.side.rawValue == want.side)
            #expect(line.agent == want.agent)
            #expect(line.language == want.language)
            #expect(line.translation == want.translation)
            #expect(line.transliteration == want.transliteration)
            #expect(line.background?.startMs == want.background?.startMs)
            #expect(line.background?.endMs == want.background?.endMs)
            #expect((line.background?.words ?? []).map(Word.init) == (want.background?.words ?? []))
        }
    }

    @Test func lrcRoundTrip() throws {
        let lyrics = try #require(LrcFormat.parse("[00:01.00]M: <00:01.00>Hello <00:01.50>world<00:02.25>\n[00:05.00]F: Bye\n[00:07.00]\n"))
        let again = try #require(LrcFormat.parse(LrcFormat.write(lyrics)))
        #expect(again.lines.map(\.text) == lyrics.lines.map(\.text))
        #expect(again.lines.map(\.startMs) == [1000, 5000])
        #expect(again.lines[0].words.last?.endMs == 2250)
        #expect(again.lines[1].side == .end)
    }

    @Test func dtdIsRefused() {
        let evil = "<?xml version=\"1.0\"?><!DOCTYPE tt [<!ENTITY x \"boom\">]><tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"1s\" end=\"2s\">&x;</p></div></body></tt>"
        #expect(TtmlFormat.parse(evil) == nil)
    }

    @Test func rowsHaveInterludes() throws {
        let lyrics = try #require(LrcFormat.parse("[00:05.00]One\n[00:06.00]♪\n[00:12.00]Two\n[00:13.00]\n"))
        let rows = LyricRows.build(lyrics)
        #expect(rows.count == 4)
        if case .interlude(let start, let end, _) = rows[0] { #expect(start == 0 && end == 5000) } else { Issue.record("нет проигрыша в начале") }
        if case .interlude(let start, let end, _) = rows[2] { #expect(start == 6000 && end == 12000) } else { Issue.record("нет проигрыша") }
        #expect(LyricRows.activeIndex(rows, at: 12_500) == 3)
        #expect(LyricRows.activeIndex(rows, at: -1) == -1)
    }
}

/// Очистка названий YouTube (`spec/title-cleaner.vectors.json`).
@Suite("Очистка названий — векторы")
struct TitleCleanerTests {
    struct Vectors: Decodable { let cases: [Case] }

    struct Case: Decodable, CustomTestStringConvertible {
        struct Input: Decodable {
            let title: String
            let channel: String?
            let videoType: String?
        }

        struct Output: Decodable {
            let artist: String?
            let title: String
        }

        let id: String
        let input: Input
        let expected: Output
        var testDescription: String { id }
    }

    static let cases: [Case] = (try? SpecFiles.decode(Vectors.self, from: "title-cleaner.vectors.json").cases) ?? []

    @Test func loaded() { #expect(Self.cases.count >= 40) }

    @Test(arguments: cases)
    func vector(_ vector: Case) {
        let clean = TitleCleaner.clean(title: vector.input.title, channel: vector.input.channel, videoType: vector.input.videoType)
        #expect(clean.title == vector.expected.title, "\(vector.id): название")
        #expect(clean.artist == vector.expected.artist, "\(vector.id): исполнитель")
    }
}

/// Редактор текста (`spec/lyrics.md`, «Редактор»): те же случаи, что Android `LyricsDraftTest` и Windows.
@Suite("Редактор текста")
struct LyricsDraftTests {
    @Test func textBecomesLinesWithBacking() {
        let draft = LyricsDraft.fromText("First line\n\n  Second line (ooh, ooh)  \nThird (not) backing here\n")
        #expect(draft.lines.map(\.text) == ["First line", "Second line", "Third (not) backing here"])
        #expect(draft.lines[1].backing == "(ooh, ooh)")
        #expect(draft.lines[2].backing == nil)
        #expect(draft.toText() == "First line\nSecond line (ooh, ooh)\nThird (not) backing here")
    }

    @Test func marksLinesInOrder() throws {
        let draft = LyricsDraft.fromText("One\nTwo\nThree").mark(1_000).mark(4_000).mark(8_000)
        #expect(draft.cursor == 3)
        #expect(draft.complete)
        let lyrics = try #require(draft.toSyncedLyrics())
        #expect(lyrics.timing == .line)
        #expect(lyrics.lines.map(\.startMs) == [1_000, 4_000, 8_000])
        #expect(lyrics.lines.map(\.endMs) == [4_000, 8_000, 13_000])
    }

    @Test func explicitEndLeavesGap() throws {
        let lyrics = try #require(LyricsDraft.fromText("One\nTwo").mark(1_000).markEnd(3_000).mark(9_000).toSyncedLyrics())
        #expect(lyrics.lines[0].startMs == 1_000 && lyrics.lines[0].endMs == 3_000)
        #expect(lyrics.lines[1].startMs == 9_000)
    }

    @Test func remarkingEarlierKeepsOnlyRealGaps() throws {
        let draft = LyricsDraft.fromText("One\nTwo").mark(1_000).markEnd(3_000).mark(2_000)
        #expect(draft.lines[0].endMs == nil)
        let line = try #require(draft.toSyncedLyrics()).lines[0]
        #expect(line.startMs == 1_000 && line.endMs == 2_000)
    }

    @Test func wordMode() throws {
        let draft = LyricsDraft.fromText("a b c\nd", language: "en").withTiming(.word).mark(100).mark(200).mark(300)
        #expect(draft.cursor == 1)
        #expect(draft.wordCursor == 0)
        let lyrics = try #require(draft.mark(1_000).toSyncedLyrics())
        #expect(lyrics.timing == .word)
        #expect(lyrics.language == "en")
        #expect(lyrics.lines[0].words == [SyncedWord(startMs: 100, endMs: 200, text: "a "), SyncedWord(startMs: 200, endMs: 300, text: "b "),
                                          SyncedWord(startMs: 300, endMs: 1_000, text: "c")])
    }

    @Test func partlyTimedWordsFallBackToLines() throws {
        let lyrics = try #require(LyricsDraft.fromText("a b\nc").withTiming(.word).mark(100).moved(to: 1).mark(2_000).toSyncedLyrics())
        #expect(lyrics.timing == .line)
        #expect(lyrics.lines.allSatisfy { $0.words.isEmpty })
    }

    @Test func endSideMakesDuet() throws {
        let lyrics = try #require(LyricsDraft.fromText("One\nTwo").mark(0).mark(2_000).withSide(1, .end).toSyncedLyrics())
        #expect(lyrics.agents.map(\.id) == ["v1", "v2"])
        #expect(lyrics.lines.map(\.agent) == ["v1", "v2"])
        #expect(lyrics.isDuet)
    }

    @Test func editingKeepsUnchangedTiming() {
        let draft = LyricsDraft.fromText("One\nTwo\nThree").mark(1_000).mark(2_000).mark(3_000).withText("One\nNew line\nTwo\nThree (yeah)")
        #expect(draft.lines.map(\.startMs) == [1_000, nil, 2_000, nil])
        #expect(draft.lines[3].backing == "(yeah)")
        #expect(draft.cursor == 1)
    }

    @Test func nudgeMovesLineAndWords() {
        let draft = LyricsDraft.fromText("a b").withTiming(.word).mark(1_000).mark(1_500).nudge(0, by: -100)
        #expect(draft.lines[0].startMs == 900)
        #expect(draft.lines[0].wordStarts == [900, 1_400])
        #expect(draft.nudge(0, by: -5_000).lines[0].startMs == 0)
    }

    @Test func startOffsetShiftsEverything() {
        let draft = LyricsDraft.fromText("a b\nc").withTiming(.word).mark(0).mark(500).mark(2_000).shifted(by: 1_500)
        #expect(draft.lines.map(\.startMs) == [1_500, 3_500])
        #expect(draft.lines[0].wordStarts == [1_500, 2_000])
    }

    @Test func roundTripThroughTtml() throws {
        var start = LyricsDraft.fromText("Hello there\nGeneral Kenobi (you are a bold one)").withTiming(.word)
        start.language = "en"
        let lyrics = try #require(start.mark(1_000).mark(1_600).mark(3_000).mark(3_700).withSide(1, .end).toSyncedLyrics())
        let parsed = try #require(TtmlFormat.parse(TtmlFormat.write(lyrics)))
        #expect(parsed.lines.map(\.text) == lyrics.lines.map(\.text))
        #expect(parsed.lines.flatMap(\.words) == lyrics.lines.flatMap(\.words))
        #expect(parsed.lines[1].background?.text == "(you are a bold one)")
        #expect(parsed.lines[1].side == .end)
        let again = LyricsDraft.from(parsed)
        #expect(again.lines.map(\.startMs) == [1_000, 3_000])
        #expect(again.lines[1].wordStarts == [3_000, 3_700])
        #expect(again.lines[1].backing == "(you are a bold one)")
        #expect(again.cursor == 2)
    }

    @Test func equalDraftsCompareEqual() {
        let a = LyricsDraft.fromText("One\nTwo").mark(100)
        let b = LyricsDraft.fromText("One\nTwo").mark(100)
        #expect(a == b)
        #expect(a != a.mark(200))
    }
}
