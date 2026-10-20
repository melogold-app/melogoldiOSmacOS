import Foundation

/// Квантование цветов картинки, как `QuantizerCelebi` из Material color utilities: Wu даёт начальные центры, взвешенный
/// k-means в CIE Lab (`QuantizerWsmeans`) их уточняет. Перенос один в один с крейта `material-colors` 0.4.2, которым
/// пользуется Linux (`artwork_colors::shares`, задание 0030): все платформы считают цвета обложки по долям одинаково, и
/// у Apple своей копии Material color utilities не было. Цвет — `0xAARRGGBB`.
enum QuantizerCelebi {
    /// Цвета и число пикселей у каждого, не больше `maxColors`.
    static func quantize(_ pixels: [UInt32], maxColors: Int) -> [(argb: UInt32, count: Int)] {
        let starting = QuantizerWu.quantize(pixels, maxColors: maxColors)
        return QuantizerWsmeans.quantize(pixels, maxColors: maxColors, startingClusters: starting)
    }

    /// Каждый цвет и сколько раз он встретился — в порядке первого появления (`QuantizerMap`).
    static func histogram(_ pixels: [UInt32]) -> [(argb: UInt32, count: Int)] {
        var position: [UInt32: Int] = [:]
        var result: [(argb: UInt32, count: Int)] = []
        for pixel in pixels {
            if let index = position[pixel] {
                result[index].count += 1
            } else {
                position[pixel] = result.count
                result.append((pixel, 1))
            }
        }
        return result
    }
}

// MARK: - Wu

/// Квантователь Wu (Xiaolin Wu, Graphics Gems II): гистограмма 32 × 32 × 32 по старшим пяти битам каналов, куб делится
/// там, где дисперсия падает сильнее всего.
enum QuantizerWu {
    private static let indexBits = 5
    private static let side = (1 << indexBits) + 1
    private static let totalSize = side * side * side

    private struct Cube {
        var r0 = 0, r1 = 0, g0 = 0, g1 = 0, b0 = 0, b1 = 0
        var volume = 0
    }

    private enum Direction { case red, green, blue }

    private struct Moments {
        var weights = [Int64](repeating: 0, count: QuantizerWu.totalSize)
        var red = [Int64](repeating: 0, count: QuantizerWu.totalSize)
        var green = [Int64](repeating: 0, count: QuantizerWu.totalSize)
        var blue = [Int64](repeating: 0, count: QuantizerWu.totalSize)
        var squares = [Double](repeating: 0, count: QuantizerWu.totalSize)
    }

    /// Центры кубов: цвета без числа пикселей, в порядке кубов.
    static func quantize(_ pixels: [UInt32], maxColors: Int) -> [UInt32] {
        guard maxColors > 0 else { return [] }
        // Как в крейте: гистограмма по возрастанию числа пикселей (сортировка устойчивая)
        let histogram = QuantizerCelebi.histogram(pixels).enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count < $1.element.count : $0.offset < $1.offset }
            .map(\.element)
        var moments = Moments()
        for (pixel, count) in histogram {
            let red = Int((pixel >> 16) & 0xFF), green = Int((pixel >> 8) & 0xFF), blue = Int(pixel & 0xFF)
            let shift = 8 - indexBits
            let index = Self.index((red >> shift) + 1, (green >> shift) + 1, (blue >> shift) + 1)
            let n = Int64(count)
            moments.weights[index] += n
            moments.red[index] += Int64(red) * n
            moments.green[index] += Int64(green) * n
            moments.blue[index] += Int64(blue) * n
            let (r, g, b) = (Double(red), Double(green), Double(blue))
            moments.squares[index] += Double(count) * (g * g).addingProduct(r, r).addingProduct(b, b)
        }
        computeMoments(&moments)

        var cubes = [Cube](repeating: Cube(), count: maxColors)
        cubes[0] = Cube(r0: 0, r1: side - 1, g0: 0, g1: side - 1, b0: 0, b1: side - 1, volume: 0)
        var variances = [Double](repeating: 0, count: maxColors)
        var next = 0
        var generated = maxColors
        var i = 1
        while i < maxColors {
            if cut(&cubes, next, i, moments) {
                variances[next] = cubes[next].volume > 1 ? variance(cubes[next], moments) : 0
                variances[i] = cubes[i].volume > 1 ? variance(cubes[i], moments) : 0
            } else {
                variances[next] = 0
                i -= 1
            }
            next = 0
            var largest = variances[0]
            var j = 1
            while j <= i {
                if variances[j] > largest {
                    largest = variances[j]
                    next = j
                }
                j += 1
            }
            if largest <= 0 {
                generated = i + 1
                break
            }
            i += 1
        }

