import Foundation
import Testing
@testable import MelogoldCore

/// Поля кадра видео (задание 0008): те же случаи, что `FrameBarsTests` у Windows, и поля не чёрного цвета.
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

    /// Кадр RGBA по цвету пикселя.
    private func colored(_ width: Int, _ height: Int, _ paint: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = paint(x, y)
                let i = (y * width + x) * 4
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
            }
        }
        return pixels
    }

    @Test func brownSideBarsAreBarsToo() {
        // «Группа крови»: обложка посередине кадра, по бокам ровные коричневые поля с шумом JPEG
        let pixels = colored(320, 180) { x, y in
            if (70..<250).contains(x) { let v = picture(x, y); return (v, v, v) }
            let noise = UInt8((x + y) % 9)
            return (90 + noise, 45 + noise, 25 + noise)
        }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == PixelRect(x: 70, y: 0, width: 180, height: 180))
    }

    @Test func blackRingInsideBrownBarsGoesToo() {
        // «Группа крови» целиком: коричневые поля, внутри них обложка в чёрной обводке 6 px
        let pixels = colored(320, 180) { x, y in
            guard (70..<250).contains(x) else { return (90, 45, 25) }
            if x < 76 || x >= 244 || y < 6 || y >= 174 { return (8, 8, 8) }
            let v = picture(x, y)
            return (v, v, v)
        }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == PixelRect(x: 77, y: 7, width: 166, height: 166))
    }

    @Test func thickFrameIsNotARing() {
        // Светлая рамка 12 % с каждой стороны внутри кадра без полей — это часть картинки, не обводка
        let pixels = colored(200, 200) { x, y in
            (24..<176).contains(x) && (24..<176).contains(y) ? { let v = picture(x, y); return (v, v, v) }() : (240, 240, 240)
        }
        let rect = FrameBars.content(pixels, width: 200, height: 200)
        // Поля с четырёх сторон по 24 px (12 % — больше 3 % вместе) срезаются как поля, а не как обводка
        #expect(rect == PixelRect(x: 24, y: 24, width: 152, height: 152))
    }

    @Test func pictureWithoutRingStays() {
        // Кадр без полей и без обводки: край — сама картинка
        #expect(FrameBars.content(frame(200, 200, picture), width: 200, height: 200) == nil)
    }

    @Test func squareCoverLosesOnlyItsRing() {
        // Квадратная обложка YouTube Music — скан в чёрной обводке 5 px; поля не ищутся
        let pixels = colored(200, 200) { x, y in
            if x < 5 || x >= 195 || y < 5 || y >= 195 { return (6, 6, 6) }
            let v = picture(x, y)
            return (v, v, v)
        }
        #expect(FrameBars.content(pixels, width: 200, height: 200, bars: false) == PixelRect(x: 6, y: 6, width: 188, height: 188))
    }

    @Test func squareCoverOnPlainBackgroundKeepsItsBackground() {
        // Без поиска полей широкий ровный фон обложки (25 % стороны) не срезается: это сама обложка
        let pixels = colored(200, 200) { x, y in
            (50..<150).contains(x) && (50..<150).contains(y) ? { let v = picture(x, y); return (v, v, v) }() : (0, 0, 0)
        }
        #expect(FrameBars.content(pixels, width: 200, height: 200, bars: false) == nil)
    }

    @Test func differentColorsOnTheSidesAreNotBars() {
        // Слева коричневая стена, справа синее небо — это кадр, а не поля
        let pixels = colored(320, 180) { x, y in
            if (70..<250).contains(x) { let v = picture(x, y); return (v, v, v) }
            return x < 70 ? (90, 45, 25) : (40, 90, 200)
        }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == nil)
    }

    @Test func plainSkyOnOneSideIsNotABar() {
        // Ровное светлое небо только слева — полей нет
        let pixels = colored(320, 180) { x, y in x < 110 ? (200, 220, 250) : { let v = picture(x, y); return (v, v, v) }() }
        #expect(FrameBars.content(pixels, width: 320, height: 180) == nil)
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
