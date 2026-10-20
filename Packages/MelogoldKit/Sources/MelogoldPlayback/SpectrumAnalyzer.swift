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
final class SpectrumAnalyzer {
    static let size = 2048
    static let hop = 512

    private var ring = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var head = 0
    private var filled = 0
    private var sinceHop = 0
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private let transform = Transform()

    /// Перемотка: прежние сэмплы не относятся к новому месту, окно копится заново.
    func reset() {
        filled = 0
        sinceHop = 0
    }

    /// Моно-сэмплы `mono`; `start` — время первого из них на шкале синхронизатора, `rate` — частота дискретизации.
    func feed(_ mono: UnsafeBufferPointer<Float>, start: Double, rate: Double) -> [SpectrumFrame] {
        guard rate > 0, let transform else { return [] }
        var frames: [SpectrumFrame] = []
        for (index, sample) in mono.enumerated() {
            ring[head] = sample
            head = (head + 1) % Self.size
            filled = min(filled + 1, Self.size)
            sinceHop += 1
            guard filled == Self.size, sinceHop >= Self.hop else { continue }
            sinceHop = 0
            for i in 0..<Self.size { window[i] = ring[(head + i) % Self.size] }
            // Время окна — его середина
            let time = start + (Double(index) - Double(Self.size) / 2) / rate
            frames.append(SpectrumFrame(time: time, bands: transform.bands(of: window, rate: rate)))
        }
        return frames
    }

    /// Полосы одного окна (`size` сэмплов моно) — значения 0…1 по §2 задания 0031. Для проверок.
    static func bands(of samples: [Float], rate: Double) -> [Float] {
        Transform()?.bands(of: samples, rate: rate) ?? []
    }

    /// БПФ и полосы с заготовленными буферами: измерений — по 86 в секунду звука.
    private final class Transform {
        private let dft: vDSP.DiscreteFourierTransform<Float>
        private let hamming: [Float]
        private var real = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var imaginary = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var outReal = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var outImaginary = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        private var power = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)

        init?() {
            let n = SpectrumAnalyzer.size
            guard let dft = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex,
                                                               ofType: Float.self) else { return nil }
            self.dft = dft
            // Окно Хэмминга с N − 1 в знаменателе, как у Linux (у `vDSP_hamm_window` — N)
            hamming = (0..<n).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
        }

        func bands(of samples: [Float], rate: Double) -> [Float] {
            let n = SpectrumAnalyzer.size
            for i in 0..<n { real[i] = i < samples.count ? samples[i] * hamming[i] : 0 }
            for i in 0..<n { imaginary[i] = 0 }
            dft.transform(inputReal: real, inputImaginary: imaginary, outputReal: &outReal, outputImaginary: &outImaginary)
            let norm = Float(n * n)
            for i in 0..<(n / 2) { power[i] = (outReal[i] * outReal[i] + outImaginary[i] * outImaginary[i]) / norm }
            let bin = Float(rate) / Float(n)
            let count = FluidAnalysis.bandCount
            return (0..<count).map { band in
                let lo = 30 * pow(Float(16000.0 / 30.0), Float(band) / Float(count))
                let hi = 30 * pow(Float(16000.0 / 30.0), Float(band + 1) / Float(count))
                let from = min(Int(lo / bin), power.count - 1)
                let to = min(max(Int(hi / bin), from + 1), power.count)
                let mean = power[from..<to].reduce(0, +) / Float(to - from)
                let tilt = 3 * log2(lo / 30)
                return min(max((10 * log10(max(mean, 1e-12)) + tilt + 70) / 55, 0), 1)
            }
        }
    }
}
