import Foundation

/// Цвет обложки (`0xRRGGBB`) и его доля в ней (0…1).
public struct ColorShare: Equatable, Sendable {
    public var rgb: UInt32
    public var share: Double

    public init(rgb: UInt32, share: Double) {
        self.rgb = rgb
        self.share = share
    }
}

/// Цвета фона «Сейчас играет» из обложки (задания 0030 и 0031) — перенос `melogold-core` `artwork_colors` у Linux: цвета
/// по долям, подложка под светлый текст, размытая обложка 24 × 24 и текстура живого фона 256 × 256. Числа общие для всех
/// платформ, по ним сверяются Linux, Windows, Android и Apple. Пиксели — RGBA по 4 байта, `stride` — байт в строке.
public enum ArtworkColors {
    /// Точек по ширине для цветов по долям; строк — пропорционально, но не больше `2 · sampleColumns`.
    static let sampleColumns = 112
    static let maxColors = 128
    /// Сколько цветов фона: преобладающий и до пяти остальных.
    static let maxShares = 6
    /// Цвет меньше этой доли не рисуется: шум сжатия и точка в углу — не цвета обложки. Порог низкий намеренно: радуга
    /// «The Dark Side of the Moon» — 1–2 % на цвет, и без неё обложка — просто чёрная.
    static let minShare = 0.005
    /// Расстояние в Lab (ΔE76), ближе которого цвета сливаются в один: тени и блики одного цвета — один цвет.
    static let mergeDistance = 16.0

    /// Сторона размытой обложки фона (задание 0030).
    public static let previewSide = 24
    /// Сторона текстуры обложки для живого фона (задание 0031).
    public static let shaderSide = 256