        var colors: [UInt32] = []
        for cube in cubes.prefix(generated) {
            let weight = volume(cube, moments.weights)
            guard weight > 0 else { continue }
            let r = UInt32(truncatingIfNeeded: volume(cube, moments.red) / weight) & 0xFF
            let g = UInt32(truncatingIfNeeded: volume(cube, moments.green) / weight) & 0xFF
            let b = UInt32(truncatingIfNeeded: volume(cube, moments.blue) / weight) & 0xFF
            let color = 0xFF00_0000 | (r << 16) | (g << 8) | b
            if !colors.contains(color) { colors.append(color) }
        }
        return colors
    }

    private static func index(_ r: Int, _ g: Int, _ b: Int) -> Int {
        (r << (indexBits * 2)) + (r << (indexBits + 1)) + (g << indexBits) + r + g + b
    }

    private static func computeMoments(_ m: inout Moments) {
        for r in 1..<side {
            var area = [Int64](repeating: 0, count: side)
            var areaR = [Int64](repeating: 0, count: side)
            var areaG = [Int64](repeating: 0, count: side)
            var areaB = [Int64](repeating: 0, count: side)
            var area2 = [Double](repeating: 0, count: side)
            for g in 1..<side {
                var line: Int64 = 0, lineR: Int64 = 0, lineG: Int64 = 0, lineB: Int64 = 0
                var line2 = 0.0
                for b in 1..<side {
                    let index = index(r, g, b)
                    line += m.weights[index]
                    lineR += m.red[index]
                    lineG += m.green[index]
                    lineB += m.blue[index]
                    line2 += m.squares[index]
                    area[b] += line
                    areaR[b] += lineR
                    areaG[b] += lineG
                    areaB[b] += lineB
                    area2[b] += line2
                    let previous = Self.index(r - 1, g, b)
                    m.weights[index] = m.weights[previous] + area[b]
                    m.red[index] = m.red[previous] + areaR[b]
                    m.green[index] = m.green[previous] + areaG[b]
                    m.blue[index] = m.blue[previous] + areaB[b]
                    m.squares[index] = m.squares[previous] + area2[b]
                }
            }
        }
    }

    private static func cut(_ cubes: inout [Cube], _ next: Int, _ i: Int, _ m: Moments) -> Bool {
        var one = cubes[next]
        var two = cubes[i]
        let wholeR = volume(one, m.red), wholeG = volume(one, m.green)
        let wholeB = volume(one, m.blue), wholeW = volume(one, m.weights)
        let whole = (wholeR, wholeG, wholeB, wholeW)
        let maxR = maximize(one, .red, one.r0 + 1, one.r1, whole, m)
        let maxG = maximize(one, .green, one.g0 + 1, one.g1, whole, m)
        let maxB = maximize(one, .blue, one.b0 + 1, one.b1, whole, m)
        let direction: Direction
        if maxR.maximum >= maxG.maximum, maxR.maximum >= maxB.maximum {
            guard maxR.cut >= 0 else { return false }
            direction = .red
        } else if maxG.maximum >= maxR.maximum, maxG.maximum >= maxB.maximum {
            direction = .green
        } else {
            direction = .blue
        }
        two.r1 = one.r1
        two.g1 = one.g1
        two.b1 = one.b1
        switch direction {
        case .red:
            one.r1 = maxR.cut
            two.r0 = one.r1
            two.g0 = one.g0
            two.b0 = one.b0
        case .green:
            one.g1 = maxG.cut
            two.r0 = one.r0
            two.g0 = one.g1
            two.b0 = one.b0
        case .blue:
            one.b1 = maxB.cut
            two.r0 = one.r0
            two.g0 = one.g0
            two.b0 = one.b1
        }
        one.volume = (one.r1 - one.r0) * (one.g1 - one.g0) * (one.b1 - one.b0)
        two.volume = (two.r1 - two.r0) * (two.g1 - two.g0) * (two.b1 - two.b0)
        cubes[next] = one
        cubes[i] = two
        return true
    }

    private static func maximize(_ cube: Cube, _ direction: Direction, _ first: Int, _ last: Int,
                                 _ whole: (r: Int64, g: Int64, b: Int64, w: Int64), _ m: Moments) -> (cut: Int, maximum: Double) {
        let bottomR = Double(bottom(cube, direction, m.red)), bottomG = Double(bottom(cube, direction, m.green))
        let bottomB = Double(bottom(cube, direction, m.blue)), bottomW = Double(bottom(cube, direction, m.weights))
        var maximum = 0.0
        var cut = -1
        var position = first
        while position < last {
            var halfR = bottomR + Double(top(cube, direction, position, m.red))
            var halfG = bottomG + Double(top(cube, direction, position, m.green))
            var halfB = bottomB + Double(top(cube, direction, position, m.blue))
            var halfW = bottomW + Double(top(cube, direction, position, m.weights))
            defer { position += 1 }
            if halfW == 0 { continue }
            var temp = (halfG * halfG).addingProduct(halfR, halfR).addingProduct(halfB, halfB) / halfW
            halfR = Double(whole.r) - halfR
            halfG = Double(whole.g) - halfG
            halfB = Double(whole.b) - halfB
            halfW = Double(whole.w) - halfW
            if halfW == 0 { continue }
            temp += (halfG * halfG).addingProduct(halfR, halfR).addingProduct(halfB, halfB) / halfW
            if temp > maximum {
                maximum = temp
                cut = position
            }
        }
        return (cut, maximum)
    }

    private static func variance(_ cube: Cube, _ m: Moments) -> Double {
        let dr = Double(volume(cube, m.red)), dg = Double(volume(cube, m.green)), db = Double(volume(cube, m.blue))
        let xx = m.squares[index(cube.r1, cube.g1, cube.b1)]
            - m.squares[index(cube.r1, cube.g1, cube.b0)]
            - m.squares[index(cube.r1, cube.g0, cube.b1)]
            + m.squares[index(cube.r1, cube.g0, cube.b0)]
            - m.squares[index(cube.r0, cube.g1, cube.b1)]
            + m.squares[index(cube.r0, cube.g1, cube.b0)]
            + m.squares[index(cube.r0, cube.g0, cube.b1)]
            - m.squares[index(cube.r0, cube.g0, cube.b0)]
        let hypotenuse = (dg * dg).addingProduct(dr, dr).addingProduct(db, db)
        return xx - hypotenuse / Double(volume(cube, m.weights))
    }

    private static func volume(_ cube: Cube, _ moment: [Int64]) -> Int64 {
        moment[index(cube.r1, cube.g1, cube.b1)]
            - moment[index(cube.r1, cube.g1, cube.b0)]
            - moment[index(cube.r1, cube.g0, cube.b1)]
            + moment[index(cube.r1, cube.g0, cube.b0)]
            - moment[index(cube.r0, cube.g1, cube.b1)]
            + moment[index(cube.r0, cube.g1, cube.b0)]
            + moment[index(cube.r0, cube.g0, cube.b1)]
            - moment[index(cube.r0, cube.g0, cube.b0)]
    }

    private static func bottom(_ cube: Cube, _ direction: Direction, _ moment: [Int64]) -> Int64 {
        switch direction {
        case .red:
            -moment[index(cube.r0, cube.g1, cube.b1)]
                + moment[index(cube.r0, cube.g1, cube.b0)]
                + moment[index(cube.r0, cube.g0, cube.b1)]
                - moment[index(cube.r0, cube.g0, cube.b0)]
        case .green:
            -moment[index(cube.r1, cube.g0, cube.b1)]
                + moment[index(cube.r1, cube.g0, cube.b0)]
                + moment[index(cube.r0, cube.g0, cube.b1)]
                - moment[index(cube.r0, cube.g0, cube.b0)]
        case .blue:
            -moment[index(cube.r1, cube.g1, cube.b0)]
                + moment[index(cube.r1, cube.g0, cube.b0)]
                + moment[index(cube.r0, cube.g1, cube.b0)]
                - moment[index(cube.r0, cube.g0, cube.b0)]
        }
    }

    private static func top(_ cube: Cube, _ direction: Direction, _ position: Int, _ moment: [Int64]) -> Int64 {
        switch direction {
        case .red:
            moment[index(position, cube.g1, cube.b1)]
                - moment[index(position, cube.g1, cube.b0)]
                - moment[index(position, cube.g0, cube.b1)]
                + moment[index(position, cube.g0, cube.b0)]
        case .green:
            moment[index(cube.r1, position, cube.b1)]
                - moment[index(cube.r1, position, cube.b0)]
                - moment[index(cube.r0, position, cube.b1)]
                + moment[index(cube.r0, position, cube.b0)]
        case .blue:
            moment[index(cube.r1, cube.g1, position)]
                - moment[index(cube.r1, cube.g0, position)]
                - moment[index(cube.r0, cube.g1, position)]
                + moment[index(cube.r0, cube.g0, position)]
        }
    }
}

