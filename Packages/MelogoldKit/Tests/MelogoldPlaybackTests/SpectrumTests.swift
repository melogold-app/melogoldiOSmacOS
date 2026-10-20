import Foundation
import Testing
import MelogoldCore
@testable import MelogoldPlayback

/// Спектр живого фона «Сейчас играет» (задание 0031, §2): те же проверки, что у Linux `spectrum.rs`.
@Suite("Спектр живого фона")
struct SpectrumTests {
    private func band(of frequency: Float) -> Int {
        (0..<FluidAnalysis.bandCount).first { band in
            frequency < 30 * pow(Float(16000.0 / 30.0), Float(band + 1) / Float(FluidAnalysis.bandCount))
        } ?? FluidAnalysis.bandCount - 1
    }

    private func tone(_ frequency: Float, rate: Float, count: Int, amplitude: Float = 0.02) -> [Float] {
        (0..<count).map { amplitude * sin(2 * Float.pi * frequency * Float($0) / rate) }
    }

    private func loudest(_ bands: [Float]) -> Int {
        bands.indices.max { bands[$0] < bands[$1] } ?? -1
    }

    /// Синус 1 кГц — громче всего его полоса (окно растекается на соседний бин, тон может делиться с соседней полосой).
    @Test func toneLightsItsOwnBand() {
        let bands = SpectrumAnalyzer.bands(of: tone(1000, rate: 48_000, count: SpectrumAnalyzer.size), rate: 48_000)
        #expect(bands.count == 48)
        let top = loudest(bands)
        #expect((band(of: 1000)...band(of: 1000) + 1).contains(top), "\(top): \(bands)")
        #expect(bands[top] > 0.3, "\(bands)")
    }

    @Test func silenceIsZero() {
        let bands = SpectrumAnalyzer.bands(of: [Float](repeating: 0, count: SpectrumAnalyzer.size), rate: 44_100)
        #expect(bands.count == 48 && bands.allSatisfy { $0 == 0 })
    }

    /// Измерения идут с шагом 512 сэмплов и помечены серединой окна на шкале звука.
    @Test func framesFollowTheAudioTime() throws {
        let analyzer = SpectrumAnalyzer()
        let rate = 44_100.0
        let second = tone(200, rate: Float(rate), count: Int(rate))
        let frames = second.withUnsafeBufferPointer { analyzer.feed($0, start: 10, rate: rate) }
        // Первое окно — после 2048 сэмплов, дальше каждые 512
        #expect(frames.count == (Int(rate) - SpectrumAnalyzer.size) / SpectrumAnalyzer.hop + 1)
        let first = try #require(frames.first)
        #expect(abs(first.time - (10 + (2047.0 - 1024) / rate)) < 1e-9)
        #expect(abs(frames[1].time - first.time - 512 / rate) < 1e-9)
        let middle = frames[frames.count / 2]
        #expect((band(of: 200)...band(of: 200) + 1).contains(loudest(middle.bands)), "\(middle.bands)")
        // Перемотка: окно копится заново, старые сэмплы не смешиваются с новыми
        analyzer.reset()
        let short = Array(second[0..<2000])
        #expect(short.withUnsafeBufferPointer { analyzer.feed($0, start: 1, rate: rate) }.isEmpty)
    }

    /// Звук приходит буферами разной длины (декодер отдаёт пакеты по 1024 сэмпла и меньше): измерения те же, что при
    /// одном большом буфере, — окно тянется через границу буферов, шаг не сбивается.
    @Test func buffersOfAnySizeGiveTheSameMeasurements() {
        let rate = 44_100.0
        let signal = tone(440, rate: Float(rate), count: 12_000).enumerated().map { $1 + 0.01 * sin(Float($0) * 0.37) }
        let whole = SpectrumAnalyzer()
        let expected = signal.withUnsafeBufferPointer { whole.feed($0, start: 3, rate: rate) }
        let pieces = SpectrumAnalyzer()
        var frames: [SpectrumFrame] = []
        var offset = 0
        for length in [1, 700, 1024, 300, 2047, 2048, 5000] where offset < signal.count {
            let end = min(offset + length, signal.count)
            let piece = Array(signal[offset..<end])
            frames += piece.withUnsafeBufferPointer { pieces.feed($0, start: 3 + Double(offset) / rate, rate: rate) }
            offset = end
        }
        if offset < signal.count {
            let rest = Array(signal[offset...])
            frames += rest.withUnsafeBufferPointer { pieces.feed($0, start: 3 + Double(offset) / rate, rate: rate) }
        }
        #expect(frames.count == expected.count)
        for (got, want) in zip(frames, expected) {
            #expect(abs(got.time - want.time) < 1e-9)
            #expect(got.bands == want.bands)
        }
    }
}
