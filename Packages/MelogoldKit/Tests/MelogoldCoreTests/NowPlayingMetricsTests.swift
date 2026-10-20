import Foundation
import Testing
@testable import MelogoldCore

/// Размеры «Сейчас играет» — те же числа, что у Linux и Windows (задания 0030 §3 и 0033 §4); сценарии — их тесты
/// `now_playing::tests` и `BackdropTests.The_wide_layout_is_one_block_in_the_middle_with_a_bigger_cover`.
@Suite("Размеры «Сейчас играет»")
struct NowPlayingMetricsTests {
    @Test func lyricsSizeFollowsTheHeightOfTheWholeArea() {
        #expect(NowPlayingMetrics.lyricsSize(areaHeight: 300) == 18)
        #expect(NowPlayingMetrics.lyricsSize(areaHeight: 800) == 34)
        #expect(NowPlayingMetrics.lyricsSize(areaHeight: 1092) == 46)
        #expect(NowPlayingMetrics.lyricsSize(areaHeight: 3000) == 64)
        // От ширины размер не зависит вовсе: одна высота — один размер в любой раскладке
        #expect(NowPlayingMetrics.lyricsSize(areaHeight: 900) > NowPlayingMetrics.lyricsSize(areaHeight: 700))
    }

    @Test func lyricsColumnIsAbout28Characters() {
        #expect(abs(NowPlayingMetrics.lyricsColumnWidth(lineSize: 28) - (28 * 0.55 * 28 + 32)) < 0.001)
        #expect(abs(NowPlayingMetrics.lyricsColumnWidth(lineSize: 46) - 760.97) < 0.01)
    }

    /// Снимок Максима с Linux 20.10.2026: страница 2000 × 1092, под заголовком 1045, под обложкой 250.
    @Test func wideLayoutIsOneBlockInTheMiddle() {
        let size = NowPlayingMetrics.lyricsSize(areaHeight: 1092)
        let layout = NowPlayingMetrics.wideLayout(width: 2000, height: 1045, below: 250, columnMin: 310, lineSize: size)
        #expect(layout.cover == 690, "0,66 · h — крупнее прежних 546")
        #expect(layout.column == 690)
        #expect(layout.lyrics == NowPlayingMetrics.lyricsColumnWidth(lineSize: size).rounded())
        #expect((200...300).contains(layout.edge), "поля по краям поровну: \(layout.edge)")
        #expect(abs(2 * layout.edge + layout.column + NowPlayingMetrics.wideGap + layout.lyrics - 2000) <= 1)
    }

    /// Windows 1920 × 1080: между строкой заголовка и панелью 889, обложка 587 (было 469), поля около 300.
    @Test func windowsFullHDMatches() {
        let size = NowPlayingMetrics.lyricsSize(areaHeight: 937)
        let layout = NowPlayingMetrics.wideLayout(width: 1920, height: 889, below: 150, columnMin: 310, lineSize: size)
        #expect(layout.cover == 587)
        #expect((250...350).contains(layout.edge))
    }

    @Test func coverLeavesRoomForTheControlsAndTheLyrics() {
        // Низкое окно: под обложкой остаются название и кнопки
        #expect(NowPlayingMetrics.wideLayout(width: 1600, height: 500, below: 250, columnMin: 310, lineSize: 24).cover == 250)
        // Узкое широкое окно: текст не уже 240, поля не меньше 48
        let narrow = NowPlayingMetrics.wideLayout(width: 900, height: 900, below: 250, columnMin: 310, lineSize: 40)
        #expect(narrow.lyrics >= 240)
        #expect(narrow.column + NowPlayingMetrics.wideGap + narrow.lyrics <= 900 - 2 * NowPlayingMetrics.wideEdge)
        #expect(narrow.edge >= NowPlayingMetrics.wideEdge)
        // Под обложкой ошибка с кнопками: обложка меньше, колонка — по кнопкам, текст рядом с ней
        let error = NowPlayingMetrics.wideLayout(width: 960, height: 593, below: 420, columnMin: 310, lineSize: 27)
        #expect(error.cover == 173)
        #expect(error.column == 310)
        #expect(error.column + NowPlayingMetrics.wideGap + error.lyrics <= 960 - 2 * NowPlayingMetrics.wideEdge)
    }

    /// Совсем узко для текста: обложка уступает — но не растёт выше того, что оставляет управление.
    @Test func coverGivesWayButNeverGrows() {
        let layout = NowPlayingMetrics.wideLayout(width: 600, height: 600, below: 150, columnMin: 200, lineSize: 30)
        #expect(layout.cover == 192)
        #expect(layout.column == 200)
        #expect(layout.lyrics == 232)
        let low = NowPlayingMetrics.wideLayout(width: 600, height: 300, below: 150, columnMin: 400, lineSize: 18)
        #expect(low.cover <= 150)
    }

    /// iPhone боком: обложка маленькая, колонка — по кнопкам, текст забирает остаток; совсем низко — обложки нет.
    @Test func phoneInLandscape() {
        let layout = NowPlayingMetrics.wideLayout(width: 750, height: 350, below: 210, columnMin: 320, lineSize: 18)
        #expect(layout.cover == 140)
        #expect(layout.column == 320)
        #expect(layout.lyrics == 262)
        #expect(layout.edge == 48)
        let tooLow = NowPlayingMetrics.wideLayout(width: 1280, height: 300, below: 250, columnMin: 320, lineSize: 18)
        #expect(tooLow.cover == 0)
        #expect(tooLow.column == 320)
    }
}