// MARK: - Wsmeans

/// Взвешенный k-means в CIE Lab, до десяти проходов; центры — от Wu. Сравнение расстояний и порядок строк матрицы
/// расстояний — как в Material color utilities (и с его особенностью: после сортировки строки порог сравнивается по
/// позиции, а не по номеру центра) — иначе цвета расходились бы с Linux.
enum QuantizerWsmeans {
    static func quantize(_ input: [UInt32], maxColors: Int, startingClusters: [UInt32]) -> [(argb: UInt32, count: Int)] {
        let histogram = QuantizerCelebi.histogram(input)
        let points = histogram.map { MaterialLab($0.argb) }
        let counts = histogram.map(\.count)
        let clusterCount = min(maxColors, points.count)
        guard clusterCount > 0 else { return [] }

        var clusters = startingClusters.prefix(clusterCount).map { MaterialLab($0) }
        let additional = clusterCount - clusters.count
        if additional > 0 {
            // Недостающие центры — настоящие точки картинки, выбранные тем же генератором с тем же зерном
            var random = JavaRandom(seed: 0x42688)
            var indices: [Int] = []
            for _ in 0..<additional {
                var index = Int(random.next(below: Int32(points.count)))
                while indices.contains(index) { index = Int(random.next(below: Int32(points.count))) }
                indices.append(index)
            }
            clusters.append(contentsOf: indices.map { points[$0] })
        }

        var assignment = points.indices.map { $0 % clusterCount }
        // Строка i — расстояния от центра i и номера центров; после сортировки строки порядок позиций меняется
        var distances = [Double](repeating: 0, count: clusterCount * clusterCount)
        var owners = [Int](repeating: 0, count: clusterCount * clusterCount)
        for row in 0..<clusterCount {
            for column in 0..<clusterCount { owners[row * clusterCount + column] = column }
        }
        var populations = [Int](repeating: 0, count: clusterCount)

        for iteration in 0..<10 {
            for i in 0..<clusterCount {
                for j in (i + 1)..<clusterCount {
                    let distance = clusters[i].distance(to: clusters[j])
                    distances[j * clusterCount + i] = distance
                    owners[j * clusterCount + i] = i
                    distances[i * clusterCount + j] = distance
                    owners[i * clusterCount + j] = j
                }
                // Устойчивая сортировка строки по расстоянию
                let row = i * clusterCount
                let sorted = (0..<clusterCount).map { (distances[row + $0], owners[row + $0], $0) }
                    .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.2 < $1.2 }
                for (position, entry) in sorted.enumerated() {
                    distances[row + position] = entry.0
                    owners[row + position] = entry.1
                }
            }

            var moved = 0
            for (i, point) in points.enumerated() {
                let previousIndex = assignment[i]
                let previousDistance = point.distance(to: clusters[previousIndex])
                var minimum = previousDistance
                var newIndex: Int?
                for j in 0..<clusterCount {
                    if distances[previousIndex * clusterCount + j] >= 4 * previousDistance { continue }
                    let distance = point.distance(to: clusters[j])
                    if distance < minimum {
                        minimum = distance
                        newIndex = j
                    }
                }
                if let newIndex {
                    moved += 1
                    assignment[i] = newIndex
                }
            }
            if moved == 0, iteration > 0 { break }

            var sumL = [Double](repeating: 0, count: clusterCount)
            var sumA = [Double](repeating: 0, count: clusterCount)
            var sumB = [Double](repeating: 0, count: clusterCount)
            populations = [Int](repeating: 0, count: clusterCount)
            for (i, point) in points.enumerated() {
                let cluster = assignment[i]
                let count = counts[i]
                populations[cluster] += count
                sumL[cluster] += point.l * Double(count)
                sumA[cluster] += point.a * Double(count)
                sumB[cluster] += point.b * Double(count)
            }
            for i in 0..<clusterCount {
                let count = Double(populations[i])
                clusters[i] = populations[i] == 0
                    ? MaterialLab(l: 0, a: 0, b: 0)
                    : MaterialLab(l: sumL[i] / count, a: sumA[i] / count, b: sumB[i] / count)
            }
        }

