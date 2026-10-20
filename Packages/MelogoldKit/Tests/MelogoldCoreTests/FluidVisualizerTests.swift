import Foundation
import Testing
@testable import MelogoldCore

/// Живой фон «Сейчас играет»: удар, огибающие и движение (задание 0031, §3–§4) — сценарии Linux `fluid.rs`.
@Suite("Живой фон — удар и движение")
struct FluidVisualizerTests {
    private let quiet = [Float](repeating: 0, count: FluidAnalysis.bandCount)
    private var loudBass: [Float] {
        var bands = quiet
        for index in 0..<10 { bands[index] = 0.8 }
        return bands
    }

    /// Ступенька баса — удар; через 0,25 с огибающая удара ниже 0,4 (проверка задания).
    @Test func bassStepIsABeatThatFades() {
        var analysis = FluidAnalysis()
        var time = 0.0
        for _ in 0..<30 {
            time += 0.011
            analysis.feed(time: time, bands: quiet)
            analysis.step(dt: 1 / 60, playing: true)
        }
        time += 0.011
        analysis.feed(time: time, bands: loudBass)
        #expect(analysis.beat == 1)
        for _ in 0..<15 { analysis.step(dt: 1 / 60, playing: true) }
        #expect(analysis.beat < 0.4, "\(analysis.beat)")
    }

    /// Одно и то же измерение на нескольких кадрах не считается заново.
    @Test func repeatedMeasurementIsNotANewBeat() {
        var analysis = FluidAnalysis()
        analysis.feed(time: 1, bands: loudBass)
        #expect(analysis.beat == 1)
        // Удар погас, с него прошло больше 0,2 с
        for _ in 0..<60 { analysis.step(dt: 1 / 60, playing: true) }
        let faded = analysis.beat
        analysis.feed(time: 1, bands: loudBass)
        #expect(analysis.beat == faded)
    }

    @Test func steadyBassIsNotABeatEveryFrame() {
        var analysis = FluidAnalysis()
        var beats = 0
        for frame in 0..<120 {
            analysis.feed(time: Double(frame) * 0.011, bands: loudBass)
            if analysis.beat == 1 { beats += 1 }
            analysis.step(dt: 1 / 60, playing: true)
        }
        #expect(beats == 1, "ровный бас — один удар на вступлении")
    }

    @Test func bandsRiseFastAndFallSlowly() {
        var analysis = FluidAnalysis()
        analysis.feed(time: 0, bands: loudBass)
        analysis.step(dt: 1 / 60, playing: true)
        let afterRise = analysis.bands[0]
        #expect(abs(afterRise - 0.8 * 0.3) < 1e-5, "вверх — 18/с")
        analysis.feed(time: 0.1, bands: quiet)
        analysis.step(dt: 1 / 60, playing: true)
        #expect(abs(analysis.bands[0] - afterRise * (1 - 4.0 / 60)) < 1e-5, "вниз — 4/с")
    }

    @Test func pauseFadesTheTargets() {
        var analysis = FluidAnalysis()
        analysis.feed(time: 0, bands: loudBass)
        for _ in 0..<30 { analysis.step(dt: 1 / 60, playing: true) }
        let playing = analysis.bass
        for _ in 0..<180 { analysis.step(dt: 1 / 60, playing: false) }
        #expect(playing > 0.5)
        #expect(analysis.bass < 0.01)
    }

    /// Течение и капли идут, только пока играет.
    @Test func motionFlowsOnlyWhilePlaying() {
        var analysis = FluidAnalysis()
        analysis.feed(time: 0, bands: [Float](repeating: 0.5, count: FluidAnalysis.bandCount))
        for _ in 0..<30 { analysis.step(dt: 1 / 60, playing: true) }
        var motion = FluidMotion()
        motion.step(analysis, dt: 0.1, playing: false)
        #expect(motion.liquidFlow == 0 && motion.lavaFlow == 0)
        #expect(motion.liquid > 0 && motion.lava > 0)
        motion.step(analysis, dt: 0.1, playing: true)
        #expect(motion.liquidFlow > 0 && motion.lavaFlow > 0)
    }

