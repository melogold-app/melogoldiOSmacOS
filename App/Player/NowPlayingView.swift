import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// «Сейчас играет» (docs/PROMPT.md §5.7): обложка, название, исполнитель, ползунок перемотки, ⏮ ⏯ ⏭, AirPlay.
/// В широком окне и на iPhone боком — обложка слева, управление справа (REWRITE §3.10.11). Текст, очередь, ♡,
/// таймер и фон по цвету обложки — в следующих срезах.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let player = model.services.player
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height * 1.1
            Group {
                if let track = player.currentTrack {
                    if wide {
                        HStack(spacing: 40) {
                            artwork(track, side: min(proxy.size.height - 80, proxy.size.width / 2 - 60))
                            controls(track).frame(maxWidth: 440)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 28) {
                            Spacer(minLength: 0)
                            artwork(track, side: min(proxy.size.width - 48, proxy.size.height * 0.5))
                            controls(track)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 24)
                    }
                } else {
                    ContentUnavailableView { Label("player.nothingPlaying", systemImage: "music.note") }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.background)
        .overlay(alignment: .topLeading) {
            Button { dismiss(); model.showNowPlaying = false } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel(Text("common.collapse"))
            .keyboardShortcut(.cancelAction)
        }
    }

    private func artwork(_ track: Track, side: CGFloat) -> some View {
        NowPlayingArtwork(url: track.artworkURL, side: max(120, side))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            .accessibilityHidden(true)
    }

    private func controls(_ track: Track) -> some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlayerStatusLine(font: .title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SeekBar()
            HStack(spacing: 36) {
                PreviousButton(size: .title)
                PlayPauseButton(size: .largeTitle)
                NextButton(size: .title)
            }
            HStack {
                Spacer()
                RoutePickerButton()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text("player.airplay"))
                Spacer()
            }
        }
    }
}

/// Большая обложка «Сейчас играет» (задание 0008): кадр видео — целиком, прямоугольником 16:9 той же ширины;
/// песня и обложка сингла из видео-«статики» (после срезки полей она квадратная) — квадрат. Форма — по картинке
/// после срезки полей: шире 1,2:1 — прямоугольник.
struct NowPlayingArtwork: View {
    let url: String?
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var wide = false

    var body: some View {
        ArtworkView(url: url, size: side, shape: wide ? .wide : .rounded)
            .animation(.snappy, value: wide)
            .task(id: url) {
                wide = false
                guard Thumbnails.isWide(url) else { return }
                let sized = Thumbnails.sized(url, px: Int((side * displayScale).rounded(.up)))
                if let image = await ArtworkLoader.shared.image(sized) {
                    wide = Double(image.width) > Double(image.height) * 1.2
                }
            }
    }
}
