import CoreImage
import SwiftUI
import MelogoldCore

/// Цвета обложки для фона «Сейчас играет»: доминирующий (`rgb`) и палитра живого градиента (`palette`, первым — тот же
/// доминирующий; пользователь, 2026-10-02: «живой градиент из цветов обложки, двигается под звук»). Не размытая обложка.
struct CoverTint: Equatable, Sendable {
    let rgb: CoverRGB
    var palette: [CoverRGB] = []

    var color: Color { Self.color(rgb) }

    /// Палитра для градиента; у старой записи без палитры — один доминирующий цвет.
    var colors: [Color] { (palette.isEmpty ? [rgb] : palette).map(Self.color) }

    static func color(_ rgb: CoverRGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// Доминирующий цвет обложки через Core Image с кешем. Картинка берётся из `ArtworkLoader` (свой кеш и срезка полей
/// кадра видео), сводится Core Image к 24×24 по центральному квадрату и отдаётся `CoverColor` — чистому правилу из
/// пакета (тесты `CoverColorTests`). Готовый цвет лежит в кеше по адресу обложки: повторное открытие «Сейчас играет»
/// и переход к уже игравшему треку не ждут картинку.
actor CoverPalette {
    static let shared = CoverPalette()

    /// Сторона уменьшенной картинки, px: больше не нужно, цвет — по площади.
    private static let side = 24
    /// `nil` в кеше — «у обложки нет цвета» (серая или чёрно-белая): второй раз не считается.
    /// `NSCache` потокобезопасен сам, поэтому `nonisolated(unsafe)`: читать кеш нужно и без актора, из главного потока.
    private nonisolated(unsafe) static let cache = NSCache<NSString, TintBox>()
    private let context = CIContext()

    /// Уже посчитанный цвет без ожидания: `nil` в первом слое — ещё не считали.
    nonisolated static func cached(_ url: String?) -> CoverTint?? {
        guard let url, let box = cache.object(forKey: url as NSString) else { return nil }
        return .some(box.tint)
    }

    func tint(for url: String?) async -> CoverTint? {
        guard let url else { return nil }
        if let hit = Self.cached(url) { return hit }
        // Небольшая версия обложки — своя запись в кеше картинок, сеть не тянет лишнего
        let sized = Thumbnails.sized(url, px: 240)
        guard let image = await ArtworkLoader.shared.image(sized), let pixels = downsample(image) else { return nil }
        let tint = CoverColor.dominant(rgba: pixels).map { CoverTint(rgb: $0, palette: CoverColor.palette(rgba: pixels)) }
        Self.cache.setObject(TintBox(tint), forKey: url as NSString)
        return tint
    }

    /// Центральный квадрат, уменьшенный до `side`×`side`, RGBA8 в sRGB.
    private func downsample(_ image: CGImage) -> [UInt8]? {
        let source = CIImage(cgImage: image)
        let extent = source.extent
        let square = min(extent.width, extent.height)
        guard square > 0 else { return nil }
        let crop = CGRect(x: extent.midX - square / 2, y: extent.midY - square / 2, width: square, height: square)
        let scale = CGFloat(Self.side) / square
        let reduced = source
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        var pixels = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
        context.render(reduced, toBitmap: &pixels, rowBytes: Self.side * 4,
                       bounds: CGRect(x: 0, y: 0, width: Self.side, height: Self.side),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixels
    }
}

private nonisolated final class TintBox: @unchecked Sendable {
    let tint: CoverTint?
    init(_ tint: CoverTint?) { self.tint = tint }
}

/// Фон «Сейчас играет» — живой градиент из цветов обложки, который двигается под звук (пользователь, 2026-10-02: «как Apple
/// Music, но живой… градиент, живой на звук, который играет»; «это база» — так же на всех платформах). Сетка 3×3
/// (`MeshGradient`) из палитры обложки: пятна медленно плывут — быстрее, когда музыка громче, — бас на миг подсвечивает
/// середину и чуть раздувает фон. Внизу, под кнопками, фон спокойнее. Не размытая обложка. На паузе замирает, при
/// «Уменьшении движения» — неподвижный; у чёрно-белой обложки — системный фон.
struct NowPlayingBackground: View {
    let tint: CoverTint?
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Сглаженные уровни звука и фаза движения: обычный класс, а не состояние — кадры не перестраивают остальной экран.
    @State private var pulse = AudioPulse()

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            if let tint {
                Group {
                    if reduceMotion {
                        mesh(tint.colors, phase: 0, bass: 0)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.playingIsPlaying)) { context in
                            let _ = pulse.advance(to: context.date, levels: model.remoteTarget == nil ? model.services.player.currentLevels() : (0, 0, 0))
                            mesh(tint.colors, phase: pulse.phase, bass: pulse.bass)
                                .scaleEffect(1 + 0.05 * pulse.bass)
                        }
                    }
                }
                .opacity(contrast == .increased ? 0.6 : 1)
                // Под кнопками спокойнее: снизу фон подмешивается сильнее
                LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                       .init(color: systemBackground.opacity(scheme == .dark ? 0.45 : 0.5), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
        .ignoresSafeArea()
    }

    private var systemBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Сетка 3×3: углы стоят, середины краёв скользят вдоль краёв, центр ходит по кривой Лиссажу; бас толкает центр и
    /// подсвечивает его. Светлые и глубокие пятна чередуются — фон объёмный, а не ровная заливка одного цвета.
    private func mesh(_ palette: [Color], phase t: Double, bass: Double) -> some View {
        let tones = shaded(palette)
        func bright(_ i: Int) -> Color { tones[i % tones.count].bright }
        func deep(_ i: Int) -> Color { tones[i % tones.count].deep }
        let points: [SIMD2<Float>] = [
            [0, 0], [Float(0.5 + 0.28 * sin(t * 0.11)), 0], [1, 0],
            [0, Float(0.5 + 0.24 * sin(t * 0.09 + 1))],
            [Float(0.5 + 0.26 * sin(t * 0.13 + 0.5) + 0.07 * bass), Float(0.42 + 0.2 * cos(t * 0.12) - 0.06 * bass)],
            [1, Float(0.5 + 0.24 * cos(t * 0.08))],
            [0, 1], [Float(0.5 + 0.26 * cos(t * 0.1 + 2)), 1], [1, 1],
        ]
        let colors: [Color] = [
            deep(1), bright(0), deep(2),
            bright(2), bright(0).mix(with: .white, by: 0.3 * bass), deep(3),
            deep(0), bright(3), bright(1),
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors, smoothsColors: true)
    }

    /// Каждый цвет палитры — светлым и глубоким пятном: в тёмной теме под белый текст оба темнее исходного, в светлой —
    /// светлее; насыщенность сохраняется.
    private func shaded(_ palette: [Color]) -> [(bright: Color, deep: Color)] {
        let base = palette.isEmpty ? [Color.gray] : palette
        let filled = base.count >= 4 ? base : (0..<4).map { base[$0 % base.count] }
        return filled.map { color in
            scheme == .dark
                // Светлое пятно не светлее 70 % исходного: белый текст поверх читается и на бежевой обложке
                ? (color.mix(with: .black, by: 0.32), color.mix(with: .black, by: 0.66))
                : (color.mix(with: .white, by: 0.12), color.mix(with: .white, by: 0.55))
        }
    }
}

/// Сглаженный звук для фона: бас подхватывается быстро и отпускается медленно (вспышка на удар), общая громкость
/// ускоряет движение пятен. Фаза копится от кадра к кадру — ускорение не дёргает картинку.
@MainActor
final class AudioPulse {
    private(set) var phase: Double = 0
    private(set) var bass: Double = 0
    private var energy: Double = 0
    private var last: Date?

    func advance(to date: Date, levels: (low: Float, mid: Float, high: Float)) {
        let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        let low = Double(levels.low)
        bass = low > bass ? bass + (low - bass) * 0.55 : bass * 0.9
        let loudness = (Double(levels.low) + Double(levels.mid) + Double(levels.high)) / 3
        energy += (loudness - energy) * 0.06
        phase += dt * (0.5 + 1.3 * energy)
    }
}