        var result: [(argb: UInt32, count: Int)] = []
        for i in 0..<clusterCount where populations[i] > 0 {
            let argb = clusters[i].argb
            guard !result.contains(where: { $0.argb == argb }) else { continue }
            result.append((argb, populations[i]))
        }
        return result
    }
}

/// CIE Lab в варианте Material color utilities (`PointProviderLab`): белая точка D65 × 100, свои матрицы sRGB ↔ XYZ.
/// Отличается от `ArtworkColors` (там Lab для слияния цветов по долям, как в `artwork_colors.rs`) — у каждого своё, как
/// на Linux.
struct MaterialLab: Equatable {
    var l, a, b: Double

    private static let whitePoint = (95.047, 100.0, 108.883)
    private static let e = 216.0 / 24389.0
    private static let kappa = 24389.0 / 27.0

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(_ argb: UInt32) {
        let r = Self.linearized(UInt8((argb >> 16) & 0xFF))
        let g = Self.linearized(UInt8((argb >> 8) & 0xFF))
        let b = Self.linearized(UInt8(argb & 0xFF))
        let x = (0.35762064 * g).addingProduct(0.41233895, r).addingProduct(0.18051042, b)
        let y = (0.7152 * g).addingProduct(0.2126, r).addingProduct(0.0722, b)
        let z = (0.11916382 * g).addingProduct(0.01932141, r).addingProduct(0.95034478, b)
        let fx = Self.labF(x / Self.whitePoint.0), fy = Self.labF(y / Self.whitePoint.1), fz = Self.labF(z / Self.whitePoint.2)
        l = (-16.0).addingProduct(116.0, fy)
        a = 500 * (fx - fy)
        self.b = 200 * (fy - fz)
    }

