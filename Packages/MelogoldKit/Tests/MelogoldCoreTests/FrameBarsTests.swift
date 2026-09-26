import Foundation
import Testing
@testable import MelogoldCore

/// Чёрные поля кадра видео (задание 0008): те же случаи, что `FrameBarsTests` у Windows.
@Suite("Поля кадра видео")
struct FrameBarsTests {
    /// Кадр RGBA: `paint` даёт яркость пикселя (x, y).
    private func frame(_ width: Int, _ height: Int, _ paint: (Int, Int) -> UInt8) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = paint(x, y)
                let i = (y * width + x) * 4
                pixels[i] = value
                pixels[i + 1] = value
                pixels[i + 2] = value
            }
        }
        return pixels
    }

    /// «Картинка»: пёстрая, с тёмными местами, но не поле.
    private func picture(_ x: Int, _ y: Int) -> UInt8 { UInt8(40 + (x * 7 + y * 13) % 200) }

    @Test func squareCoverInWideFrameLosesSideBars() {
        // hq720 «статичного» видео: обложка 720×720 посередине кадра 1280×720
        let pixels = frame(1280, 720) { x, y in (280..<1000).contains(x) ? picture(x, y) : (x % 3 == 0 ? 12 : 4) }
        #expect(FrameBars.content(pixels, width: 1280, height: 720) == PixelRect(x: 280, y: 0, width: 720, height: 720))
    }

    @Test func letterboxedPreviewLosesTopAndBottom() {
        // hqdefault 480×360: кадр 16:9 и полосы по 45 px сверху и снизу
        let pixels = frame(480, 360) { x, y in (45..<315).contains(y) ? picture(x, y) : 0 }
        #expect(FrameBars.content(pixels, width: 480, height: 360) == PixelRect(x: 0, y: 45, width: 480, height: 270))
    }

    @Test func fullFrameStaysAsIs() {
        #expect(FrameBars.content(frame(320, 180, picture), width: 320, height: 180) == nil)
    }

    @Test func darkSceneOnOneSideIsNotABar() {
        // Ночная сцена: тёмная левая треть, справа светло — полей нет
        let pixels = frame(320, 180) { x, y in x < 110 ? 6 : picture(x, y) }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == nil)
    }

    @Test func almostBlackFrameStaysAsIs() {
        // Почти весь кадр чёрный, светлая полоска посередине — срезать нечего
        let pixels = frame(320, 180) { x, y in (150..<170).contains(x) ? picture(x, y) : 0 }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == nil)
    }

    @Test func thinEdgeIsNotABar() {
        // Чёрная кромка в 2 px — меньше 3 % стороны
        let pixels = frame(320, 180) { x, y in x < 2 || x >= 318 ? 0 : picture(x, y) }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == nil)
    }

    @Test func jpegNoiseInBarsIsTolerated() {
        // Редкие светлые пиксели в поле (шум JPEG) — всё равно поле
        let pixels = frame(320, 180) { x, y in (70..<250).contains(x) ? picture(x, y) : (x == 10 && y == 50 ? 200 : 8) }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == PixelRect(x: 70, y: 0, width: 180, height: 180))
    }

    @Test func rowPaddingIsRespected() {
        // Строки с отступом (как у CGImage): поля по бокам находятся так же
        let width = 320, height = 180, stride = width * 4 + 64
        var pixels = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (70..<250).contains(x) ? picture(x, y) : 8
                let i = y * stride + x * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
            }
        }
        let rect = pixels.withUnsafeBytes { FrameBars.content($0, width: width, height: height, bytesPerRow: stride) }
        #expect(rect == PixelRect(x: 70, y: 0, width: 180, height: 180))
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

/// Обрезка настоящей картинки: квадрат 90×90 в кадре 160×90 с чёрными полями по бокам.
@Suite("Обрезка кадра")
struct FrameCropTests {
    private func image(_ width: Int, _ height: Int, _ paint: (Int, Int) -> UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = paint(x, y)
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    @Test func squareCoverLosesSideBars() throws {
        let frame = try image(160, 90) { x, y in (35..<125).contains(x) ? UInt8(60 + (x + y) % 150) : 5 }
        let cropped = FrameCrop.withoutBars(frame)
        #expect(cropped.width == 90)
        #expect(cropped.height == 90)
    }

    @Test func centerSquareTakesTheMiddle() throws {
        let frame = try image(160, 90) { x, _ in x < 80 ? 200 : 100 }
        let square = FrameCrop.centerSquare(frame)
        #expect(square.width == 90 && square.height == 90)
    }
}
#endif