    /// Цвета обложки по долям, преобладающий — первым; доли в сумме дают 1.
    ///
    /// Здесь не выбирается «лучший» цвет: Score отдаёт предпочтение яркому, и у «The Dark Side of the Moon» фон выходил
    /// красным из тонкой радуги на чёрном. Чёрный и серый — такие же цвета, как остальные. Полосы letterbox не срезаются:
    /// у квадратной обложки чёрный край — часть рисунка.
    public static func shares(rgba: [UInt8], width: Int, height: Int, stride: Int) -> [ColorShare] {
        guard valid(rgba, width, height, stride) else { return [] }
        // Точки, а не средние по клеткам: усреднение превращает мелкий цветной узор в серый, и доля серого вырастала из
        // ничего
        let (columns, rows) = sampleSize(width, height)
        var pixels: [UInt32] = []
        pixels.reserveCapacity(columns * rows)
        for y in 0..<rows {
            let line = min(y * height / rows, height - 1) * stride
            for x in 0..<columns {
                let i = line + min(x * width / columns, width - 1) * 4
                pixels.append(0xFF00_0000 | UInt32(rgba[i]) << 16 | UInt32(rgba[i + 1]) << 8 | UInt32(rgba[i + 2]))
            }
        }
        // По убыванию числа пикселей, при равенстве — по значению RGB
        let colors = QuantizerCelebi.quantize(pixels, maxColors: maxColors)
            .map { (rgb: $0.argb & 0xFF_FFFF, count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.rgb < $1.rgb }

        // Слияние близких: цвет группы — её самый частый цвет, без усреднения. Среднее в Lab уплывало к серому, и радуга
        // «A Head Full of Dreams» превращалась в серую кашу
        var clusters: [(lab: Lab, weight: Double)] = []
        for color in colors {
            let lab = Lab(color.rgb)
            if let found = clusters.firstIndex(where: { $0.lab.distance(to: lab) < mergeDistance }) {
                clusters[found].weight += Double(color.count)
            } else {
                clusters.append((lab, Double(color.count)))
            }
        }
        // Устойчиво по убыванию веса: при равном весе — в порядке появления
        let ordered = clusters.enumerated()
            .sorted { $0.element.weight != $1.element.weight ? $0.element.weight > $1.element.weight : $0.offset < $1.offset }
            .map(\.element)
        let total = ordered.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let kept = ordered
            .map { ColorShare(rgb: $0.lab.rgb, share: $0.weight / total) }
            .filter { $0.share >= minShare }
            .prefix(maxShares)
        let sum = kept.reduce(0) { $0 + $1.share }
        return kept.map { ColorShare(rgb: $0.rgb, share: $0.share / sum) }
    }

    /// Цвет фона под светлый текст: оттенок и насыщенность прежние, светлота — в пределах, где белый текст читается
    /// (`L*` от 6 до 38). Белая обложка даёт серый фон, чёрная — почти чёрный, красная остаётся красной.
    public static func darkBackdrop(_ rgb: UInt32) -> UInt32 {
        let lab = Lab(rgb)
        let target = min(max(lab.l, 6), 38)
        // Темнее — чуть меньше насыщенности (у тёмного цвета та же насыщенность кричит), но не вдвое: иначе радуга
        // превращается в грязь
        let keep = lab.l > 0 ? min(max((target / lab.l).squareRoot(), 0.7), 1) : 1
        return Lab(l: target, a: lab.a * keep, b: lab.b * keep).rgb
    }

    /// Обложка для фона «Сейчас играет» (задание 0030): 24 × 24 после трёх проходов размытия «коробкой» 5 × 5, средняя
    /// яркость до размытия и цвет подложки. Растянутая на окно, она и есть «размытая обложка» — без размытия всего окна
    /// на каждом кадре. `shares` — уже посчитанные цвета по долям этой обложки (иначе считаются здесь).
    public static func backdropPreview(rgba: [UInt8], width: Int, height: Int, stride: Int,
                                       shares known: [ColorShare]? = nil) -> BackdropPreview? {
        guard valid(rgba, width, height, stride) else { return nil }
        let side = previewSide
        var cells = [Double](repeating: 0, count: side * side * 3)
        var luma = 0.0
        for cell in 0..<(side * side) {
            let (cx, cy) = (cell % side, cell / side)
            let (x0, y0) = (cx * width / side, cy * height / side)
            let x1 = min(max((cx + 1) * width / side, x0 + 1), width)
            let y1 = min(max((cy + 1) * height / side, y0 + 1), height)
            var sum = (0.0, 0.0, 0.0)
            var n = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * stride + x * 4
                    sum.0 += Double(rgba[i])
                    sum.1 += Double(rgba[i + 1])
                    sum.2 += Double(rgba[i + 2])
                    n += 1
                }
            }
            n = max(n, 1)
            cells[cell * 3] = sum.0 / n
            cells[cell * 3 + 1] = sum.1 / n
            cells[cell * 3 + 2] = sum.2 / n
            luma += (0.2126 * cells[cell * 3] + 0.7152 * cells[cell * 3 + 1] + 0.0722 * cells[cell * 3 + 2]) / 255
        }
        luma /= Double(side * side)
        for _ in 0..<3 { cells = boxBlur(cells, side: side) }
        let dominant = (known ?? shares(rgba: rgba, width: width, height: height, stride: stride)).first?.rgb ?? 0x10_1010
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for cell in 0..<(side * side) {
            for channel in 0..<3 { pixels[cell * 4 + channel] = UInt8(cells[cell * 3 + channel].rounded()) }
        }
        return BackdropPreview(rgba: pixels, luma: luma, base: darkBackdrop(dominant))
    }

    /// Обложка 256 × 256 RGBA усреднением по клеткам — текстура шейдера живого фона (задание 0031, §1).
    public static func shaderTexture(rgba: [UInt8], width: Int, height: Int, stride: Int) -> [UInt8]? {
        guard valid(rgba, width, height, stride) else { return nil }
        let side = shaderSide
        var out = [UInt8]()
        out.reserveCapacity(side * side * 4)
        for y in 0..<side {
            let (y0, y1) = (y * height / side, min(max((y + 1) * height / side, y * height / side + 1), height))
            for x in 0..<side {
                let (x0, x1) = (x * width / side, min(max((x + 1) * width / side, x * width / side + 1), width))
                var sum: (UInt32, UInt32, UInt32) = (0, 0, 0)
                var n: UInt32 = 0
                for row in y0..<y1 {
                    for column in x0..<x1 {
                        let i = row * stride + column * 4
                        sum.0 += UInt32(rgba[i])
                        sum.1 += UInt32(rgba[i + 1])
                        sum.2 += UInt32(rgba[i + 2])
                        n += 1
                    }
                }
                n = max(n, 1)
                out.append(contentsOf: [UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n), 255])
            }
        }
        return out
    }

    /// Яркость `k` матрицы цвета: светлую обложку под белым текстом приглушаем, тёмную не трогаем.
    public static func brightness(luma: Double) -> Double {
        min(max(0.30 / max(luma, 0.01), 0.30), 1.0)
    }

    /// Насыщенность матрицы цвета (Rec. 709).
    public static let saturation = 1.6

    /// Матрица цвета задания 0030 на пикселях RGBA: `R' = k·((lr+s)·R + lg·G + lb·B)` и так же для G и B, где
    /// `lr = 0,2126·(1−s)`, `lg = 0,7152·(1−s)`, `lb = 0,0722·(1−s)`; каналы обрезаются до 0…255, альфа не меняется.
    /// Матрица линейна, поэтому её можно наложить на 24 × 24 один раз на обложку, а не на каждый кадр: смесь двух слоёв
    /// и размытие дают то же с точностью до обрезки каналов (так же у Windows).
    public static func applyColorMatrix(_ rgba: [UInt8], brightness k: Double, saturation s: Double) -> [UInt8] {
        let (lr, lg, lb) = (0.2126 * (1 - s), 0.7152 * (1 - s), 0.0722 * (1 - s))
        func channel(_ value: Double) -> UInt8 { UInt8(min(max(value.rounded(), 0), 255)) }
        var result = rgba
        var i = 0
        while i + 3 < rgba.count {
            let (r, g, b) = (Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]))
            result[i] = channel(k * ((lr + s) * r + lg * g + lb * b))
            result[i + 1] = channel(k * (lr * r + (lg + s) * g + lb * b))
            result[i + 2] = channel(k * (lr * r + lg * g + (lb + s) * b))
            i += 4
        }
        return result
    }

    // MARK: - Внутреннее

    private static func valid(_ rgba: [UInt8], _ width: Int, _ height: Int, _ stride: Int) -> Bool {
        width > 0 && height > 0 && stride >= width * 4 && rgba.count >= stride * (height - 1) + width * 4
    }

    static func sampleSize(_ width: Int, _ height: Int) -> (columns: Int, rows: Int) {
        let rows = Int((Double(sampleColumns * height) / Double(width)).rounded())
        return (sampleColumns, min(max(rows, 1), sampleColumns * 2))
    }

    /// Размытие «коробкой» 5 × 5, края — повтор крайнего пикселя.
    private static func boxBlur(_ source: [Double], side: Int) -> [Double] {
        var result = source
        for y in 0..<side {
            for x in 0..<side {
                var sum = (0.0, 0.0, 0.0)
                for dy in -2...2 {
                    for dx in -2...2 {
                        let sx = min(max(x + dx, 0), side - 1), sy = min(max(y + dy, 0), side - 1)
                        let i = (sy * side + sx) * 3
                        sum.0 += source[i]
                        sum.1 += source[i + 1]
                        sum.2 += source[i + 2]
                    }
                }
                let o = (y * side + x) * 3
                result[o] = sum.0 / 25
                result[o + 1] = sum.1 / 25
                result[o + 2] = sum.2 / 25
            }
        }
        return result
    }

    /// CIE Lab (D65) по sRGB — как `to_lab`/`from_lab` в `artwork_colors.rs`.
    struct Lab {
        var l, a, b: Double

        init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }

        init(_ rgb: UInt32) {
            func channel(_ shift: UInt32) -> Double {
                let c = Double((rgb >> shift) & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let (r, g, bl) = (channel(16), channel(8), channel(0))
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
            func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
            let (fx, fy, fz) = (f(x), f(y), f(z))
            l = 116 * fy - 16
            a = 500 * (fx - fy)
            b = 200 * (fy - fz)
        }

        var rgb: UInt32 {
            let fy = (l + 16) / 116
            let (fx, fz) = (fy + a / 500, fy - b / 200)
            func inverse(_ t: Double) -> Double { t * t * t > 216.0 / 24389.0 ? t * t * t : (116 * t - 16) / (24389.0 / 27.0) }
            let (x, y, z) = (inverse(fx) * 0.95047, inverse(fy), inverse(fz) * 1.08883)
            let linear = (3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z,
                          0.0557 * x - 0.2040 * y + 1.0570 * z)
            func gamma(_ value: Double) -> UInt32 {
                let c = min(max(value, 0), 1)
                let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
                return UInt32((v * 255).rounded())
            }
            return gamma(linear.0) << 16 | gamma(linear.1) << 8 | gamma(linear.2)
        }

        func distance(to other: Lab) -> Double {
            ((l - other.l) * (l - other.l) + (a - other.a) * (a - other.a) + (b - other.b) * (b - other.b)).squareRoot()
        }
    }
}

