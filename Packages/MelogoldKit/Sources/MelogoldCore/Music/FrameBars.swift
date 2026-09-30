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

/// Поля у кадра видео YouTube (задание 0008): квадратная обложка в кадре 16:9 (видео-«статика» с обложкой сингла) —
/// полосы по бокам, превью 4:3 (`hqdefault`) — сверху и снизу. Порт `FrameBars.cs` Windows, но поля не только чёрные:
/// у «статики» они бывают любого ровного цвета (коричневые у «Группы крови» — прямоугольник с полями в «Сейчас играет»
/// вместо квадратной обложки, 2026-09-30). Порог строгий: поле — линия почти целиком одного цвета, поля заметные,
/// одинаковой ширины и одного цвета с двух сторон; тёмная или однотонная сцена самого видео полем не считается.
public enum FrameBars {
    /// Отклонение пикселя поля от цвета поля, по каналу: шум JPEG.
    static let tolerance = 24
    /// Линия — поле, если почти все её пиксели цвета поля.
    static let minBarShare = 0.98
    /// Поля срезаются, только если вместе они не меньше 3 % стороны.
    static let minBars = 0.03
    /// Поля по краям одинаковые: у тёмной сцены тёмен обычно один край.
    static let maxAsymmetry = 0.03
    /// Поля с двух сторон одного цвета (по каналу).
    static let maxSidesDifference = 40
    /// Остаток — не меньше 40 % стороны: почти однотонный кадр остаётся как есть.
    static let minContent = 0.4
    /// Рамка обводки внутри полей (чёрная обводка обложки в кадре «статики»): со всех четырёх сторон, одного цвета,
    /// каждая сторона — не шире этой доли стороны.
    static let maxRing = 0.06

    private typealias Color = (r: Int, g: Int, b: Int)

    /// Что остаётся без полей и обводки; `nil` — срезать нечего. `pixels` — 4 байта на пиксель (RGBA или BGRA, альфа
    /// последней), `bytesPerRow` — длина строки с отступом. `bars: false` — только обводка: у квадратной обложки YouTube
    /// Music полей нет, а чёрная рамка скана бывает (обложка «Группы крови»).
    public static func content(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bars useBars: Bool = true) -> PixelRect? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, pixels.count >= bytesPerRow * (height - 1) + width * 4 else { return nil }

        func pixel(_ index: Int, _ i: Int, horizontal: Bool) -> Color {
            let offset = horizontal ? index * bytesPerRow + i * 4 : i * bytesPerRow + index * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }

        func near(_ a: Color, _ b: Color, _ limit: Int) -> Bool {
            abs(a.r - b.r) <= limit && abs(a.g - b.g) <= limit && abs(a.b - b.b) <= limit
        }

        /// Линия почти вся цвета `color`.
        func matches(_ index: Int, from: Int, to: Int, horizontal: Bool, _ color: Color) -> Bool {
            let count = to - from + 1
            let allowed = count - Int((Double(count) * minBarShare).rounded(.up))
            var off = 0
            for i in from...to where !near(pixel(index, i, horizontal: horizontal), color, tolerance) {
                off += 1
                if off > allowed { return false }
            }
            return true
        }

        /// Цвет крайней линии, если она почти вся одного цвета; `nil` — у края картинка.
        func edgeColor(_ index: Int, from: Int, to: Int, horizontal: Bool) -> Color? {
            var sum: Color = (0, 0, 0)
            for i in from...to {
                let p = pixel(index, i, horizontal: horizontal)
                sum = (sum.r + p.r, sum.g + p.g, sum.b + p.b)
            }
            let count = to - from + 1
            let mean: Color = (sum.r / count, sum.g / count, sum.b / count)
            return matches(index, from: from, to: to, horizontal: horizontal, mean) ? mean : nil
        }

        /// Ширина полей с двух концов стороны `size`: линии поперёк — от `from` до `to`.
        func bars(size: Int, from: Int, to: Int, horizontal: Bool) -> (Int, Int)? {
            guard let first = edgeColor(0, from: from, to: to, horizontal: horizontal),
                  let last = edgeColor(size - 1, from: from, to: to, horizontal: horizontal),
                  near(first, last, maxSidesDifference) else { return nil }
            var start = 0, end = size - 1
            while start < end, matches(start, from: from, to: to, horizontal: horizontal, first) { start += 1 }
            while end > start, matches(end, from: from, to: to, horizontal: horizontal, last) { end -= 1 }
            let tail = size - 1 - end
            guard Double(start + tail) >= Double(size) * minBars,
                  Double(abs(start - tail)) <= Double(size) * maxAsymmetry,
                  Double(size - start - tail) >= Double(size) * minContent else { return nil }
            return (start, end)
        }

        /// Рамка одного цвета со всех четырёх сторон прямоугольника: новые границы или `nil`.
        func ring(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> (Int, Int, Int, Int)? {
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            guard w > 8, h > 8, let color = edgeColor(y0, from: x0, to: x1, horizontal: true) else { return nil }
            var top = y0, bottom = y1, left = x0, right = x1
            while top < y1, matches(top, from: x0, to: x1, horizontal: true, color) { top += 1 }
            while bottom > top, matches(bottom, from: x0, to: x1, horizontal: true, color) { bottom -= 1 }
            while left < x1, matches(left, from: y0, to: y1, horizontal: false, color) { left += 1 }
            while right > left, matches(right, from: y0, to: y1, horizontal: false, color) { right -= 1 }
            let vertical = [top - y0, y1 - bottom], horizontal = [left - x0, x1 - right]
            guard (vertical + horizontal).allSatisfy({ $0 >= 1 }),
                  vertical.allSatisfy({ Double($0) <= Double(h) * maxRing }),
                  horizontal.allSatisfy({ Double($0) <= Double(w) * maxRing }) else { return nil }
            // Ещё полпроцента: граница рамки у JPEG размыта, иначе по краю остаётся тёмный волосок
            let blend = max(1, Int((Double(min(w, h)) * 0.005).rounded(.up)))
            guard right - left > 2 * blend, bottom - top > 2 * blend else { return nil }
            return (left + blend, right - blend, top + blend, bottom - blend)
        }

        var (y0, y1) = (useBars ? bars(size: height, from: 0, to: width - 1, horizontal: true) : nil) ?? (0, height - 1)
        var (x0, x1) = (useBars ? bars(size: width, from: y0, to: y1, horizontal: false) : nil) ?? (0, width - 1)
        if let inner = ring(x0, x1, y0, y1) { (x0, x1, y0, y1) = inner }

        if x0 == 0, y0 == 0, x1 == width - 1, y1 == height - 1 { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    public static func content(_ pixels: [UInt8], width: Int, height: Int, bars: Bool = true) -> PixelRect? {
        pixels.withUnsafeBytes { content($0, width: width, height: height, bytesPerRow: width * 4, bars: bars) }
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

/// Обрезка кадра видео: без полей (`FrameBars`) и центральный квадрат (задание 0008).
public enum FrameCrop {
    /// Кадр без полей и обводки; срезать нечего — тот же кадр. `bars: false` — только обводка (квадратная обложка).
    public static func withoutBars(_ image: CGImage, bars: Bool = true) -> CGImage {
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
        guard drawn, let rect = FrameBars.content(pixels, width: width, height: height, bars: bars) else { return image }
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
