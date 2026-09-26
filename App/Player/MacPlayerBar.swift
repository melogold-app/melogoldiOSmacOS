#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Панель воспроизведения Mac (docs/PROMPT.md §5.4) — внизу окна во всю ширину, как у Windows:
/// слева обложка, название и исполнитель (обложка открывает «Сейчас играет»); в центре ⏮ ⏯ ⏭ и ползунок перемотки;
/// справа AirPlay и громкость. ♡ — у названия, ⇄ и ⟲ — по краям ⏮ ⏯ ⏭. «Текст» и «Очередь» — срезы 6 и 7.
struct MacPlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        if let track = player.currentTrack {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    Button { model.showNowPlaying = true } label: {
                        ArtworkView(url: track.artworkURL, size: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("player.openNowPlaying"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.headline).lineLimit(1)
                        PlayerStatusLine(font: .subheadline)
                    }
                    LikeButton(size: .body)
                }
                .frame(width: 300, alignment: .leading)

                VStack(spacing: 2) {
                    HStack(spacing: 20) {
                        ShuffleToggle()
                        PreviousButton(size: .title3)
                        PlayPauseButton(size: .title)
                        NextButton(size: .title3)
                        RepeatToggle()
                    }
                    SeekBar()
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    Button {
                        if model.showNowPlaying && model.lyricsVisible {
                            model.showNowPlaying = false
                        } else {
                            model.lyricsVisible = true
                            model.showNowPlaying = true
                        }
                    } label: {
                        Image(systemName: model.showNowPlaying && model.lyricsVisible ? "quote.bubble.fill" : "quote.bubble")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("player.lyrics"))
                    .accessibilityLabel(Text("player.lyrics"))
                    RoutePickerButton()
                        .frame(width: 28, height: 28)
                        .accessibilityLabel(Text("player.airplay"))
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        .frame(width: 100)
                        .accessibilityLabel(Text("player.volume"))
                }
                .frame(width: 230, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
#endif
