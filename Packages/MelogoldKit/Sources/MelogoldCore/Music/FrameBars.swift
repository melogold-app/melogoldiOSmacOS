import Foundation

/// Прямоугольник в пикселях.
public struct PixelRect: Hashable, Sendable {
    public var x, y, width, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Чёрные поля у кадра видео YouTube (задание 0008): квадратная обложка в кадре 16:9 (видео-«статика» с обложкой
/// сингла) — полосы по бокам, превью 4:3 (`hqdefault`) — сверху и снизу. Порт `FrameBars.cs` Windows. Порог строгий:
/// тёмная сцена самого видео полем не считается — поля почти целиком чёрные, заметные и одинаковые с двух сторон.
public enum FrameBars {
    /// Чёрный у JPEG — 0…20 по каналу.
    static let maxChannel: UInt8 = 28
    /// Линия — поле, если почти все её пиксели чёрные.
    static let minBarShare = 0.98
    /// Поля срезаются, только если вместе они не меньше 3 % стороны.
    static let minBars = 0.03
    /// Поля по краям одинаковые: у тёмной сцены тёмен обычно один край.
    static let maxAsymmetry = 0.03
    /// Остаток — не меньше 40 % стороны: почти чёрный кадр остаётся как есть.
    static let minContent = 0.4

    /// Что остаётся без полей; `nil` — полей нет. `pixels` — 4 байта на пиксель (RGBA или BGRA, альфа последней),
    /// `bytesPerRow` — длина строки с отступом.
    public static func content(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> PixelRect? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, pixels.count >= bytesPerRow * (height - 1) + width * 4 else { return nil }

        func line(_ index: Int, from: Int, to: Int, horizontal: Bool) -> Bool {
            let count = to - from + 1
            let allowed = count - Int((Double(count) * minBarShare).rounded(.up))
            var bright = 0
            for i in from...to {
                let offset = horizontal ? index * bytesPerRow + i * 4 : i * bytesPerRow + index * 4
                if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > maxChannel {
                    bright += 1
                    if bright > allowed { return false }
                }
            }
            return true
        }

        func accept(_ first: Int, _ last: Int, _ size: Int) -> Bool {
            Double(first + last) >= Double(size) * minBars
                && Double(abs(first - last)) <= Double(size) * maxAsymmetry
                && Double(size - first - last) >= Double(size) * minContent
        }

        var top = 0, bottom = height - 1
        while top < bottom, line(top, from: 0, to: width - 1, horizontal: true) { top += 1 }
        while bottom > top, line(bottom, from: 0, to: width - 1, horizontal: true) { bottom -= 1 }
        let (y0, y1) = accept(top, height - 1 - bottom, height) ? (top, bottom) : (0, height - 1)

        var left = 0, right = width - 1
        while left < right, line(left, from: y0, to: y1, horizontal: false) { left += 1 }
        while right > left, line(right, from: y0, to: y1, horizontal: false) { right -= 1 }
        let (x0, x1) = accept(left, width - 1 - right, width) ? (left, right) : (0, width - 1)

        if x0 == 0, y0 == 0, x1 == width - 1, y1 == height - 1 { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    public static func content(_ pixels: [UInt8], width: Int, height: Int) -> PixelRect? {
        pixels.withUnsafeBytes { content($0, width: width, height: height, bytesPerRow: width * 4) }
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

/// Обрезка кадра видео: без чёрных полей (`FrameBars`) и центральный квадрат (задание 0008).
public enum FrameCrop {
    /// Кадр без чёрных полей; полей нет — тот же кадр.
    public static func withoutBars(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 4_000_000 else { return image }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let rect = FrameBars.content(pixels, width: width, height: height) else { return image }
        return image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) ?? image
    }

    /// Центральный квадрат: у кадра 16:9 — середина, а не левый край.
    public static func centerSquare(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        guard side > 0, image.width != image.height else { return image }
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return image.cropping(to: rect) ?? image
    }
}
#endif
