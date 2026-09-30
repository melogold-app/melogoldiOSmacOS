import CoreImage
import SwiftUI
import MelogoldCore

/// Оттенок обложки для фона «Сейчас играет» (docs/PROMPT.md §5.1): мягкий и статичный, не размытая обложка.
struct CoverTint: Equatable, Sendable {
    let rgb: CoverRGB

    var color: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
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
        let tint = CoverColor.dominant(rgba: pixels).map(CoverTint.init(rgb:))
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

/// Фон «Сейчас играет»: системный фон и поверх него мягкий вертикальный оттенок обложки, сверху гуще, книзу тает.
/// Статичный (docs/PROMPT.md §5.1): двигается только смена цвета при смене трека — это смена состояния.
struct NowPlayingBackground: View {
    let tint: CoverTint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // При повышенной контрастности оттенок слабее: текст важнее цвета
        let strength = contrast == .increased ? 0.5 : 1.0
        let top = (scheme == .dark ? 0.55 : 0.42) * strength
        let bottom = (scheme == .dark ? 0.16 : 0.10) * strength
        ZStack {
            Rectangle().fill(.background)
            if let tint {
                LinearGradient(colors: [tint.color.opacity(top), tint.color.opacity(bottom)], startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: tint)
        .ignoresSafeArea()
    }
}
