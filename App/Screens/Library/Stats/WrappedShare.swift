import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import MelogoldCore

/// Картинка «Итогов года» для «Поделиться» (задание 0018): PNG 1080×1920, фон — цвет обложки трека года, надпись «Melogold ·
/// Итоги 2026». Её собирает `ImageRenderer` из `WrappedShareCard`.
struct WrappedShareImage: Transferable {
    let url: URL
    let year: Int

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { image in SentTransferredFile(image.url) }
    }

    static let width = 1080
    static let height = 1920

    /// Рисует картинку и кладёт её в папку временных файлов; `nil` — не получилось.
    @MainActor
    static func make(year: Int, stats: ListeningStats, cover: CGImage?, tint: ArtworkTint.Tint, locale: Locale) -> WrappedShareImage? {
        let renderer = ImageRenderer(content: WrappedShareCard(year: year, stats: stats, cover: cover, tint: tint, locale: locale)
            .frame(width: CGFloat(width), height: CGFloat(height)))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: CGFloat(height))
        guard let image = renderer.cgImage else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Melogold-\(year).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return WrappedShareImage(url: url, year: year)
    }
}

/// Макет картинки: обложка трека года, минуты, трек, три исполнителя, подпись. Фон — тот же оттенок, что у карточек.
struct WrappedShareCard: View {
    let year: Int
    let stats: ListeningStats
    let cover: CGImage?
    let tint: ArtworkTint.Tint
    let locale: Locale

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: String(localized: "stats.share.watermark \(year)"))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .opacity(0.85)
                .padding(.top, 110)
            Spacer(minLength: 40)
            if let cover {
                Image(decorative: cover, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 560, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 56, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
            }
            if let top = stats.topTracks.first {
                Text("stats.wrapped.track")
                    .font(.system(size: 40, weight: .medium))
                    .opacity(0.8)
                    .padding(.top, 56)
                Text(verbatim: top.title)
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 90)
                if let artist = top.artist {
                    Text(verbatim: artist)
                        .font(.system(size: 46))
                        .opacity(0.85)
                        .lineLimit(1)
                        .padding(.horizontal, 90)
                }
            }
            Spacer(minLength: 40)
            VStack(spacing: 6) {
                Text(verbatim: stats.totalMinutes.formatted(.number.locale(locale)))
                    .font(.system(size: 150, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(verbatim: WrappedView.plural("stats.wrapped.minutes", stats.totalMinutes))
                    .font(.system(size: 42, weight: .medium))
                    .opacity(0.85)
            }
            if !stats.topArtists.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(stats.topArtists.prefix(3).enumerated()), id: \.element.id) { index, artist in
                        Text(verbatim: "\(index + 1)  \(artist.name)")
                            .font(.system(size: 44, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .padding(.top, 48)
                .padding(.horizontal, 90)
            }
            Spacer(minLength: 110)
        }
        .foregroundStyle(.white)
        .frame(width: 1080, height: 1920)
        .background(LinearGradient(colors: [tint.color, tint.darker.color], startPoint: .top, endPoint: .bottom))
        .environment(\.locale, locale)
    }
}
