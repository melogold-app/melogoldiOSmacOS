import Foundation

/// Звук → огибающие и удар для живого фона «Сейчас играет» (задание 0031, §3) — перенос `Analysis` из Linux `fluid.rs`.
/// Полосы — 48 значений 0…1 одного измерения спектра (`SpectrumAnalyzer` в MelogoldPlayback); `dt` — секунды с прошлого
/// кадра.
public struct FluidAnalysis: Sendable {
    public static let bandCount = 48

    public private(set) var bands = [Float](repeating: 0, count: bandCount)
    private var targets = [Float](repeating: 0, count: bandCount)
    /// Бас (полосы 0–9), верха (30–47) и громкость (все), сглаженные к своему среднему со скоростью 12/с.
    public private(set) var bass: Float = 0
    public private(set) var high: Float = 0
    public private(set) var loud: Float = 0
    /// Огибающая удара: 1 в миг удара, гаснет на 4/с.
    public private(set) var beat: Float = 0
    private var fluxAverage: Float = 0
    private var previousBass: Float = 0
    private var sinceBeat: Float = 1
    /// Время последнего учтённого измерения: одно измерение — один раз, сколько бы кадров его ни показали.
    private var lastTime: Double?

    public init() {}

    /// Новое измерение со временем звука `time`. Удар — по сырым значениям, до сглаживания: поток баса заметно выше
    /// своего среднего и с прошлого удара прошло больше 0,2 с.
    public mutating func feed(time: Double, bands measured: [Float]) {
        guard time != lastTime, measured.count == Self.bandCount else { return }
        lastTime = time
        targets = measured
        let bass = measured[0..<10].reduce(0, +) / 10
        let flux = max(0, bass - previousBass)
        previousBass = bass
        fluxAverage = fluxAverage * 0.94 + flux * 0.06
        if flux > fluxAverage * 2.2 + 0.035, sinceBeat > 0.2 {
            beat = 1
            sinceBeat = 0
        }
    }

    /// Шаг кадра: полосы идут к целям со скоростью 18/с вверх и 4/с вниз; на паузе цели гаснут.
    public mutating func step(dt: Float, playing: Bool) {
        for index in bands.indices {
            if !playing { targets[index] *= max(0, 1 - dt * 3) }
            let rate: Float = targets[index] > bands[index] ? 18 : 4
            bands[index] += (targets[index] - bands[index]) * min(rate * dt, 1)
        }
        func range(_ from: Int, _ to: Int) -> Float { bands[from..<to].reduce(0, +) / Float(to - from) }
        func follow(_ current: Float, _ target: Float) -> Float { current + (target - current) * min(12 * dt, 1) }
        bass = follow(bass, range(0, 10))
        high = follow(high, range(30, Self.bandCount))
        loud = follow(loud, range(0, Self.bandCount))
        beat *= max(0, 1 - dt * 4)
        sinceBeat += dt
    }
}

/// Движение живого фона, вариант 1 «капли — бас, течение — верха» (задание 0031, §4) — перенос `Motion` из Linux
/// `fluid.rs`. Силы следуют за звуком: вверх со скоростью 5/с, вниз — 1,8/с.
public struct FluidMotion: Sendable {
    /// Сила течения (верха) и лавы (бас).
    public private(set) var liquid: Float = 0
    public private(set) var lava: Float = 0
    /// Размер капель — ещё одно сглаживание лавы: капли раздуваются мягче, чем течёт фон (у всех шести одинаковый).
    public private(set) var blob: Float = 0
    /// Пульс на бас: на ударе — сразу, отпускает мягко.
    public private(set) var pulse: Float = 0
    /// Время течения и капель: идёт, только пока играет, быстрее — когда сил больше.
    public private(set) var liquidFlow: Float = 0
    public private(set) var lavaFlow: Float = 0

    public init() {}

    public mutating func step(_ analysis: FluidAnalysis, dt: Float, playing: Bool) {
        func follow(_ current: Float, _ target: Float) -> Float {
            let rate: Float = target > current ? 5 : 1.8
            return current + (target - current) * min(rate * dt, 1)
        }
        liquid = follow(liquid, min(analysis.high, 1.5))
        lava = follow(lava, min(analysis.bass, 1.5))
        let target = min(analysis.beat + analysis.bass * 0.4, 1.2)
        pulse = target > pulse ? target : follow(pulse, target)
        blob = follow(blob, min(lava, 1.5))
        if playing {
            liquidFlow += dt * (0.25 + 1.4 * liquid)
            lavaFlow += dt * (0.2 + 1.2 * lava)
        }
    }

    /// Замерший кадр (задание 0031, §6): силы — 0, время стоит там, где было.
    public mutating func freeze() {
        (liquid, lava, blob, pulse) = (0, 0, 0, 0)
    }

    /// Силы погасли: на паузе кадры больше не нужны.
    public var calm: Bool {
        liquid < 0.005 && lava < 0.005 && blob < 0.005 && pulse < 0.005
    }
}
