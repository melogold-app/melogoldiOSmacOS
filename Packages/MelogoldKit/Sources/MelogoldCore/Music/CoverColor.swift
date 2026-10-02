import Foundation

/// Цвет в sRGB, каналы 0…1.
public struct CoverRGB: Hashable, Sendable {
    public var red, green, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Доминирующий цвет обложки для фона «Сейчас играет» (docs/PROMPT.md §5.1: «мягкий статичный оттенок цвета обложки»).
///
/// Не среднее по картинке: среднее из красного и синего даёт грязно-лиловый, а чёрная рамка обложки тянет всё в серое.
/// Пиксели делятся по оттенку на 12 секторов; побеждает сектор с наибольшей площадью (насыщенные весят больше), в него
/// входят и соседние сектора — красный по обе стороны от 0°. Чёрные, белые и серые пиксели не голосуют: у чёрно-белой
/// обложки цвета нет, фон остаётся системным (`nil`). Выбранный цвет приглушается до диапазона, который годится под фон
/// (насыщенность и яркость ограничены), сама подмешивающая прозрачность — забота вида.
public enum CoverColor {
    static let sectors = 12
    /// Пиксель голосует, если он не серый или белый (насыщенность от `minSaturation`) и не чёрный (яркость от `minValue`).
    static let minSaturation = 0.20
    static let minValue = 0.14
    /// Цвета должно быть заметно: меньше 8 % пикселей — обложка считается бесцветной.
    static let minChromaticShare = 0.08

    /// `rgba` — 4 байта на пиксель (R, G, B, A), sRGB; пиксели с прозрачностью меньше половины не считаются.
    public static func dominant(rgba: [UInt8]) -> CoverRGB? {
        let count = rgba.count / 4
        guard count > 0 else { return nil }
        var weight = [Double](repeating: 0, count: sectors)
        var sum = [(r: Double, g: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: sectors)
        var voters = 0.0
        for index in 0..<count {
            let offset = index * 4
            guard rgba[offset + 3] >= 128 else { continue }
            let r = Double(rgba[offset]) / 255, g = Double(rgba[offset + 1]) / 255, b = Double(rgba[offset + 2]) / 255
            let (hue, saturation, value) = hsv(r, g, b)
            guard saturation >= minSaturation, value >= minValue else { continue }
            let w = 0.3 + saturation
            let sector = min(sectors - 1, Int(hue / 360 * Double(sectors)))
            weight[sector] += w
            sum[sector].r += r * w
            sum[sector].g += g * w
            sum[sector].b += b * w
            sum[sector].w += w
            voters += 1
        }
        guard voters / Double(count) >= minChromaticShare else { return nil }
        // Сектор вместе с соседями: границы секторов не должны дробить один цвет
        var best = 0
        var bestWeight = -1.0
        for sector in 0..<sectors {
            let total = weight[sector] + 0.5 * (weight[(sector + 1) % sectors] + weight[(sector + sectors - 1) % sectors])
            if total > bestWeight {
                bestWeight = total
                best = sector
            }
        }
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for (offset, factor) in [(0, 1.0), (1, 0.5), (sectors - 1, 0.5)] {
            let cell = sum[(best + offset) % sectors]
            r += cell.r * factor
            g += cell.g * factor
            b += cell.b * factor
            w += cell.w * factor
        }
        guard w > 0 else { return nil }
        return soften(CoverRGB(red: r / w, green: g / w, blue: b / w))
    }

    /// Палитра для живого фона «Сейчас играет» (пользователь, 2026-10-02: «живой градиент из цветов обложки, двигается под
    /// звук»): первым — доминирующий цвет (`dominant`), за ним до трёх заметных цветов других оттенков, отстоящих от уже
    /// взятых хотя бы на два сектора (60°), — по убыванию площади. Если других цветов на обложке нет, палитру дополняют
    /// светлый и тёмный вариант доминирующего, чтобы пятнам фона было чем отличаться. У чёрно-белой обложки — пусто.
    public static func palette(rgba: [UInt8], maxColors: Int = 4) -> [CoverRGB] {
        guard let main = dominant(rgba: rgba) else { return [] }
        let count = rgba.count / 4
        var weight = [Double](repeating: 0, count: sectors)
        var sum = [(r: Double, g: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: sectors)
        for index in 0..<count {
            let offset = index * 4
            guard rgba[offset + 3] >= 128 else { continue }
            let r = Double(rgba[offset]) / 255, g = Double(rgba[offset + 1]) / 255, b = Double(rgba[offset + 2]) / 255
            let (hue, saturation, value) = hsv(r, g, b)
            guard saturation >= minSaturation, value >= minValue else { continue }
            let w = 0.3 + saturation
            let sector = min(sectors - 1, Int(hue / 360 * Double(sectors)))
            weight[sector] += w
            sum[sector] = (sum[sector].r + r * w, sum[sector].g + g * w, sum[sector].b + b * w, sum[sector].w + w)
        }
        let total = weight.reduce(0, +)
        var colors = [main]
        var taken = [sector(of: main)]
        // Сектора по убыванию площади; цвет берётся, если его не меньше 4 % цветных пикселей и он далёк от уже взятых
        for candidate in weight.indices.sorted(by: { weight[$0] > weight[$1] }) where colors.count < maxColors {
            guard total > 0, weight[candidate] / total >= 0.04, sum[candidate].w > 0 else { continue }
            let far = taken.allSatisfy { other in
                let distance = abs(candidate - other)
                return min(distance, sectors - distance) >= 2
            }
            guard far else { continue }
            let cell = sum[candidate]
            colors.append(soften(CoverRGB(red: cell.r / cell.w, green: cell.g / cell.w, blue: cell.b / cell.w)))
            taken.append(candidate)
        }
        // Одноцветная обложка: светлее и темнее того же цвета
        if colors.count < 3 {
            let (hue, saturation, value) = hsv(main.red, main.green, main.blue)
            colors.append(rgb(hue: hue, saturation: min(0.8, saturation * 1.15), value: max(0.35, value * 0.7)))
            if colors.count < maxColors {
                colors.append(rgb(hue: (hue + 18).truncatingRemainder(dividingBy: 360), saturation: saturation * 0.8, value: min(0.95, value * 1.1)))
            }
        }
        return Array(colors.prefix(maxColors))
    }

    private static func sector(of color: CoverRGB) -> Int {
        let hue = hsv(color.red, color.green, color.blue).hue
        return min(sectors - 1, Int(hue / 360 * Double(sectors)))
    }

    /// Насыщенность не выше 0,75 и не ниже 0,25, яркость — 0,45…0,92: под фон и с тёмным, и со светлым текстом.
    static func soften(_ color: CoverRGB) -> CoverRGB {
        let (hue, saturation, value) = hsv(color.red, color.green, color.blue)
        return rgb(hue: hue, saturation: min(0.75, max(0.25, saturation)), value: min(0.92, max(0.45, value)))
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double, value: Double) {
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        return (hue, high == 0 ? 0 : delta / high, high)
    }

    static func rgb(hue: Double, saturation: Double, value: Double) -> CoverRGB {
        let chroma = value * saturation
        let sector = hue / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let m = value - chroma
        return CoverRGB(red: r1 + m, green: g1 + m, blue: b1 + m)
    }
}
