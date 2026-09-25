import ImageIO
import SwiftUI
import MelogoldCore

/// Обложка по месту (REWRITE §4.8.2): размер картинки подбирается по пикселям места, превью видео 16:9 в квадрате
/// обрезается по центру. Пока грузится — нейтральная подложка со значком ноты. Грузит `ArtworkSession`
/// (свой дисковый кэш в `Caches`), в памяти держится последняя сотня картинок.
struct ArtworkView: View {
    enum Shape { case rounded, circle, wide }

    let url: String?
    var size: CGFloat
    var shape: Shape = .rounded
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private var height: CGFloat { shape == .wide ? size * 9 / 16 : size }

    var body: some View {
        let pixels = Int((max(size, height) * displayScale).rounded(.up))
        let sized = Thumbnails.sized(url, px: pixels)
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
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: max(4, size * 0.12), style: .continuous))
        case .wide: AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Загрузка и разбор обложек вне главного потока; готовые картинки — в памяти.
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let memory = NSCache<NSString, CGImageBox>()
    private var running: [String: Task<CGImage?, Never>] = [:]

    init() {
        memory.countLimit = 120
    }

    func image(_ url: String?) async -> CGImage? {
        guard let url, let address = URL(string: url) else { return nil }
        if let hit = memory.object(forKey: url as NSString) { return hit.image }
        if let task = running[url] { return await task.value }
        let task = Task<CGImage?, Never> {
            guard let (data, _) = try? await ArtworkSession.shared.data(from: address),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        running[url] = task
        let result = await task.value
        running[url] = nil
        if let result { memory.setObject(CGImageBox(result), forKey: url as NSString) }
        return result
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
