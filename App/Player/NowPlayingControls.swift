import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Блоки управления «Сейчас играет» (docs/PROMPT.md §5.7), общие для iPhone, iPad, Mac и Vision: название и ♡,
/// стеклянный транспорт, панель режимов и действий. Каждый блок знает два вида — обычный и компактный (под текстом
/// песни и в низком окне): тот же состав, размеры меньше, чтобы текст занимал больше места.

/// Название и исполнитель (без многоточия до двух строк), справа ♡.
struct NowPlayingTitle: View {
    let track: Track
    var large = false

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(large ? Font.title.weight(.bold) : .playerTitle)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlayerStatusLine(font: large ? .title3 : .playerArtist)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LikeButton(size: large ? .title : .title2)
        }
    }
}

/// ⏮ ⏯ ⏭ на стекле: три круглые кнопки в одной группе (`GlassEffectContainer`) — появление индикатора и «Повторить»
/// система морфит из соседних капель, а не заменяет рывком.
struct TransportRow: View {
    var compact = false
    @Namespace private var namespace

    var body: some View {
        let skip = compact ? Design.Size.compactSkipButton : Design.Size.skipButton
        let play = compact ? Design.Size.compactPlayButton : Design.Size.playButton
        ControlGlassGroup(spacing: Design.Space.m) {
            HStack(spacing: compact ? Design.Space.m : Design.Space.l) {
                PreviousButton(glass: GlassSpec(diameter: skip, namespace: namespace))
                PlayPauseButton(glass: GlassSpec(diameter: play, namespace: namespace))
                NextButton(glass: GlassSpec(diameter: skip, namespace: namespace))
            }
        }
        .iconTypeSize()
    }
}

/// Кнопка «Текст»: включает и выключает показ текста песни; включённая — акцентом.
struct LyricsToggleButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3

    var body: some View {
        Button {
            withAnimation(.snappy) { model.lyricsVisible.toggle() }
        } label: {
            Image(systemName: model.lyricsVisible ? "quote.bubble.fill" : "quote.bubble")
                .font(size)
                .controlSymbol(active: model.lyricsVisible)
                .frame(minWidth: Design.Size.minTap, minHeight: Design.Size.minTap)
                .contentShape(Rectangle())
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
            Image(systemName: "list.bullet")
                .font(size)
                .controlSymbol(active: model.queueVisible)
                .frame(minWidth: Design.Size.minTap, minHeight: Design.Size.minTap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: model.queueVisible)
        .accessibilityLabel(Text("player.queue"))
        .accessibilityAddTraits(model.queueVisible ? .isSelected : [])
    }
}

/// Панель режимов и действий одной стеклянной капсулой (HIG «Toolbars»: значки без рамок, сгруппированы): ⇄ ⟲ — режимы
/// (в компактном виде их нет, они в очереди и на обычном экране), затем «Текст», «Очередь», AirPlay, «…». Шире одного ряда
/// не бывает: значки не растут с Dynamic Type дальше `xxxLarge`.
struct PlayerActionBar: View {
    var includesModes = true

    var body: some View {
        ControlGlassGroup {
            HStack(spacing: 2) {
                if includesModes {
                    ShuffleToggle(size: .title3)
                    RepeatToggle(size: .title3)
                    Divider().frame(height: 22).padding(.horizontal, 2)
                }
                LyricsToggleButton()
                QueueToggleButton()
                #if !os(visionOS)
                RoutePickerButton()
                    .frame(width: Design.Size.minTap, height: Design.Size.minTap)
                    .accessibilityLabel(Text("player.airplay"))
                #endif
                PlayerMoreMenu()
            }
            .padding(.horizontal, Design.Space.xs)
            .iconTypeSize()
            .controlGlass(Capsule())
        }
    }
}
