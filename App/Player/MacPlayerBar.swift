#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Панель воспроизведения Mac — плавающая капсула на стекле Liquid Glass внизу окна, по центру, в одну строку, как в
/// «Музыке» macOS 26+ (снимок пользователя 2026-10-02). HIG вообще просит не ставить управление внизу окна, но системный
/// музыкальный плеер Apple держит его здесь — запись в `docs/design/EXCEPTIONS.md`. Списки окна заканчиваются над
/// капсулой (`safeAreaBar` и поле прокрутки в `SplitShell`).
///
/// Слева ⇄ ⏮ ⏯ ⏭ ⟲; в центре обложка (нажатие открывает «Сейчас играет»), название (нажатие — альбом), исполнитель и
/// альбом (нажатие — исполнитель), под ними тонкая полоса перемотки; справа «…», «Текст», «Очередь», AirPlay, «Мини-плеер» и
/// громкость. Кнопки — те же компоненты, что в «Сейчас играет» (`PlayerControls`); у каждой подсказка, название для
/// VoiceOver и путь с клавиатуры; все команды есть и в меню «Управление». В узком окне сначала уходит громкость, затем
/// ⇄ и ⟲.
struct MacPlayerBar: View {
    @Environment(AppModel.self) private var model

    private enum Metrics {
        static let content: CGFloat = 40
        static let cover: CGFloat = 30
        static let button: CGFloat = 28
        static let inset: CGFloat = 12
        static let maxWidth: CGFloat = 860
    }

    /// Сколько от низа окна занимает капсула с отступом и зазором: на столько списки окна получают нижнее поле прокрутки
    /// (`SplitShell`), иначе последние строки остаются под капсулой.
    static let reservedHeight: CGFloat = Metrics.content + Design.Space.xxs * 2 + Metrics.inset + Design.Space.xs

    var body: some View {
        if model.hasPlayer {
            let track = model.playingTrack
            GeometryReader { proxy in
                let width = min(Metrics.maxWidth, proxy.size.width - Metrics.inset * 2)
                let volume = width >= 820
                let modes = width >= 640
                HStack(spacing: Design.Space.s) {
                    transport(modes: modes)
                    screen(track)
                        .frame(maxWidth: .infinity)
                    trailing(volume: volume)
                }
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, Design.Space.xxs)
                .frame(width: width, height: Metrics.content + Design.Space.xxs * 2)
                .background { Backing() }
                .glassEffect(.regular, in: Capsule())
                .frame(maxWidth: .infinity)
            }
            .frame(height: Metrics.content + Design.Space.xxs * 2)
            .padding(.bottom, Metrics.inset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("player.bar"))
        }
    }

    // MARK: - Слева: ⇄ ⏮ ⏯ ⏭ ⟲

    private func transport(modes: Bool) -> some View {
        HStack(spacing: 2) {
            if modes {
                ShuffleToggle(size: .callout, tap: Metrics.button)
                    .help(Text("player.shuffle"))
            }
            PreviousButton(glass: GlassSpec(diameter: Metrics.button, glass: false))
                .help(Text("player.previous"))
            PlayPauseButton(glass: GlassSpec(diameter: 34, glass: false))
                .help(Text(model.playingIsPlaying ? "player.pause" : "player.play"))
            NextButton(glass: GlassSpec(diameter: Metrics.button, glass: false))
                .help(Text("player.next"))
            if modes {
                RepeatToggle(size: .callout, tap: Metrics.button)
                    .help(Text("player.repeat"))
            }
        }
    }

    // MARK: - В центре: обложка, название, исполнитель, тонкая полоса перемотки

    /// `track` — `nil`, пока на выбранном другом устройстве ничего не играет: «Ничего не играет» и где.
    private func screen(_ track: Track?) -> some View {
        HStack(spacing: Design.Space.xs) {
            CoverButton(url: track?.artworkURL, size: Metrics.cover) { if track != nil { model.showNowPlaying = true } }
            VStack(alignment: .leading, spacing: 1) {
                if let track, track.albumId != nil {
                    LinkText(text: track.title, prominent: true, hint: "menu.goToAlbum") { model.openAlbum(of: track) }
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                } else if let track {
                    Text(verbatim: track.title).font(.callout.weight(.semibold)).lineLimit(1).foregroundStyle(Color.fullContrast)
                } else {
                    Text("remote.nothingPlaying").font(.callout.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
                }
                PlayerStatusLine(font: .caption) { if let track { model.openArtist(of: track) } }
                SeekBar(style: .hairline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Справа: «…», текст, очередь, AirPlay, мини-плеер, громкость

    private func trailing(volume: Bool) -> some View {
        HStack(spacing: 2) {
            PlayerMoreMenu(size: .callout, tap: Metrics.button)
                .help(Text("menu.more"))
            BarIconButton(symbol: "quote.bubble", activeSymbol: "quote.bubble.fill", active: model.lyricsShown, label: "player.lyrics") {
                withMotion(.snappy) { model.toggleLyrics() }
            }
            BarIconButton(symbol: "list.bullet", active: model.queueVisible, label: "player.queue") {
                model.toggleQueue()
            }
            RoutePickerButton()
                .frame(width: Metrics.button, height: Metrics.button)
                .help(Text("player.airplay"))
                .accessibilityLabel(Text("player.airplay"))
            BarIconButton(symbol: "pip.enter", active: false, label: "window.miniPlayer") {
                MiniPlayerPanel.shared.toggle(model: model)
            }
            if volume {
                VolumeBar()
                    .frame(width: 90)
                    .padding(.leading, Design.Space.xxs)
            }
        }
    }
}

/// Подложка под стеклом панели: стекло само содержимое под собой не размывает (в активном окне строки списка, ушедшие под
/// панель, просвечивали резко и спорили со значками), поэтому под ним — тонкий материал, он размывает то, что под панелью.
private struct Backing: View {
    var body: some View {
        Capsule().fill(.thinMaterial)
    }
}

/// Обложка панели: нажатие открывает «Сейчас играет»; под указателем — затемнение и стрелка вверх, как у Music.app.
private struct CoverButton: View {
    let url: String?
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ArtworkView(url: url, size: size, cornerRadius: Design.Radius.small)
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        .fill(.black.opacity(hovering ? 0.35 : 0))
                        .overlay {
                            Image(systemName: "chevron.up")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .opacity(hovering ? 1 : 0)
                        }
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("player.openNowPlaying"))
        .accessibilityLabel(Text("player.openNowPlaying"))
    }
}

/// Кнопка-значок правой части панели: зона нажатия 30 pt, значок во весь контраст (как в «Музыке»), включённая — на мягкой
/// подложке, под указателем подсвечивается.
private struct BarIconButton: View {
    let symbol: String
    var activeSymbol: String?
    let active: Bool
    let label: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? (activeSymbol ?? symbol) : symbol)
                .font(.callout)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.fullContrast)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        .fill(.primary.opacity(active ? 0.12 : 0))
                }
                .hoverHighlight(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
                .contentShape(Rectangle())
                .symbolReplace()
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
#endif
