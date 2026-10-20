import Foundation
import Testing
@testable import MelogoldCore

/// Цвета фона «Сейчас играет» по обложке (задание 0030): те же сценарии, что у Linux `artwork_colors.rs`.
@Suite("Цвета обложки по долям и размытая обложка")
struct ArtworkColorsTests {
    private func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                out += [r, g, b, 255]
            }
        }
        return out
    }

    /// Чёрная обложка с тонкой радугой (как у «The Dark Side of the Moon»): преобладает чёрный, а не красный, как
    /// выбирал Score; радуга — маленькими долями. Тест Linux `a_black_cover_with_a_thin_rainbow_is_mostly_black`.
    @Test func blackCoverWithThinRainbowIsMostlyBlack() throws {
        let rainbow: [(UInt8, UInt8, UInt8)] = [(230, 30, 30), (240, 200, 20), (30, 160, 60), (40, 90, 220)]
        let rgba = image(200, 200) { x, y in (90..<110).contains(y) && x > 100 ? rainbow[(y - 90) / 5] : (2, 2, 2) }
        let shares = ArtworkColors.shares(rgba: rgba, width: 200, height: 200, stride: 800)
        let first = try #require(shares.first)
        #expect(ArtworkColors.Lab(first.rgb).l < 10, "первым — чёрный: \(shares)")
        #expect(first.share > 0.85, "\(shares)")
        #expect(shares.count >= 3, "цвета радуги тоже есть, маленькими долями: \(shares)")
        #expect(abs(shares.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        // Красный и синий полосы — среди цветов
        #expect(shares.contains { ArtworkColors.Lab($0.rgb).a > 40 })
        #expect(shares.contains { ArtworkColors.Lab($0.rgb).b < -40 })
    }

    @Test func emptyOrBrokenImageHasNoShares() {
        #expect(ArtworkColors.shares(rgba: [], width: 0, height: 0, stride: 0).isEmpty)
        #expect(ArtworkColors.shares(rgba: [0, 0, 0, 255], width: 2, height: 2, stride: 8).isEmpty)
        #expect(BackdropCover.prepare(rgba: [1, 2, 3], width: 10, height: 10, stride: 40) == nil)
    }

    @Test func backdropKeepsWhiteTextReadable() {
        #expect(ArtworkColors.Lab(ArtworkColors.darkBackdrop(0xFF_FFFF)).l <= 38.5, "белая обложка — серый фон")
        #expect(ArtworkColors.Lab(ArtworkColors.darkBackdrop(0x02_0202)).l >= 5.5, "чёрная — почти чёрный, не провал")
        let red = ArtworkColors.Lab(ArtworkColors.darkBackdrop(0xE0_1E1E))
        #expect(red.a > 20, "красный остаётся красным: \(red)")
    }

    @Test func labRoundTrip() {
        for color: UInt32 in [0x00_0000, 0xFF_FFFF, 0xE0_1E1E, 0x2D_5AE0, 0x7F_7F7F, 0x12_AB34] {
            let back = ArtworkColors.Lab(color).rgb
            for shift: UInt32 in [16, 8, 0] {
                let (a, b) = (Int((color >> shift) & 0xFF), Int((back >> shift) & 0xFF))
                #expect(abs(a - b) <= 1, "\(String(color, radix: 16)) → \(String(back, radix: 16))")
            }
        }
    }

    @Test func flatCoverGivesFlatPreview() throws {
        let rgba = image(100, 60) { _, _ in (200, 40, 40) }
        let preview = try #require(ArtworkColors.backdropPreview(rgba: rgba, width: 100, height: 60, stride: 400))
        #expect(preview.rgba.count == ArtworkColors.previewSide * ArtworkColors.previewSide * 4)
        #expect(stride(from: 0, to: preview.rgba.count, by: 4).allSatisfy { Array(preview.rgba[$0..<($0 + 4)]) == [200, 40, 40, 255] },
                "однотонная остаётся однотонной")
        let expected = (0.2126 * 200 + 0.7152 * 40 + 0.0722 * 40) / 255
        #expect(abs(preview.luma - expected) < 1e-9)
        #expect(preview.base == ArtworkColors.darkBackdrop(0xC8_2828))
    }

    @Test func previewBlursAHardEdge() throws {
        // Левая половина белая, правая чёрная: после размытия у границы — серый переход, края — почти исходные
        let rgba = image(48, 48) { x, _ in x < 24 ? (255, 255, 255) : (0, 0, 0) }
        let preview = try #require(ArtworkColors.backdropPreview(rgba: rgba, width: 48, height: 48, stride: 192))
        let row = 12 * ArtworkColors.previewSide * 4
        let left = preview.rgba[row], middle = preview.rgba[row + 12 * 4], right = preview.rgba[row + 23 * 4]
        #expect(left > 240 && right < 15)
        #expect((60...200).contains(middle), "\(middle)")
    }

    @Test func shaderTextureAveragesCells() throws {
        // 512 × 512 в шахматку 1 px — каждая клетка 2 × 2 усредняется в серый
        let rgba = image(512, 512) { x, y in (x + y) % 2 == 0 ? (255, 255, 255) : (0, 0, 0) }
        let texture = try #require(ArtworkColors.shaderTexture(rgba: rgba, width: 512, height: 512, stride: 2048))
        #expect(texture.count == 256 * 256 * 4)
        #expect(texture[0] == 127 && texture[3] == 255)
    }

    @Test func colorMatrixDimsBrightCoverAndKeepsDarkOne() {
        // Светлая обложка (яркость 0,9) приглушается до k = 1/3, тёмная (0,1) — нет
        #expect(abs(ArtworkColors.brightness(luma: 0.9) - 0.30 / 0.9) < 1e-12)
        #expect(ArtworkColors.brightness(luma: 0.1) == 1)
        #expect(ArtworkColors.brightness(luma: 0) == 1)
        // Серый остаётся серым при любой насыщенности; цвет становится насыщеннее
        let grey = ArtworkColors.applyColorMatrix([100, 100, 100, 255], brightness: 1, saturation: 1.6)
        #expect(grey == [100, 100, 100, 255])
        let red = ArtworkColors.applyColorMatrix([150, 60, 60, 200], brightness: 1, saturation: 1.6)
        #expect(red[0] > 150 && red[1] < 60 && red[3] == 200)
        let dimmed = ArtworkColors.applyColorMatrix([200, 200, 200, 255], brightness: 0.5, saturation: 1.6)
        #expect(dimmed == [100, 100, 100, 255])
    }

    @Test func preparedCoverHasEverything() throws {
        let rgba = image(64, 64) { x, _ in x < 32 ? (20, 160, 150) : (240, 240, 235) }
        let cover = try #require(BackdropCover.prepare(rgba: rgba, width: 64, height: 64, stride: 256))
        #expect(cover.tinted.count == cover.preview.rgba.count)
        #expect(cover.shaderTexture.count == 256 * 256 * 4)
        #expect(cover.shares.count == 2)
        #expect(cover.base == ArtworkColors.darkBackdrop(cover.shares[0].rgb))
    }
}