    var argb: UInt32 {
        let fy = (l + 16) / 116
        let fx = a / 500 + fy
        let fz = fy - b / 200
        let x = Self.labInvF(fx) * Self.whitePoint.0
        let y = Self.labInvF(fy) * Self.whitePoint.1
        let z = Self.labInvF(fz) * Self.whitePoint.2
        let r = (-1.5376652402851851 * y).addingProduct(3.2413774792388685, x).addingProduct(-0.49885366846268053, z)
        let g = (1.8758853451067872 * y).addingProduct(-0.9691452513005321, x).addingProduct(0.04156585616912061, z)
        let bl = (-0.20395524564742123 * y).addingProduct(0.05562093689691305, x).addingProduct(1.0571799111220335, z)
        return 0xFF00_0000 | (Self.delinearized(r) << 16) | (Self.delinearized(g) << 8) | Self.delinearized(bl)
    }

    /// Квадрат ΔE76: для сравнения расстояний корень не нужен.
    func distance(to other: MaterialLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (da * da).addingProduct(dl, dl).addingProduct(db, db)
    }

    private static func linearized(_ component: UInt8) -> Double {
        let normalized = Double(component) / 255
        return normalized <= 0.040449936 ? normalized / 12.92 * 100 : pow((normalized + 0.055) / 1.055, 2.4) * 100
    }

    private static func delinearized(_ component: Double) -> UInt32 {
        let normalized = component / 100
        let value = normalized <= 0.0031308 ? normalized * 12.92 : (-0.055).addingProduct(1.055, pow(normalized, 1 / 2.4))
        let scaled = (value * 255).rounded()
        return scaled.isNaN ? 0 : UInt32(min(max(scaled, 0), 255))
    }

    private static func labF(_ t: Double) -> Double {
        t > e ? cbrt(t) : 16.0.addingProduct(kappa, t) / 116
    }

    private static func labInvF(_ ft: Double) -> Double {
        let ft3 = ft * ft * ft
        return ft3 > e ? ft3 : (-16.0).addingProduct(116.0, ft) / kappa
    }
}

/// Генератор `java.util.Random` (48-битный LCG) с особенностью переноса в крейте `material-colors`: зерно и
/// последовательность те же, что у Linux, — недостающие центры k-means выбираются одинаково.
struct JavaRandom {
    private var state: Int64

    init(seed: Int64) {
        state = (seed ^ 0x5DEE_CE66D) & ((1 << 48) - 1)
    }

    private mutating func next(bits: Int64) -> Int32 {
        state = (state &* 0x5DEE_CE66D &+ 0xB) & ((1 << 48) - 1)
        return Int32(truncatingIfNeeded: UInt64(bitPattern: state) >> UInt64(48 - bits))
    }

    mutating func next(below range: Int32) -> Int32 {
        if range & -range == range {
            return Int32(truncatingIfNeeded: (Int64(range) &* Int64(next(bits: 31))) >> 31)
        }
        var value: Int32
        repeat {
            let bits = next(bits: 31)
            value = bits % range
            // Как в крейте: `!bits - val + (range - 1) < 0` — выход почти всегда с первого раза
            if (~bits &- value &+ (range &- 1)) < 0 { break }
        } while true
        return value
    }
}
