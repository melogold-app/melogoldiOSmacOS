import Foundation

/// Движение фона «Сейчас играет» без шейдера (задание 0030, §1): два квадрата размытой обложки, вращающиеся навстречу,
/// виньетка. Формулы и числа — из задания, одни на всех платформах (Linux `backdrop.rs`, Windows `BackdropMotion`);
/// `t` — секунды часов анимации, `w`, `h` — размер области «Сейчас играет» в точках.
public enum BackdropMotion {
    /// Положение одного слоя: центр, сторона квадрата, поворот в градусах и непрозрачность.
    public struct Layer: Equatable, Sendable {
        public let centerX, centerY, side, degrees, opacity: Double
    }

    /// Слой 1: сторона `1,6 · max(w, h)` вокруг середины, поворот `t · 2,4°`, непрозрачность 1.
    public static func first(t: Double, w: Double, h: Double) -> Layer {
        Layer(centerX: w / 2, centerY: h / 2, side: 1.6 * max(w, h), degrees: t * 2.4, opacity: 1)
    }

    /// Слой 2: сторона `1,15 · max(w, h)`, центр плывёт, поворот `90° − t · 3,6°`, непрозрачность 0,7.
    public static func second(t: Double, w: Double, h: Double) -> Layer {
        Layer(centerX: w / 2 + sin(t / 17) * 0.18 * w, centerY: h / 2 + cos(t / 23) * 0.15 * h,
              side: 1.15 * max(w, h), degrees: 90 - t * 3.6, opacity: 0.7)
    }

    /// Радиус гауссова размытия слоёв в точках — как `GtkSnapshot.push_blur(32)`, у которого σ = радиус / 2.
    public static let blurRadius = 32.0
    /// Виньетка: радиусы `0,75 · w` и `0,75 · h`; до 55 % — прозрачная, на краю — чёрный с непрозрачностью 0,30.
    public static let vignetteRadius = 0.75
    public static let vignetteStart = 0.55
    public static let vignetteEdge = 0.30
    /// Новая обложка сменяет старую затуханием за столько секунд.
    public static let crossfade = 0.4
    /// Самый длинный шаг часов за кадр: пропуск кадров (приложение было в фоне) — не прыжок фона.
    public static let longestFrame = 0.1
}

/// Часы анимации фона «Сейчас играет» (задание 0030, §2): идут, только пока трек играет, окно видно, «Живой фон» включён и
/// в системе не выключены анимации. Пауза и смена трека время не сбрасывают — движение продолжается с того же места.
public struct BackdropClock: Sendable {
    public private(set) var seconds: Double = 0
    private var last: Date?

    public init() {}

    /// Фон может двигаться: окно видно, «Живой фон» включён, «Уменьшение движения» выключено. Двигается — если ещё и играет.
    public static func isLive(visible: Bool, liveBackground: Bool, reduceMotion: Bool) -> Bool {
        visible && liveBackground && !reduceMotion
    }

    /// Кадр в момент `date`; `running` — фон живой и трек играет. Стоящие часы помнят только момент кадра.
    @discardableResult
    public mutating func advance(to date: Date, running: Bool) -> Double {
        if running, let last {
            seconds += min(max(0, date.timeIntervalSince(last)), BackdropMotion.longestFrame)
        }
        last = running ? date : nil
        return seconds
    }
}
