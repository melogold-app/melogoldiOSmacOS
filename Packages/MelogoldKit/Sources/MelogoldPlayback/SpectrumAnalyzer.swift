import Accelerate
import Foundation
import MelogoldCore

/// Одно измерение спектра для живого фона «Сейчас играет»: 48 полос 0…1 и время звука — середина окна на шкале
/// синхронизатора (как у кадров уровней `LevelFrame`).
public struct SpectrumFrame: Sendable {
    public let time: Double
    public let bands: [Float]
}

/// Спектр для живого фона «Сейчас играет» (задание 0031, §2) — перенос Linux `melogold-playback` `spectrum.rs`: моно,
/// окно Хэмминга, БПФ 2048 с шагом 512 (vDSP), мощность бина `(re² + im²) / N²` в дБ, 48 полос от 30 Гц до 16 кГц по
/// логарифму, наклон +3 дБ на октаву. Числа общие для всех платформ.
///
/// Сэмплы — те же, что идут на столбики «играет» (`LevelAnalyzer`, до регулятора громкости): второй раз звук не
/// декодируется. Каждое измерение помечено временем звука: «Сейчас играет» рисует то, что звучит сейчас (по часам
/// синхронизатора), а не то, что только что прочитано, — иначе картинка опережала бы звук на запас чтения.
///
/// Считается в чтении фрагмента, до того как его звук уйдёт в рендерер: ~860 окон на фрагмент в 10 с. Поэтому всё над
/// массивами — vDSP, без поэлементных циклов Swift: циклом по сэмплу отладочная сборка тратила на фрагмент около секунды,
/// и трек начинал играть заметно позже.
final class SpectrumAnalyzer {
    static let size = 2048
    static let hop = 512

    /// Последние сэмплы после сброса (не больше `size − 1` между вызовами) и новые — подряд: окно — отрезок без копирования
    /// по кругу.
    private var history: [Float] = []
    /// Сэмплов после сброса (до `size`) и после последнего измерения.
    private var filled = 0
    private var sinceHop = 0
    private let transform = Transform()

    /// Перемотка: прежние сэмплы не относятся к новому месту, окно копится заново.
    func reset() {
        history.removeAll(keepingCapacity: true)
        filled = 0
        sinceHop = 0
    }

    /// Моно-сэмплы `mono`; `start` — время первого из них на шкале синхронизатора, `rate` — частота дискретизации.
    /// Измерение — после каждого сэмпла, на котором окно полно и с прошлого измерения прошло `hop` сэмплов.
    func feed(_ mono: UnsafeBufferPointer<Float>, start: Double, rate: Double) -> [SpectrumFrame] {
        guard rate > 0, let transform, !mono.isEmpty else { return [] }
        let carried = history.count
        history.append(contentsOf: mono)
        let count = mono.count
        var frames: [SpectrumFrame] = []
        // Первое измерение — на сэмпле, где окно впервые полно и шаг набран; дальше — каждые `hop`
        var index = max(Self.size - filled, Self.hop - sinceHop, 1) - 1
        var last: Int?
        history.withUnsafeBufferPointer { all in
            while index < count {
                let end = carried + index + 1
                let window = UnsafeBufferPointer(rebasing: all[(end - Self.size)..<end])
                // Время окна — его середина
                let time = start + (Double(index) - Double(Self.size) / 2) / rate
                frames.append(SpectrumFrame(time: time, bands: transform.bands(of: window, rate: rate)))
                last = index
                index += Self.hop
            }
        }
        filled = min(filled + count, Self.size)
        sinceHop = last.map { count - 1 - $0 } ?? sinceHop + count
        // Для следующего вызова нужны только последние `size − 1` сэмплов
        if history.count >= Self.size { history.removeFirst(history.count - (Self.size - 1)) }
        return frames
    }

    /// Полосы одного окна (`size` сэмплов моно) — значения 0…1 по §2 задания 0031. Для проверок.
    static func bands(of samples: [Float], rate: Double) -> [Float] {
        var window = Array(samples.prefix(size))
        window += [Float](repeating: 0, count: size - window.count)
        return window.withUnsafeBufferPointer { Transform()?.bands(of: $0, rate: rate) } ?? []
    }

    /// БПФ и полосы с заготовленными буферами.
    private final class Transform {
        private let dft: vDSP.DiscreteFourierTransform<Float>
        private let hamming: [Float]
        private var real = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        /// Мнимая часть входа — всегда нули: преобразование её не меняет.
        private let imaginary = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var outReal = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var outImaginary = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var power = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
        /// Квадраты действительной части — промежуточный буфер мощности.
        private var squares = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
        /// Бины каждой полосы и наклон +3 дБ на октаву — для частоты `bandsRate`; меняются только с частотой.
        private var bandBins: [(range: Range<Int>, tilt: Float)] = []
        private var bandsRate = 0.0

        init?() {
            let n = SpectrumAnalyzer.size
            guard let dft = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex,
                                                               ofType: Float.self) else { return nil }
            self.dft = dft
            // Окно Хэмминга с N − 1 в знаменателе, как у Linux (у `vDSP_hamm_window` — N)
            hamming = (0..<n).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
        }

        /// Полоса `b` — бины `[30·(16000/30)^(b/48), 30·(16000/30)^((b+1)/48))`, хотя бы один.
        private func bins(rate: Double) -> [(range: Range<Int>, tilt: Float)] {
            if bandsRate != rate {
                let bin = Float(rate) / Float(SpectrumAnalyzer.size)
                let count = FluidAnalysis.bandCount
                bandBins = (0..<count).map { band in
                    let lo = 30 * pow(Float(16000.0 / 30.0), Float(band) / Float(count))
                    let hi = 30 * pow(Float(16000.0 / 30.0), Float(band + 1) / Float(count))
                    let from = min(Int(lo / bin), power.count - 1)
                    let to = min(max(Int(hi / bin), from + 1), power.count)
                    return (from..<to, 3 * log2(lo / 30))
                }
                bandsRate = rate
            }
            return bandBins
        }

        func bands(of samples: UnsafeBufferPointer<Float>, rate: Double) -> [Float] {
            vDSP.multiply(samples, hamming, result: &real)
            dft.transform(inputReal: real, inputImaginary: imaginary, outputReal: &outReal, outputImaginary: &outImaginary)
            // P = (re² + im²) / N² для первой половины бинов
            let half = 0..<(SpectrumAnalyzer.size / 2)
            vDSP.multiply(outReal[half], outReal[half], result: &squares)
            vDSP.add(multiplication: (outImaginary[half], outImaginary[half]), squares, result: &power)
            let norm = Float(SpectrumAnalyzer.size * SpectrumAnalyzer.size)
            return bins(rate: rate).map { band in
                // Мощность полосы — среднее линейной мощности её бинов
                let mean = vDSP.mean(power[band.range]) / norm
                return min(max((10 * log10(max(mean, 1e-12)) + band.tilt + 70) / 55, 0), 1)
            }
        }
    }
}