/// Квантование `QuantizerCelebi`: сценарии из Material color utilities (тесты крейта `material-colors`).
@Suite("Квантование цветов Celebi")
struct QuantizerCelebiTests {
    private let red: UInt32 = 0xFFFF_0000, green: UInt32 = 0xFF00_FF00, blue: UInt32 = 0xFF00_00FF

    @Test func singleColorStaysItself() {
        for color in [0xFF14_1216, red, green, blue] {
            let result = QuantizerCelebi.quantize([color], maxColors: 256)
            #expect(result.map(\.argb) == [color])
        }
        #expect(QuantizerCelebi.quantize(Array(repeating: blue, count: 5), maxColors: 256).map(\.argb) == [blue])
    }

    @Test func countsArePreserved() {
        let result = QuantizerCelebi.quantize([red, red, green, green, green], maxColors: 256)
        #expect(result.count == 2)
        #expect(result.first { $0.argb == green }?.count == 3)
        #expect(result.first { $0.argb == red }?.count == 2)
        let three = QuantizerCelebi.quantize([red, green, blue], maxColors: 256)
        #expect(Set(three.map(\.argb)) == [red, green, blue])
    }

    @Test func manyShadesFitIntoTheLimitAndAreStable() {
        var pixels: [UInt32] = []
        for i in 0..<4000 {
            let r = UInt32((i * 37) % 256), g = UInt32((i * 91) % 256), b = UInt32((i * 13) % 256)
            pixels.append(0xFF00_0000 | r << 16 | g << 8 | b)
        }
        let first = QuantizerCelebi.quantize(pixels, maxColors: 16)
        let second = QuantizerCelebi.quantize(pixels, maxColors: 16)
        #expect(first.count <= 16 && first.count > 8)
        #expect(first.map(\.argb) == second.map(\.argb))
        #expect(first.reduce(0) { $0 + $1.count } == pixels.count)
    }

    @Test func materialLabRoundTrip() {
        for color: UInt32 in [0xFF00_0000, 0xFFFF_FFFF, 0xFFE0_1E1E, 0xFF2D_5AE0, 0xFF12_AB34] {
            #expect(MaterialLab(color).argb == color)
        }
    }

    @Test func javaRandomMatchesJava() {
        // java.util.Random(42).nextInt(10) — 0, 3, 8, 4, 0 (известная последовательность Java)
        var random = JavaRandom(seed: 42)
        #expect((0..<5).map { _ in random.next(below: 10) } == [0, 3, 8, 4, 0])
    }
}
