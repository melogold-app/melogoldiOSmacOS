#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Панель воспроизведения Mac (docs/PROMPT.md §5.4, решение остаётся: внизу окна во всю ширину) — плавающая панель на
/// стекле Liquid Glass с отступами от краёв окна, а не прибитая полоса: список и боковая панель заканчиваются над ней
/// (`safeAreaBar` в `SplitShell`), содержимое уходит под неё с мягким затуханием.
///
/// Слева обложка, название, исполнитель (обложка открывает «Сейчас играет») и ♡; в центре ⇄ ⏮ ⏯ ⏭ ⟲ и полоса перемотки
/// со временем; справа «Текст», «Очередь», AirPlay, громкость и «…». Раскладка считается от ширины окна: в окне 720 pt
/// сначала исчезает громкость (она есть в «Сейчас играет» и в системе), затем ⇄ и ⟲ — центр не сжимается меньше 260 pt.
struct MacPlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track = model.services.player.currentTrack {
            GeometryReader { proxy in
                let width = proxy.size.width
                let volume = width >= 1000
                let modes = width >= 760
                let side: CGFloat = min(300, max(150, width * 0.24))
                HStack(spacing: Design.Space.m) {
                    left(track)
                        .frame(width: side, alignment: .leading)
                    center(modes: modes)
                        .frame(maxWidth: .infinity)
                    right(volume: volume)
                        .frame(width: volume ? 280 : 168, alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 60)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            .controlGlass(RoundedRectangle(cornerRadius: Design.Radius.bar, style: .continuous))
            .padding(.horizontal, Design.Space.s)
            .padding(.bottom, Design.Space.s)
        }
    }

    private func left(_ track: Track) -> some View {
        HStack(spacing: Design.Space.s) {
            Button { model.showNowPlaying = true } label: {
                ArtworkView(url: track.artworkURL, size: 48, cornerRadius: Design.Radius.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("player.openNowPlaying"))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                PlayerStatusLine(font: .subheadline)
            }
            LikeButton(size: .body)
        }
    }

    private func center(modes: Bool) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: Design.Space.m) {
                if modes { ShuffleToggle(size: .body) }
                PreviousButton(size: .title3)
                PlayPauseButton(size: .title)
                NextButton(size: .title3)
                if modes { RepeatToggle(size: .body) }
            }
            .frame(height: 36)
            SeekBar(style: .compact)
                .frame(maxWidth: 520)
        }
    }

    private func right(volume: Bool) -> some View {
        HStack(spacing: Design.Space.xs) {
            LyricsToggleButton(size: .body)
                .help(Text("player.lyrics"))
            QueueToggleButton(size: .body)
                .help(Text("player.queue"))
            RoutePickerButton()
                .frame(width: 28, height: 28)
                .accessibilityLabel(Text("player.airplay"))
            if volume {
                VolumeBar()
                    .frame(width: 110)
            }
            PlayerMoreMenu(size: .body)
        }
    }
}
#endif
