import CoreGraphics
import CoreImage
import SwiftUI

/// Цвет обложки для фона «Итогов года» (docs/PROMPT.md §5.1: мягкий статичный оттенок, доминирующий цвет через Core
/// Image): средний цвет картинки, приведённый к яркости, на которой читается белый текст.
enum ArtworkTint {
    /// Цвет бренда Melogold — фон года, у которого нет обложки.
    static let brand = Tint(red: 0.996, green: 0.42, blue: 0.03).adjusted()

    struct Tint: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }

        /// Яркость не выше 0,55 и насыщенность не ниже 0,35: под белым текстом.
        func adjusted() -> Tint {
            let maxValue = max(red, green, blue)
            let minValue = min(red, green, blue)
            let delta = maxValue - minValue
            var hue = 0.0
            if delta > 0 {
                switch maxValue {
                case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
                case green: hue = (blue - red) / delta + 2
                default: hue = (red - green) / delta + 4
                }
                hue /= 6
                if hue < 0 { hue += 1 }
            }
            let saturation = max(0.35, maxValue == 0 ? 0 : delta / maxValue)
            let brightness = min(0.55, max(0.3, maxValue))
            return Tint(hue: hue, saturation: saturation, brightness: brightness)
        }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hue: Double, saturation: Double, brightness: Double) {
            let h = hue * 6
            let c = brightness * saturation
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let m = brightness - c
            let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
            self.init(red: r + m, green: g + m, blue: b + m)
        }

        /// Ниже по фону — темнее.
        var darker: Tint { Tint(red: red * 0.55, green: green * 0.55, blue: blue * 0.55) }
    }

    /// Средний цвет картинки через `CIAreaAverage`; `nil` — картинка не разобралась.
    static func tint(of image: CGImage) -> Tint? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Tint(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255).adjusted()
    }
}
