#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Панель воспроизведения Mac (docs/PROMPT.md §5.4, решение остаётся: внизу окна во всю ширину) — плавающая панель на
/// стекле Liquid Glass с отступами от краёв окна, а не прибитая полоса: список и боковая панель заканчиваются над ней
/// (`safeAreaBar` в `SplitShell`), содержимое уходит под неё с мягким затуханием. Углы панели — концентричные углам окна.
///
/// Слева обложка (нажатие открывает «Сейчас играет»), название (нажатие — альбом), исполнитель (нажатие — исполнитель) и
/// ♡; в центре ⇄ ⏮ ⏯ ⏭ ⟲ и полоса перемотки со временем; справа «Текст», «Очередь», AirPlay, «Мини-плеер», громкость и «…».
/// Кнопки — те же компоненты, что в «Сейчас играет» (`PlayerControls`), под указателем подсвечиваются; у каждой есть
/// подсказка, название для VoiceOver и путь с клавиатуры (Tab). Раскладка считается от ширины окна: в окне 720 pt
/// сначала исчезает громкость (она есть в «Сейчас играет» и в системе), затем ⇄ и ⟲ — центр не сжимается меньше 240 pt.
struct MacPlayerBar: View {
    @Environment(AppModel.self) private var model

    /// Размеры панели: высота содержимого 52 pt (обложка 48, ряд транспорта 40 и полоса 12), отступы 8 и 10 pt.
    private enum Metrics {
        static let content: CGFloat = 52
        static let cover: CGFloat = 48
        static let button: CGFloat = 30
        static let inset: CGFloat = 10
    }

    /// Сколько от низа окна занимает панель вместе с отступами и небольшим зазором: на столько списки окна получают нижнее
    /// поле прокрутки (`SplitShell`), иначе последние строки (в Настройках — «Лицензии», в Библиотеке — «Импорт») остаются
    /// под панелью и до них не долистать (0.2.0, 30.09.2026).
    static let reservedHeight: CGFloat = Metrics.content + Design.Space.xs * 2 + Metrics.inset + Design.Space.xs

    var body: some View {
        if let track = model.services.player.currentTrack {
            GeometryReader { proxy in
                let width = proxy.size.width
                let volume = width >= 1000
                let modes = width >= 760
                let side: CGFloat = min(300, max(215, width * 0.3))
                HStack(spacing: Design.Space.m) {
                    left(track)
                        .frame(width: side, alignment: .leading)
                    center(modes: modes)
                        .frame(maxWidth: .infinity)
                    right(volume: volume)
                        .frame(width: volume ? 280 : 158, alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: Metrics.content)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            .background { Backing() }
            .glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(Design.Radius.small)), isUniform: true))
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, Metrics.inset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("player.bar"))
        }
    }

    // MARK: - Слева: обложка, название, исполнитель, ♡

    private func left(_ track: Track) -> some View {
        HStack(spacing: Design.Space.s) {
            CoverButton(url: track.artworkURL, size: Metrics.cover) { model.showNowPlaying = true }
            VStack(alignment: .leading, spacing: 1) {
                if track.albumId != nil {
                    LinkText(text: track.title, prominent: true, hint: "menu.goToAlbum") { model.openAlbum(of: track) }
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    Text(verbatim: track.title).font(.headline).lineLimit(1)
                }
                PlayerStatusLine(font: .subheadline) { model.openArtist(of: track) }
            }
            .layoutPriority(1)
            LikeButton(size: .callout, tap: Metrics.button)
                .help(Text(model.isLiked(track) ? "menu.unlike" : "menu.like"))
            Spacer(minLength: 0)
        }
    }

    // MARK: - В центре: транспорт и полоса перемотки

    private func center(modes: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.s) {
                if modes {
                    ShuffleToggle(size: .callout, tap: Metrics.button)
                        .help(Text("player.shuffle"))
                }
                PreviousButton(glass: GlassSpec(diameter: 34, glass: false))
                    .help(Text("player.previous"))
                PlayPauseButton(glass: GlassSpec(diameter: 40, glass: false))
                    .help(Text(model.services.player.isPlaying ? "player.pause" : "player.play"))
                NextButton(glass: GlassSpec(diameter: 34, glass: false))
                    .help(Text("player.next"))
                if modes {
                    RepeatToggle(size: .callout, tap: Metrics.button)
                        .help(Text("player.repeat"))
                }
            }
            .frame(height: 40)
            SeekBar(style: .compact)
                .frame(maxWidth: 520)
                .frame(height: 12)
        }
    }

    // MARK: - Справа: текст, очередь, AirPlay, мини-плеер, громкость, «…»

    private func right(volume: Bool) -> some View {
        HStack(spacing: 2) {
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
                    .frame(width: 110)
                    .padding(.horizontal, Design.Space.xs)
            }
            PlayerMoreMenu(size: .callout, tap: Metrics.button)
                .help(Text("menu.more"))
        }
    }
}

/// Подложка под стеклом панели: стекло само содержимое под собой не размывает (в активном окне строки списка, ушедшие под
/// панель, просвечивали резко и спорили со значками), поэтому под ним — тонкий материал, он размывает то, что под панелью.
private struct Backing: View {
    var body: some View {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Design.Radius.small)), isUniform: true)
            .fill(.thinMaterial)
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

/// Кнопка-значок правой части панели: зона нажатия 30 pt, включённая — на мягкой подложке, под указателем подсвечивается.
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
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
