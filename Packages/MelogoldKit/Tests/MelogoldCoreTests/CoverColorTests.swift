import Foundation
import Testing
@testable import MelogoldCore

/// Цвет фона «Сейчас играет» по обложке (docs/PROMPT.md §5.1).
@Suite("Доминирующий цвет обложки")
struct CoverColorTests {
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        pixels.flatMap { [$0.0, $0.1, $0.2, 255] }
    }

    private func repeated(_ color: (UInt8, UInt8, UInt8), _ count: Int) -> [(UInt8, UInt8, UInt8)] {
        Array(repeating: color, count: count)
    }

    private func hue(_ color: CoverRGB) -> Double { CoverColor.hsv(color.red, color.green, color.blue).hue }

    @Test func solidRedStaysRed() throws {
        let color = try #require(CoverColor.dominant(rgba: image(repeated((220, 30, 40), 100))))
        #expect(color.red > color.green + 0.2)
        #expect(color.red > color.blue + 0.2)
    }

    @Test func majorityHueWinsOverAverage() throws {
        // 70 % синего и 30 % красного: среднее было бы лиловым, доминирует синий
        let pixels = repeated((30, 60, 220), 70) + repeated((220, 40, 40), 30)
        let color = try #require(CoverColor.dominant(rgba: image(pixels)))
        #expect((200...260).contains(hue(color)))
    }

    @Test func blackFrameDoesNotDragColorToGrey() throws {
        // обложка «Группа крови»: бежевая середина в чёрной рамке
        let pixels = repeated((0, 0, 0), 45) + repeated((214, 170, 120), 55)
        let color = try #require(CoverColor.dominant(rgba: image(pixels)))
        let (h, s, _) = CoverColor.hsv(color.red, color.green, color.blue)
        #expect((15...45).contains(h))
        #expect(s >= 0.25)
    }

    @Test func achromaticCoverHasNoTint() {
        let grey = image(repeated((128, 128, 128), 60) + repeated((240, 240, 240), 20) + repeated((10, 10, 10), 20))
        #expect(CoverColor.dominant(rgba: grey) == nil)
    }

    @Test func redAroundZeroDegreesIsOneColor() throws {
        // красный по обе стороны от 0° не дробится границей секторов: розоватый и оранжеватый красный вместе побеждают зелёный
        let pixels = repeated((230, 30, 60), 30) + repeated((230, 60, 20), 30) + repeated((30, 200, 60), 40)
        let color = try #require(CoverColor.dominant(rgba: image(pixels)))
        #expect(color.red > color.green)
    }

    @Test func fewColoredPixelsAreIgnored() {
        // 3 % цветных пикселей на сером — обложка бесцветная
        let pixels = repeated((120, 120, 120), 97) + repeated((220, 30, 40), 3)
        #expect(CoverColor.dominant(rgba: image(pixels)) == nil)
    }

    @Test func transparentPixelsDoNotVote() {
        var data = image(repeated((220, 30, 40), 50))
        for index in 0..<50 { data[index * 4 + 3] = 0 }
        #expect(CoverColor.dominant(rgba: data) == nil)
    }

    @Test func colorIsSoftenedForBackground() throws {
        let dark = try #require(CoverColor.dominant(rgba: image(repeated((60, 0, 0), 100))))
        let bright = try #require(CoverColor.dominant(rgba: image(repeated((255, 255, 0), 100))))
        #expect(CoverColor.hsv(dark.red, dark.green, dark.blue).value >= 0.45 - 1e-9)
        #expect(CoverColor.hsv(bright.red, bright.green, bright.blue).value <= 0.92 + 1e-9)
    }

    @Test func emptyImageHasNoColor() {
        #expect(CoverColor.dominant(rgba: []) == nil)
    }

    @Test func paletteStartsWithDominantAndAddsDistinctHues() {
        // Половина красного, четверть синего, четверть жёлтого
        let pixels = image(repeated((220, 30, 30), 200) + repeated((30, 60, 220), 100) + repeated((230, 210, 40), 100))
        let palette = CoverColor.palette(rgba: pixels)
        #expect(palette.count >= 3)
        #expect(palette.first == CoverColor.dominant(rgba: pixels))
        // Синий и жёлтый попали в палитру как отдельные цвета
        #expect(palette.contains { $0.blue > $0.red && $0.blue > $0.green })
        #expect(palette.contains { $0.red > 0.4 && $0.green > 0.4 && $0.blue < $0.green })
    }

    @Test func singleHueCoverStillGetsVariants() {
        let palette = CoverColor.palette(rgba: image(repeated((40, 160, 70), 400)))
        #expect(palette.count >= 3)
        #expect(Set(palette).count == palette.count)
    }

    @Test func blackAndWhiteCoverHasNoPalette() {
        #expect(CoverColor.palette(rgba: image(repeated((0, 0, 0), 200) + repeated((255, 255, 255), 200))).isEmpty)
    }
}