    @Test func pulseJumpsOnBeatAndReleasesSoftly() {
        var analysis = FluidAnalysis()
        analysis.feed(time: 0, bands: loudBass)
        var motion = FluidMotion()
        motion.step(analysis, dt: 1 / 60, playing: true)
        #expect(motion.pulse >= 1, "удар — сразу")
        for _ in 0..<30 {
            analysis.step(dt: 1 / 60, playing: true)
            motion.step(analysis, dt: 1 / 60, playing: true)
        }
        #expect(motion.pulse < 1 && motion.pulse > 0.2, "\(motion.pulse)")
    }

    @Test func freezeStopsForcesButKeepsTime() {
        var analysis = FluidAnalysis()
        analysis.feed(time: 0, bands: loudBass)
        var motion = FluidMotion()
        for _ in 0..<20 {
            analysis.step(dt: 1 / 60, playing: true)
            motion.step(analysis, dt: 1 / 60, playing: true)
        }
        let flow = motion.liquidFlow
        motion.freeze()
        #expect(motion.calm)
        #expect(motion.liquidFlow == flow)
    }
}

/// Фон без шейдера (задание 0030): слои, часы и «Живой фон».
@Suite("Фон «Сейчас играет» — слои и часы")
struct BackdropMotionTests {
    @Test func layersFollowTheFormulas() {
        let first = BackdropMotion.first(t: 10, w: 800, h: 600)
        #expect(first == BackdropMotion.Layer(centerX: 400, centerY: 300, side: 1280, degrees: 24, opacity: 1))
        let second = BackdropMotion.second(t: 0, w: 800, h: 600)
        #expect(abs(second.centerX - 400) < 1e-9)
        #expect(abs(second.centerY - (300 + 0.15 * 600)) < 1e-9)
        #expect(abs(second.side - 920) < 1e-9 && second.degrees == 90 && second.opacity == 0.7)
    }

    @Test func firstLayerCoversTheWholeAreaAtAnyAngle() {
        // Вписанный круг квадрата 1,6 · max(w, h) накрывает углы области при любом повороте
        for (w, h) in [(390.0, 844.0), (1280.0, 800.0), (2000.0, 600.0)] {
            let layer = BackdropMotion.first(t: 0, w: w, h: h)
            #expect(layer.side / 2 >= (w * w + h * h).squareRoot() / 2)
        }
    }

    @Test func clockRunsOnlyWhenAsked() {
        var clock = BackdropClock()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        clock.advance(to: start, running: true)
        clock.advance(to: start.addingTimeInterval(0.05), running: true)
        #expect(abs(clock.seconds - 0.05) < 1e-9)
        // Пауза: время стоит, но не сбрасывается
        clock.advance(to: start.addingTimeInterval(5), running: false)
        #expect(abs(clock.seconds - 0.05) < 1e-9)
        // После паузы — с того же места, без прыжка на время паузы
        clock.advance(to: start.addingTimeInterval(6), running: true)
        clock.advance(to: start.addingTimeInterval(6.02), running: true)
        #expect(abs(clock.seconds - 0.07) < 1e-9)
        // Пропуск кадров — не больше 0,1 с за кадр
        clock.advance(to: start.addingTimeInterval(9), running: true)
        #expect(abs(clock.seconds - 0.17) < 1e-9)
    }

    @Test func liveNeedsVisibleSettingAndMotion() {
        #expect(BackdropClock.isLive(visible: true, liveBackground: true, reduceMotion: false))
        #expect(!BackdropClock.isLive(visible: false, liveBackground: true, reduceMotion: false))
        #expect(!BackdropClock.isLive(visible: true, liveBackground: false, reduceMotion: false))
        #expect(!BackdropClock.isLive(visible: true, liveBackground: true, reduceMotion: true))
    }
}
