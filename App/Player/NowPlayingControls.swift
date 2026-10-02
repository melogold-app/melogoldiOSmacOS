import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Блоки управления «Сейчас играет» (docs/PROMPT.md §5.7), общие для iPhone, iPad, Mac и Vision. Раскладка — как у Apple
/// Music: под обложкой название с ♡ и «…», полоса перемотки, ряд ⇄ ⏮ ⏯ ⏭ ⟲ значками без рамок, громкость (iPhone и
/// iPad), внизу «Текст», AirPlay и «Очередь» поровну по ширине. Каждый блок знает обычный и компактный вид (под текстом
/// песни и в низком окне): тот же состав, размеры меньше, режимы ⇄ ⟲ убраны.

/// Название и исполнитель (без многоточия до двух строк), справа ♡ и «…» — действия с треком рядом с ним.
struct NowPlayingTitle: View {
    let track: Track
    var large = false

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(large ? Font.title.weight(.bold) : .playerTitle)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlayerStatusLine(font: large ? .title3 : .playerArtist, detailed: true, onTint: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TrackActionCircles(size: large ? .title3 : .body)
        }
    }
}

/// ♡ и «…» в стеклянных кругах одного размера: у названия в «Сейчас играет» и в шапке над текстом.
struct TrackActionCircles: View {
    var size: Font = .body

    var body: some View {
        ControlGlassGroup(spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                LikeButton(size: size, circle: true)
                PlayerMoreMenu(size: size, circle: true)
            }
        }
        .iconTypeSize()
    }
}

/// ⇄ ⏮ ⏯ ⏭ ⟲ одним рядом во всю ширину: значки без рамок, под пальцем проступает круг (`TransportPressStyle`). Режимы
/// по краям мельче и приглушены, включённый — акцентом. В компактном виде (рядом с текстом) режимы гаснут, а ⏮ ⏯ ⏭
/// становятся меньше — это тот же ряд с теми же кнопками, поэтому при переключении текста он плавно меняет размер, а не
/// растворяется одним рядом и появляется другим (пользователь, 2026-10-02: «анимации отстой»).
struct TransportRow: View {
    var compact = false

    var body: some View {
        let skip = compact ? Design.Size.compactSkipButton : Design.Size.skipButton
        let play = compact ? Design.Size.compactPlayButton : Design.Size.playButton
        HStack(spacing: 0) {
            ShuffleToggle(size: .title3, muted: true)
                .modeHidden(compact)
            Spacer(minLength: 0)
            PreviousButton(glass: GlassSpec(diameter: skip, glass: false))
            Spacer(minLength: 0)
            PlayPauseButton(glass: GlassSpec(diameter: play, glass: false))
            Spacer(minLength: 0)
            NextButton(glass: GlassSpec(diameter: skip, glass: false))
            Spacer(minLength: 0)
            RepeatToggle(size: .title3, muted: true)
                .modeHidden(compact)
        }
        .iconTypeSize()
    }
}

private extension View {
    /// Перемешивание и повтор в компактном ряду: место остаётся, кнопки гаснут и не нажимаются.
    func modeHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

/// Кнопка нижнего ряда: значок приглушён, включённый — ярче, заливкой и на мягкой подложке (как «Текст» у Apple Music).
private struct ActionSymbol: View {
    @Environment(\.secondaryOnTint) private var secondaryTint
    let name: String
    var activeName: String?
    let active: Bool
    let size: Font

    var body: some View {
        Image(systemName: active ? (activeName ?? name) : name)
            .font(size)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(secondaryTint))
            .frame(width: Design.Size.minTap, height: Design.Size.minTap)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                    .fill(.primary.opacity(active ? 0.12 : 0))
            }
            .contentShape(Rectangle())
            .symbolReplace()
    }
}

/// Кнопка «Текст»: включает и выключает показ текста песни.
struct LyricsToggleButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3

    var body: some View {
        Button {
            withMotion(.snappy) { model.lyricsVisible.toggle() }
        } label: {
            ActionSymbol(name: "quote.bubble", activeName: "quote.bubble.fill", active: model.lyricsVisible, size: size)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: model.lyricsVisible)
        .accessibilityLabel(Text("player.lyrics"))
        .accessibilityAddTraits(model.lyricsVisible ? .isSelected : [])
    }
}

/// Кнопка «Очередь»: лист на iPhone и Vision, колонка справа на iPad и Mac.
struct QueueToggleButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3

    var body: some View {
        Button {
            model.queueVisible.toggle()
        } label: {
            ActionSymbol(name: "list.bullet", active: model.queueVisible, size: size)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: model.queueVisible)
        .accessibilityLabel(Text("player.queue"))
        .accessibilityAddTraits(model.queueVisible ? .isSelected : [])
    }
}

/// Нижний ряд: «Текст», «Устройство» (AirPlay или лист пульта, задание 0020), «Очередь» поровну по ширине, одного цвета;
/// над ним — «Играет на «…»», пока пульт управляет другим устройством. «…» — у названия, режимы — в ряду транспорта.
struct PlayerActionBar: View {
    var body: some View {
        VStack(spacing: Design.Space.xs) {
            RemotePlayingPill()
            HStack(spacing: 0) {
                LyricsToggleButton()
                Spacer(minLength: 0)
                DeviceButton()
                Spacer(minLength: 0)
                QueueToggleButton()
            }
            .padding(.horizontal, Design.Space.l)
        }
        .iconTypeSize()
    }
}

#if os(iOS)
/// Громкость устройства: системный `MPVolumeView` между значками динамика (HIG «Playing audio»).
struct VolumeRow: View {
    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: "speaker.fill")
            SystemVolumeView()
                .frame(height: 34)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.footnote)
        .secondaryOnTint()
        .accessibilityElement(children: .contain)
    }
}
#endif
