import CoreGraphics
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Оттенок обложки для фона экранов плеера на часах: как `CoverPalette` на iPhone, но Core Image на watchOS нет — картинка
/// из `ArtworkLoader` сводится Core Graphics к 24×24 по центральному квадрату и отдаётся `CoverColor` из пакета.
actor WatchTintLoader {
    static let shared = WatchTintLoader()

    private static let side = 24
    private var cache: [String: CoverRGB?] = [:]

    func rgb(for url: String?) async -> CoverRGB? {
        guard let url else { return nil }
        if let hit = cache[url] { return hit }
        guard let image = await ArtworkLoader.shared.image(Thumbnails.sized(url, px: 120)), let pixels = Self.downsample(image) else { return nil }
        let rgb = CoverColor.dominant(rgba: pixels)
        cache[url] = .some(rgb)
        return rgb
    }

    private static func downsample(_ image: CGImage) -> [UInt8]? {
        let square = min(image.width, image.height)
        guard square > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let crop = image.cropping(to: CGRect(x: (image.width - square) / 2, y: (image.height - square) / 2, width: square, height: square))
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }
}

/// Фон экрана плеера: плавный градиент из оттенка обложки. Это фон навигации (`containerBackground`): при переходе между
/// «Ещё», текстом и очередью цвета перетекают друг в друга, а не меняются рывком; со сменой трека цвет плывёт к новому.
struct PlayerBackground: ViewModifier {
    @Environment(WatchModel.self) private var model
    @State private var tint: CoverRGB?

    func body(content: Content) -> some View {
        let url = model.services.player.currentTrack?.artworkURL
        content
            .task(id: url) {
                let rgb = await WatchTintLoader.shared.rgb(for: url)
                withAnimation(.smooth(duration: 0.9)) { tint = rgb }
            }
            .containerBackground(for: .navigation) {
                let base = tint.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1) } ?? Color.gray
                LinearGradient(colors: [base.opacity(0.9), base.opacity(0.45), .black], startPoint: .top, endPoint: .bottom)
                    .animation(.smooth(duration: 0.9), value: tint)
            }
    }
}

extension View {
    func playerBackground() -> some View { modifier(PlayerBackground()) }
}

/// «Ещё» в «Сейчас играет»: ♡, текст, очередь, таймер сна и устройство — крупными плитками вместо ряда кнопок поверх управления.
struct WatchPlayerMoreView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let player = model.services.player
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        ScrollView {
            VStack(spacing: 8) {
                if let track = player.currentTrack {
                    HStack(spacing: 8) {
                        ArtworkView(url: track.artworkURL, size: 36, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.title).font(.footnote.weight(.semibold)).lineLimit(1)
                            Text(track.artistsText ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    if let track = player.currentTrack, let library = model.services.library {
                        let liked = library.isLiked(track.videoId)
                        Button { library.library.setLiked(track, !liked) } label: {
                            // Подпись одна и короткая: «Убрать из Избранного» не помещалась в плитку; состояние — сердце
                            PlayerTile(title: "library.favorites", systemImage: liked ? "heart.fill" : "heart",
                                       tint: liked ? .pink : nil, bounce: liked)
                        }
                        .buttonStyle(TileStyle())
                        .accessibilityLabel(Text(liked ? "menu.unlike" : "menu.like"))
                    }
                    NavigationLink(value: WatchRoute.lyrics) {
                        PlayerTile(title: "player.lyrics", systemImage: "quote.bubble")
                    }
                    .buttonStyle(TileStyle())
                    NavigationLink(value: WatchRoute.queue) {
                        PlayerTile(title: "player.queue", systemImage: "list.bullet")
                    }
                    .buttonStyle(TileStyle())
                    NavigationLink(value: WatchRoute.sleepTimer) {
                        let on = player.sleepTimerEnd != nil || player.sleepAtTrackEnd
                        PlayerTile(title: "sleep.title", systemImage: on ? "moon.fill" : "moon.zzz", tint: on ? .indigo : nil)
                    }
                    .buttonStyle(TileStyle())
                    if model.account.isSignedIn, model.account.supportsRemote {
                        NavigationLink(value: WatchRoute.remote) {
                            PlayerTile(title: "remote.device", systemImage: model.remote.isActive ? DeviceSymbol.name(for: model.remote.target?.platform ?? "") : "airplay.audio",
                                       tint: model.remote.isActive ? .accentColor : nil)
                        }
                        .buttonStyle(TileStyle())
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .playerBackground()
    }
}

/// Плитка «Ещё»: значок и подпись на стеклянной подложке.
private struct PlayerTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color?
    var bounce = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint ?? .white)
                .symbolEffect(.bounce, value: bounce)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 24)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Нажатие плитки: чуть сжимается и светлеет, как кнопки управления.
private struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}