/// Размытая обложка фона «Сейчас играет» (задание 0030): `rgba` — 24 × 24 RGBA строками подряд, средняя яркость 0…1
/// (Rec. 709) и подложка `0xRRGGBB` — `darkBackdrop` преобладающего цвета.
public struct BackdropPreview: Equatable, Sendable {
    public let rgba: [UInt8]
    public let luma: Double
    public let base: UInt32
}

/// Всё, что нужно фону «Сейчас играет» от одной обложки; считается один раз на обложку, не в потоке интерфейса.
public struct BackdropCover: Sendable {
    /// Размытая обложка, яркость и подложка (задание 0030).
    public let preview: BackdropPreview
    /// Та же размытая обложка с матрицей цвета — слои запасного фона, когда живого нет.
    public let tinted: [UInt8]
    /// Обложка 256 × 256 RGBA для шейдера (задание 0031).
    public let shaderTexture: [UInt8]
    /// Цвета по долям, преобладающий первым — капли живого фона.
    public let shares: [ColorShare]

    public var luma: Double { preview.luma }
    public var base: UInt32 { preview.base }

    /// `nil` — картинка пустая или кривая.
    public static func prepare(rgba: [UInt8], width: Int, height: Int, stride: Int) -> BackdropCover? {
        let shares = ArtworkColors.shares(rgba: rgba, width: width, height: height, stride: stride)
        guard let preview = ArtworkColors.backdropPreview(rgba: rgba, width: width, height: height, stride: stride, shares: shares),
              let texture = ArtworkColors.shaderTexture(rgba: rgba, width: width, height: height, stride: stride) else { return nil }
        let tinted = ArtworkColors.applyColorMatrix(preview.rgba, brightness: ArtworkColors.brightness(luma: preview.luma),
                                                    saturation: ArtworkColors.saturation)
        return BackdropCover(preview: preview, tinted: tinted, shaderTexture: texture, shares: shares)
    }
}
