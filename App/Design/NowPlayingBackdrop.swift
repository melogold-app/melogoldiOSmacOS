import CoreGraphics
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Обложка играющего трека, подготовленная для фона «Сейчас играет» (задания 0030 и 0031). Равенство — по адресу обложки:
/// одна обложка — один фон.
nonisolated struct NowPlayingCover: Equatable, Sendable {
    let url: String
    let backdrop: BackdropCover
    /// Слой запасного фона: размытая 24 × 24 с матрицей цвета.
    let layer: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
}

/// Подготовка обложки для фона «Сейчас играет» вне главного потока, с кешем по адресу: цвета по долям, размытая 24 × 24,
/// яркость, подложка и текстура шейдера 256 × 256 (`BackdropCover`, тесты `ArtworkColorsTests`). Считает `RootView` при
/// смене трека — к открытию «Сейчас играет» фон уже готов и не мигает.
actor NowPlayingCovers {
    static let shared = NowPlayingCovers()

    /// Сторона картинки, px — как у Linux (обложка «Сейчас играет» на 544): цвета те же, а счёт — миллисекунды.
    private static let side = 544
    /// `NSCache` потокобезопасен сам, поэтому `nonisolated(unsafe)`: читать кеш нужно и без актора, из главного потока.
    private nonisolated(unsafe) static let cache: NSCache<NSString, CoverBox> = {
        let cache = NSCache<NSString, CoverBox>()
        cache.countLimit = 32
        return cache
    }()

    /// Уже подготовленная обложка без ожидания.
    nonisolated static func cached(_ url: String?) -> NowPlayingCover? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSString)?.cover
    }

    /// Обложка для фона; `nil` — картинки нет (нет сети, адрес пустой). Неудача не запоминается: сеть вернётся.
    func cover(for url: String?) async -> NowPlayingCover? {
        guard let url else { return nil }
        if let hit = Self.cached(url) { return hit }
        guard let image = await ArtworkLoader.shared.image(Thumbnails.sized(url, px: Self.side)),
              let pixels = Self.pixels(image),
              let backdrop = BackdropCover.prepare(rgba: pixels.rgba, width: pixels.width, height: pixels.height,
                                                   stride: pixels.width * 4),
              let layer = Self.image(rgba: backdrop.tinted, side: ArtworkColors.previewSide) else { return nil }
        let cover = NowPlayingCover(url: url, backdrop: backdrop, layer: layer)
        Self.cache.setObject(CoverBox(cover), forKey: url as NSString)
        return cover
    }

    /// Пиксели картинки RGBA8 в sRGB, как есть по размеру (у кадра видео поля уже срезаны `ArtworkLoader`).
    private static func pixels(_ image: CGImage) -> (rgba: [UInt8], width: Int, height: Int)? {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (rgba, width, height) : nil
    }

    private static func image(rgba: [UInt8], side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private nonisolated final class CoverBox: @unchecked Sendable {
    let cover: NowPlayingCover
    init(_ cover: NowPlayingCover) { self.cover = cover }
}

#if os(iOS) || os(macOS)
/// Фон «Сейчас играет» — общая норма всех платформ (задания 0030 и 0031, эталон — Linux): размытая обложка во всё окно,
/// которая живёт под музыку — течёт от верхних частот, капли её цветов раздувает бас, на ударе размытие собирается
/// (`FluidBackdropView`). Нет Metal — размытая обложка двумя вращающимися слоями (`BlurredCoverBackdrop`). Движется,
/// пока трек играет, окно видно, «Живой фон» включён и «Уменьшение движения» выключено; иначе — тот же кадр, неподвижный.
/// Повышенная контрастность — без фона: системный фон и цвета темы. Текст и кнопки поверх фона всегда светлые — тёмную
/// схему ставит `NowPlayingChrome`.
struct NowPlayingBackdrop: View {
    let cover: NowPlayingCover?
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Подложка, пока обложки нет: почти чёрная, как у обложки без цветов (`0x101010` у Linux).
    static let emptyBase: UInt32 = 0x10_1010

    var body: some View {
        ZStack {
            if contrast == .increased {
                Rectangle().fill(.background)
            } else {
                Self.color(cover?.backdrop.base ?? Self.emptyBase)
                if FluidRenderer.isAvailable {
                    FluidBackdropView(cover: cover, live: live, playing: model.playingIsPlaying, fades: !reduceMotion,
                                      spectrum: { [model] in
                                          // Звук свой, только пока играет этот плеер, а не пульт другого устройства
                                          model.remoteTarget == nil ? model.services.player.currentSpectrum() : nil
                                      })
                } else {
                    BlurredCoverBackdrop(cover: cover, moving: live && model.playingIsPlaying, fades: !reduceMotion)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var live: Bool {
        BackdropClock.isLive(visible: scenePhase != .background, liveBackground: model.settings.liveBackground,
                             reduceMotion: reduceMotion)
    }

    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

/// Фон задания 0030 (§1) — запасной путь, когда живого фона нет: размытая обложка 24 × 24 (матрица цвета уже наложена)
/// двумя квадратами, вращающимися навстречу, под гауссовым размытием, и виньетка. Формулы — `BackdropMotion`, часы —
/// `BackdropClock`: идут, только пока `moving`. Новая обложка проявляется поверх старой за 0,4 с, часы не сбрасываются.
struct BlurredCoverBackdrop: View {
    let cover: NowPlayingCover?
    let moving: Bool
    let fades: Bool
    /// Часы — обычный класс, а не состояние: кадры не перестраивают остальной экран.
    @State private var clock = ClockBox()
    @State private var previous: NowPlayingCover?
    @State private var fadeStart = Date.distantPast

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: !moving && previous == nil)) { context in
                let t = clock.advance(to: context.date, running: moving)
                let progress = min(1, max(0, context.date.timeIntervalSince(fadeStart) / BackdropMotion.crossfade))
                ZStack {
                    if let previous, progress < 1 {
                        CoverLayers(cover: previous, t: t, size: proxy.size)
                    }
                    if let cover {
                        CoverLayers(cover: cover, t: t, size: proxy.size)
                            .opacity(previous == nil ? 1 : progress)
                    }
                    // Виньетка: края темнее — внимание остаётся на обложке и тексте
                    EllipticalGradient(stops: [.init(color: .clear, location: BackdropMotion.vignetteStart),
                                               .init(color: .black.opacity(BackdropMotion.vignetteEdge), location: 1)],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: BackdropMotion.vignetteRadius)
                }
            }
        }
        .onChange(of: cover) { old, _ in
            guard fades, let old else { return }
            previous = old
            fadeStart = .now
        }
        .task(id: fadeStart) {
            guard previous != nil else { return }
            try? await Task.sleep(for: .seconds(BackdropMotion.crossfade))
            previous = nil
        }
    }
}

/// Одна обложка запасного фона: подложка и два слоя под размытием.
private struct CoverLayers: View {
    let cover: NowPlayingCover
    let t: Double
    let size: CGSize

    var body: some View {
        let first = BackdropMotion.first(t: t, w: size.width, h: size.height)
        let second = BackdropMotion.second(t: t, w: size.width, h: size.height)
        ZStack {
            NowPlayingBackdrop.color(cover.backdrop.base)
            ZStack {
                layer(first)
                layer(second)
            }
            .frame(width: size.width, height: size.height)
            // σ = радиус / 2, как у `GtkSnapshot.push_blur(32)`; радиус размытия SwiftUI — это σ
            .blur(radius: BackdropMotion.blurRadius / 2, opaque: true)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func layer(_ layer: BackdropMotion.Layer) -> some View {
        Image(decorative: cover.layer, scale: 1)
            .resizable()
            // Линейная фильтрация растянутой 24 × 24
            .interpolation(.low)
            .frame(width: layer.side, height: layer.side)
            .rotationEffect(.degrees(layer.degrees))
            .position(x: layer.centerX, y: layer.centerY)
            .opacity(layer.opacity)
    }
}

/// Часы фона в ссылочной обёртке для `@State`.
private final class ClockBox {
    private var clock = BackdropClock()

    func advance(to date: Date, running: Bool) -> Double {
        clock.advance(to: date, running: running)
    }
}
#endif
