import Foundation
import Testing
@testable import MelogoldCore

/// Правила записи текстов трека (audit 4.2): что поиск, выбор, «Искать заново» и сдвиг делают со строкой, какой она
/// лежит сейчас.
@Suite("Правила записи текстов")
struct LyricsRulesTests {
    static let lrc = "[00:01.00]Один\n[00:02.00]Два"
    static let other = "[00:05.00]Чужой текст"

    let typed = StoredLyrics(synced: lrc, plain: "Один\nДва", syncedSource: LyricsSources.user, plainSource: LyricsSources.user, offsetMs: -200)

    // MARK: - Поиск в полёте

    @Test func foundTextFillsWhatNobodyTouched() {
        let found = FoundLyrics(synced: Self.lrc, plain: "Один", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.youtubeMusic)
        let merged = LyricsRules.mergeFetched(baseline: nil, current: nil, found: found)
        #expect(merged == StoredLyrics(synced: Self.lrc, plain: "Один", syncedSource: "lrclib", plainSource: "youtube_music"))
    }

    @Test func searchInFlightDoesNotOverwriteImportedOrTypedText() {
        // Поиск начался с пустой строки; за это время пользователь импортировал файл
        let imported = StoredLyrics(synced: Self.other, plain: nil, syncedSource: LyricsSources.file, plainSource: nil)
        let found = FoundLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib)
        let merged = LyricsRules.mergeFetched(baseline: nil, current: imported, found: found)
        // Синхронная сторона осталась своей, обычная, которой не было, — заполнена найденной
        #expect(merged?.synced == Self.other)
        #expect(merged?.syncedSource == "file")
        #expect(merged?.plain == "Найденный")
        // Своё целиком: найденное ничего не меняет
        let full = LyricsRules.mergeFetched(baseline: nil, current: typed, found: found)
        #expect(full == typed)
    }

    @Test func searchInFlightDoesNotOverwriteChosenText() {
        let chosen = StoredLyrics(synced: Self.other, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil, chosen: true)
        let found = FoundLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.kugou, plainSource: LyricsSources.lrclib)
        let merged = LyricsRules.mergeFetched(baseline: nil, current: chosen, found: found)
        #expect(merged == chosen)
    }

    /// Поиск ищет только недостающие стороны, но и когда он вернул другой текст для стороны, которая уже своя или
    /// выбрана, — она остаётся.
    @Test func ownAndChosenSidesAreNeverReplacedBySearch() {
        let found = FoundLyrics(synced: Self.other, plain: "Чужой", syncedSource: LyricsSources.kugou, plainSource: LyricsSources.kugou)
        #expect(LyricsRules.mergeFetched(baseline: typed, current: typed, found: found) == typed)
        let chosen = StoredLyrics(synced: Self.lrc, plain: "Выбранный", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib, chosen: true)
        #expect(LyricsRules.mergeFetched(baseline: chosen, current: chosen, found: found) == chosen)
        // А найденное автоматически заменяется: искать заново его обновляет
        let auto = StoredLyrics(synced: Self.lrc, plain: "Старый", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib)
        #expect(LyricsRules.mergeFetched(baseline: auto, current: auto, found: found)?.synced == Self.other)
    }

    @Test func searchInFlightKeepsTextThatSyncBroughtMeanwhile() {
        // Синк принёс версию с другого устройства, пока шёл поиск
        let pulled = StoredLyrics(synced: Self.other, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil, chosen: true)
        let found = FoundLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.youtubeMusic)
        #expect(LyricsRules.mergeFetched(baseline: nil, current: pulled, found: found) == pulled)
    }

    @Test func sidesTheSearchDidNotTouchAreLeftAsTheyAre() {
        // Поиск вернул сторону как есть (она уже была) — если её за это время поменяли, остаётся новое
        let baseline = StoredLyrics(synced: nil, plain: "Старый", syncedSource: nil, plainSource: LyricsSources.lrclib)
        let edited = StoredLyrics(synced: nil, plain: "Мой", syncedSource: nil, plainSource: LyricsSources.user)
        let found = FoundLyrics(synced: Self.lrc, plain: "Старый", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib)
        let merged = LyricsRules.mergeFetched(baseline: baseline, current: edited, found: found)
        #expect(merged?.plain == "Мой")
        #expect(merged?.plainSource == "user")
        #expect(merged?.synced == Self.lrc)
    }

    @Test func nothingFoundBecauseOfNetworkWritesNothing() {
        #expect(LyricsRules.mergeFetched(baseline: nil, current: nil, found: FoundLyrics(synced: nil, plain: nil)) == nil)
        #expect(LyricsRules.mergeFetched(baseline: nil, current: typed, found: FoundLyrics(synced: nil, plain: nil)) == typed)
    }

    @Test func searchedAndNotFoundIsRememberedAsEmptySides() {
        let merged = LyricsRules.mergeFetched(baseline: nil, current: nil, found: FoundLyrics(synced: "", plain: ""))
        #expect(merged == StoredLyrics(synced: "", plain: "", syncedSource: nil, plainSource: nil))
    }

    @Test func offsetAndLanguageOfFoundTextDoNotOverrideUserShift() {
        let baseline = StoredLyrics(synced: nil, plain: "x", syncedSource: nil, plainSource: LyricsSources.lrclib, offsetMs: 0)
        let shifted = StoredLyrics(synced: nil, plain: "x", syncedSource: nil, plainSource: LyricsSources.lrclib, offsetMs: 300)
        let found = FoundLyrics(synced: Self.lrc, plain: "x", syncedSource: LyricsSources.melogold, offsetMs: -500, language: "ru")
        let merged = LyricsRules.mergeFetched(baseline: baseline, current: shifted, found: found)
        #expect(merged?.offsetMs == 300)
        #expect(merged?.language == "ru")
        let untouched = LyricsRules.mergeFetched(baseline: baseline, current: baseline, found: found)
        #expect(untouched?.offsetMs == -500)
    }

    @Test func textFromOwnServerVersionBecomesChosen() {
        let found = FoundLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, chosen: true)
        let merged = LyricsRules.mergeFetched(baseline: nil, current: nil, found: found)
        #expect(merged?.chosen == true)
        #expect(merged?.isOwn == true)
        // Общий текст сообщества своим не становится
        let community = FoundLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.melogold)
        #expect(LyricsRules.mergeFetched(baseline: nil, current: nil, found: community)?.isOwn == false)
    }

    // MARK: - «Искать заново»

    @Test func searchAgainKeepsOwnAndForgetsFound() {
        let found = StoredLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.youtubeMusic, offsetMs: 100)
        #expect(LyricsRules.forgetFound(found) == nil)
        #expect(LyricsRules.forgetFound(nil) == nil)
        // Свой текст остаётся целиком
        #expect(LyricsRules.forgetFound(typed) == typed)
        // Выбранный — тоже
        let chosen = StoredLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil, chosen: true)
        #expect(LyricsRules.forgetFound(chosen) == chosen)
        // Смешанная строка: своя обычная сторона остаётся, найденная синхронная забывается вместе со сдвигом
        let mixed = StoredLyrics(synced: Self.lrc, plain: "Мой", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.user, offsetMs: 100, language: "ru")
        let rest = LyricsRules.forgetFound(mixed)
        #expect(rest == StoredLyrics(synced: nil, plain: "Мой", syncedSource: nil, plainSource: "user", offsetMs: 0, language: "ru"))
        // Пустая сторона с источником `user` своей не считается
        #expect(LyricsRules.forgetFound(StoredLyrics(synced: "", plain: "x", syncedSource: "user", plainSource: "lrclib")) == nil)
    }

    // MARK: - Свой и выбранный текст

    @Test func saveOwnKeepsTheOtherSideAndTheChosenFlag() {
        let current = StoredLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.lrclib,
                                   offsetMs: 400, language: "ru", chosen: true)
        // Импорт обычного текста: синхронная сторона, сдвиг и флаг остаются
        let plainOnly = LyricsRules.saveOwn(current: current, synced: nil, plain: "Из файла", source: LyricsSources.file, language: nil)
        #expect(plainOnly.plain == "Из файла")
        #expect(plainOnly.plainSource == "file")
        #expect(plainOnly.synced == Self.lrc)
        #expect(plainOnly.syncedSource == "lrclib")
        #expect(plainOnly.offsetMs == 400)
        #expect(plainOnly.chosen)
        // Новый синхронный текст сбрасывает сдвиг
        let both = LyricsRules.saveOwn(current: current, synced: Self.other, plain: "Свой", source: LyricsSources.user, language: "en")
        #expect(both.syncedSource == "user")
        #expect(both.offsetMs == 0)
        #expect(both.language == "en")
        // Первая запись в пустую строку
        let first = LyricsRules.saveOwn(current: nil, synced: nil, plain: "Свой", source: LyricsSources.user, language: nil)
        #expect(first == StoredLyrics(synced: nil, plain: "Свой", syncedSource: nil, plainSource: "user"))
    }

    @Test func chooseReplacesBothSidesAndMarksChosen() {
        let auto = StoredLyrics(synced: Self.lrc, plain: "Найденный", syncedSource: LyricsSources.youtubeMusic, plainSource: LyricsSources.youtubeMusic)
        let chosen = LyricsRules.choose(current: auto, synced: nil, plain: "Обычный из LRCLIB", source: LyricsSources.lrclib, replacingTyped: false)
        #expect(chosen == StoredLyrics(synced: "", plain: "Обычный из LRCLIB", syncedSource: nil, plainSource: "lrclib", chosen: true))
        #expect(chosen?.isOwn == true)
        // Пробельные стороны — «нет»
        let blank = LyricsRules.choose(current: nil, synced: "  \n", plain: "x", source: LyricsSources.lrclib, replacingTyped: false)
        #expect(blank?.synced == "")
        #expect(blank?.syncedSource == nil)
    }

    @Test func chooseDoesNotReplaceTypedTextSilently() {
        #expect(LyricsRules.choose(current: typed, synced: Self.other, plain: nil, source: LyricsSources.lrclib, replacingTyped: false) == nil)
        let mixed = StoredLyrics(synced: Self.lrc, plain: "Мой", syncedSource: LyricsSources.lrclib, plainSource: LyricsSources.file)
        #expect(LyricsRules.choose(current: mixed, synced: Self.other, plain: nil, source: LyricsSources.lrclib, replacingTyped: false) == nil)
        // С подтверждением — заменяется
        #expect(LyricsRules.choose(current: typed, synced: Self.other, plain: nil, source: LyricsSources.lrclib, replacingTyped: true)?.synced == Self.other)
        // Найденный и ранее выбранный текст заменяются без вопросов
        let chosen = StoredLyrics(synced: Self.lrc, plain: "", syncedSource: LyricsSources.lrclib, plainSource: nil, chosen: true)
        #expect(LyricsRules.choose(current: chosen, synced: Self.other, plain: nil, source: LyricsSources.lrclib, replacingTyped: false)?.synced == Self.other)
    }

    @Test func shiftAddsToWhatIsStoredAndResets() {
        #expect(LyricsRules.shifted(nil, by: 100) == nil)
        #expect(LyricsRules.shifted(typed, by: -100)?.offsetMs == -300)
        #expect(LyricsRules.shifted(typed, by: nil)?.offsetMs == 0)
    }
}
