import Foundation
import Testing
@testable import MelogoldCore

/// Тексты через сервер (задание 0001 §4): разница со снимком, надгробие поверх неизменённого и изменённого текста.
@Suite("Правила синхронизации текстов")
struct LyricsSyncRulesTests {
    static let lrc = "[00:12.30]Я вернусь\n[00:15.80]Когда растает снег"
    static let ttml = #"<?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml"><body><p begin="1s">A</p></body></tt>"#

    let own = StoredLyrics(synced: lrc, plain: "Я вернусь", syncedSource: LyricsSources.user, plainSource: LyricsSources.lrclib, offsetMs: -300, language: "ru")

    @Test func payloadKeepsBothSidesWithTheirSources() {
        let payload = LyricsSyncRules.payload(own)
        #expect(payload.synced == Self.lrc)
        #expect(payload.syncedFormat == "lrc")
        #expect(payload.syncedSource == "user")
        #expect(payload.plainSource == "lrclib")
        // Сдвиг «раньше» — где в треке начинается текст
        #expect(payload.startTimeMs == 300)
        #expect(LyricsSyncRules.payload(StoredLyrics(synced: Self.ttml, plain: nil, syncedSource: "file", plainSource: nil)).syncedFormat == "ttml")
        // Не LRC и не TTML — синхронной стороны нет
        #expect(LyricsSyncRules.payload(StoredLyrics(synced: "просто текст", plain: nil, syncedSource: "user", plainSource: nil)).synced == nil)
        // Общий текст сообщества уходит без источника
        #expect(LyricsSyncRules.payload(StoredLyrics(synced: nil, plain: "x", syncedSource: nil, plainSource: "melogold")).plainSource == nil)
    }

    @Test func ownIsUserOrFileWithText() {
        #expect(LyricsSyncRules.isOwn(own))
        #expect(!LyricsSyncRules.isOwn(StoredLyrics(synced: Self.lrc, plain: nil, syncedSource: "lrclib", plainSource: nil)))
        #expect(!LyricsSyncRules.isOwn(StoredLyrics(synced: "", plain: nil, syncedSource: "user", plainSource: nil)))
    }

    @Test func sendsNewChangedAndRemoved() {
        let hash = LyricsSyncRules.hash(LyricsSyncRules.payload(own))
        #expect(hash.count == 64)
        // Новый — PUT
        #expect(LyricsSyncRules.planSends(own: ["v1": own], snapshot: [:]) == [.put(videoId: "v1", payload: LyricsSyncRules.payload(own), hash: hash)])
        // Не менялся — ничего
        #expect(LyricsSyncRules.planSends(own: ["v1": own], snapshot: ["v1": LyricsSnapshot(rev: 3, hash: hash)]).isEmpty)
        // Изменился — PUT
        var edited = own
        edited.plain = "Я вернусь!"
        #expect(LyricsSyncRules.planSends(own: ["v1": edited], snapshot: ["v1": LyricsSnapshot(rev: 3, hash: hash)]).count == 1)
        // Своего больше нет — DELETE, отвергнутого — просто забыть
        #expect(LyricsSyncRules.planSends(own: [:], snapshot: ["v1": LyricsSnapshot(rev: 3, hash: hash), "v2": LyricsSnapshot(rev: -1, hash: "x")])
            == [.delete(videoId: "v1"), .forget(videoId: "v2")])
    }

    @Test func tombstoneDeletesOnlyUnchangedText() {
        let snapshot = LyricsSnapshot(rev: 3, hash: LyricsSyncRules.hash(LyricsSyncRules.payload(own)))
        #expect(LyricsSyncRules.deleteOnTombstone(own, snapshot))
        var edited = own
        edited.synced = Self.lrc + "\n[00:20.00]Новая строка"
        #expect(!LyricsSyncRules.deleteOnTombstone(edited, snapshot))
        #expect(!LyricsSyncRules.deleteOnTombstone(own, nil))
        #expect(!LyricsSyncRules.deleteOnTombstone(nil, snapshot))
    }

    @Test func serverVersionRoundTrips() {
        let payload = LyricsSyncRules.payload(own)
        let stored = LyricsSyncRules.stored(payload)
        #expect(stored.offsetMs == -300)
        #expect(LyricsSyncRules.sameContent(own, stored))
        #expect(LyricsSyncRules.hash(LyricsSyncRules.payload(stored)) == LyricsSyncRules.hash(payload))
    }

    @Test func tooLargeByUtf16() {
        let big = LyricsPayload(plain: String(repeating: "я", count: LyricsSyncRules.plainMax + 1), plainSource: "user", synced: nil,
                                syncedFormat: nil, syncedSource: nil, startTimeMs: nil, language: nil)
        #expect(LyricsSyncRules.tooLarge(big))
        #expect(!LyricsSyncRules.tooLarge(LyricsSyncRules.payload(own)))
    }
}
