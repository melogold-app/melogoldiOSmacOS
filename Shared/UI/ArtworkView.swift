import ImageIO
import SwiftUI
import MelogoldCore

/// Обложка по месту (REWRITE §4.8.2): размер картинки подбирается по пикселям места, кадр видео 16:9 в квадрате
/// обрезается по центру и выбирается по короткой стороне — по высоте (задание 0008). Пока грузится — нейтральная
/// подложка со значком ноты. Грузит `ArtworkSession` (свой дисковый кэш в `Caches`), в памяти держится последняя
/// сотня картинок.
struct ArtworkView: View {
    enum Shape { case rounded, circle, wide, square }

    let url: String?
    var size: CGFloat
    var shape: Shape = .rounded
    /// Радиус скругления вместо стандартного (у `rounded` — 9 % стороны от 5 до 14 pt, у `wide` — 8): крупным обложкам он
    /// меньше (прежние 12 % давали «пузыри» у карточек в 150–176 pt; те же числа — `Design.Radius.artwork` у приложения).
    var cornerRadius: CGFloat?
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private var height: CGFloat { shape == .wide ? size * 9 / 16 : size }

    var body: some View {
        // Кадр видео в квадрате показывается серединой: нужная высота кадра — сторона квадрата, ширина — в 16/9 больше.
        let side = max(size, height) * (shape != .wide && Thumbnails.isWide(url) ? 16.0 / 9.0 : 1)
        let sized = Thumbnails.sized(url, px: Int((side * displayScale).rounded(.up)))
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: height)
        .clipShape(clip)
        .accessibilityHidden(true)
        .task(id: sized) {
            image = await ArtworkLoader.shared.image(sized)
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: max(10, min(size, height) * 0.35)))
                .foregroundStyle(.secondary)
        }
    }

    private var clip: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: cornerRadius ?? min(14, max(5, size * 0.09)), style: .continuous))
        case .wide: AnyShape(RoundedRectangle(cornerRadius: cornerRadius ?? 8, style: .continuous))
        case .square: AnyShape(Rectangle())
        }
    }
}

/// Загрузка и разбор обложек вне главного потока; готовые картинки — в памяти. До того как картинка попадёт в память,
/// у кадра видео (`i.ytimg.com/vi/`) срезаются поля любого ровного цвета, у любой картинки — обводка одного цвета со
/// всех четырёх сторон (задание 0008, `FrameBars`). Помнит, какие размеры одной обложки грузились (`Thumbnails.family`):
/// большая обложка «Сейчас играет» показывает маленькую из мини-плеера, пока грузится сама (задание 0033 §6).
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let memory = NSCache<NSString, CGImageBox>()
    private var running: [String: Task<CGImage?, Never>] = [:]
    /// Обложка (`Thumbnails.family`) → адреса её размеров, которые грузились.
    private var sizes: [String: Set<String>] = [:]

    init() {
        memory.countLimit = 120
    }

    /// Картинка по адресу, если она уже в памяти, — без загрузки.
    func cached(_ url: String?) -> CGImage? {
        url.flatMap { memory.object(forKey: $0 as NSString)?.image }
    }

    /// Та же обложка другого размера, пока эта грузится: самая крупная из памяти; нет такой и `wait` — та, что уже в пути
    /// (мини-плеер начал её раньше, и маленькая приходит быстрее). Ничего нет — `nil`: сама загрузка здесь не начинается.
    func otherSize(of url: String?, wait: Bool) async -> CGImage? {
        guard let url else { return nil }
        let others = (sizes[Thumbnails.family(url)] ?? []).subtracting([url])
        if let ready = others.compactMap({ memory.object(forKey: $0 as NSString)?.image }).max(by: { $0.width < $1.width }) {
            return ready
        }
        guard wait, let task = others.lazy.compactMap({ self.running[$0] }).first else { return nil }
        return await task.value
    }

    func image(_ url: String?) async -> CGImage? {
        guard let url, let address = URL(string: url) else { return nil }
        if let hit = memory.object(forKey: url as NSString) { return hit.image }
        if let task = running[url] { return await task.value }
        remember(url)
        let isFrame = Thumbnails.isWide(url)
        let task = Task<CGImage?, Never> {
            guard let data = await ArtworkSession.imageData(from: address),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            // У обложки — только обводка скана со всех сторон, у кадра видео — ещё и поля
            return FrameCrop.withoutBars(image, bars: isFrame)
        }
        running[url] = task
        let result = await task.value
        running[url] = nil
        if let result { memory.setObject(CGImageBox(result), forKey: url as NSString) }
        return result
    }

    private func remember(_ url: String) {
        // В памяти не больше 120 картинок: время от времени забываются обложки, которых нет ни в памяти, ни в пути
        if sizes.count >= 600 {
            sizes = sizes.filter { $0.value.contains { memory.object(forKey: $0 as NSString) != nil || running[$0] != nil } }
        }
        sizes[Thumbnails.family(url), default: []].insert(url)
    }
}

nonisolated final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

extension Track {
    /// Обложка трека; у видео без своей — превью YouTube.
    var artworkURL: String? { thumbnailUrl ?? Thumbnails.forVideo(videoId) }

    /// Длительность «3:45».
    var durationLabel: String? { durationMs.map(Durations.format) }
}
