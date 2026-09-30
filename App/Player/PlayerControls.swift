import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Подпись под названием: исполнитель; пока нет потока — «Получаем поток…» (3 с) и «Долго… · Пропустить» (15 с);
/// при ошибке — причина словами (docs/PROMPT.md §5.7, REWRITE §3.10.9).
struct PlayerStatusLine: View {
    @Environment(AppModel.self) private var model
    var font: Font = .subheadline
    /// Нажатие на исполнителя (панель воспроизведения Mac: «по исполнителю — исполнитель», docs/PROMPT.md §5.4).
    var onArtistTap: (() -> Void)?

    var body: some View {
        let player = model.services.player
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if player.phase == .failed, let failure = player.failure {
                    Label(failure.text, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                } else if player.phase == .loading, let since = player.loadingSince, context.date.timeIntervalSince(since) >= 15 {
                    Text("player.slow")
                        .foregroundStyle(.secondary)
                } else if player.phase == .loading, let since = player.loadingSince, context.date.timeIntervalSince(since) >= 3 {
                    Text("player.gettingStream")
                        .foregroundStyle(.secondary)
                } else if let onArtistTap, player.currentTrack?.primaryArtistId != nil {
                    LinkText(text: player.currentTrack?.artistsText ?? "", hint: "menu.goToArtist", action: onArtistTap)
                } else {
                    Text(player.currentTrack?.artistsText ?? "")
                        .foregroundStyle(.secondary)
                }
            }
            .font(font)
            .lineLimit(1)
        }
    }
}

/// Текст-ссылка панели воспроизведения Mac: приглушённый, при наведении — подчёркнутый и обычным цветом; для
/// VoiceOver — кнопка. Вне Mac наведения нет, остаётся кнопка без оформления.
struct LinkText: View {
    let text: String
    /// Название, а не подпись: в покое обычным цветом.
    var prominent = false
    /// Что сделает нажатие — для VoiceOver («Открыть исполнителя»).
    var hint: LocalizedStringResource?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .underline(hovering)
                .foregroundStyle(hovering || prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
        .onHover { hovering = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
    }
}

/// Как рисовать кнопку транспорта крупно: `diameter` — круг нажатия. `glass` — постоянный стеклянный круг (редактор
/// текста), иначе значок без рамки, как у Apple Music, а круг проступает только под пальцем (`TransportPressStyle`).
/// `namespace` включает морфинг стекла внутри `ControlGlassGroup`.
struct GlassSpec {
    var diameter: CGFloat
    var namespace: Namespace.ID?
    var glass = true
}

/// Значок транспорта: шрифт `size` без оформления или размер по диаметру стекла.
private struct TransportSymbol: View {
    let name: String
    let size: Font
    let glass: GlassSpec?

    var body: some View {
        if let glass {
            // Без стекла значок крупнее: он сам и есть кнопка
            Image(systemName: name)
                .font(.system(size: glass.diameter * (glass.glass ? 0.36 : 0.5), weight: .semibold))
                .frame(width: glass.diameter, height: glass.diameter)
                .contentShape(Circle())
        } else {
            Image(systemName: name)
                .font(size)
                .frame(minWidth: Design.Size.minTap, minHeight: Design.Size.minTap)
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    /// Оформление кнопки транспорта: стеклянный круг, круг под пальцем или ничего (мини-плеер, панель Mac).
    @ViewBuilder
    func transportGlass(_ glass: GlassSpec?, id: String) -> some View {
        if let glass, glass.glass {
            buttonStyle(.plain).glassCircle(glass.diameter, id: id, in: glass.namespace)
        } else if let glass {
            buttonStyle(TransportPressStyle(diameter: glass.diameter))
        } else {
            buttonStyle(.plain)
        }
    }
}

/// Нажатие крупной кнопки транспорта без рамки: значок чуть сжимается, под ним проступает мягкий круг — как у Apple
/// Music. На Mac круг мягче проступает и под указателем. Уменьшение движения — без сжатия.
struct TransportPressStyle: ButtonStyle {
    var diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        TransportPressBody(configuration: configuration, diameter: diameter)
    }
}

private struct TransportPressBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let fill = configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.07 : 0)
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background {
                Circle()
                    .fill(.primary.opacity(fill))
                    .frame(width: diameter, height: diameter)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.86 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// ⏯: пока нет потока — индикатор на его месте; при ошибке — «Повторить».
struct PlayPauseButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title2
    var glass: GlassSpec?
    @State private var taps = 0

    var body: some View {
        let player = model.services.player
        let symbol = player.phase == .failed ? "arrow.clockwise" : (player.isPlaying ? "pause.fill" : "play.fill")
        Button {
            taps += 1
            player.togglePlayPause()
        } label: {
            ZStack {
                if player.phase == .loading, player.isPlaying {
                    ProgressView()
                        .frame(width: glass?.diameter ?? Design.Size.minTap, height: glass?.diameter ?? Design.Size.minTap)
                } else {
                    TransportSymbol(name: symbol, size: size, glass: glass)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .animation(.snappy(duration: 0.25), value: symbol)
        }
        .transportGlass(glass, id: "playPause")
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .accessibilityLabel(Text(player.phase == .failed ? "common.retry" : (player.isPlaying ? "player.pause" : "player.play")))
    }
}

struct NextButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3
    var glass: GlassSpec?
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            model.services.player.next()
        } label: {
            TransportSymbol(name: "forward.fill", size: size, glass: glass)
        }
        .transportGlass(glass, id: "next")
        .disabled(!model.services.player.hasNext)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(Text("player.next"))
    }
}

struct PreviousButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3
    var glass: GlassSpec?
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            model.services.player.previous()
        } label: {
            TransportSymbol(name: "backward.fill", size: size, glass: glass)
        }
        .transportGlass(glass, id: "previous")
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(Text("player.previous"))
    }
}

/// Полоса перемотки (docs/PROMPT.md §5.7): капсула, при перетаскивании утолщается; перетаскивание относительное — от
/// того места, где была полоса, а не от точки нажатия, позиция применяется при отпускании; слева прошедшее время,
/// справа оставшееся со знаком минус. Начало и конец перетаскивания отзываются лёгким откликом; для VoiceOver — «Больше»
/// и «Меньше» на 10 секунд.
struct SeekBar: View {
    enum Style {
        /// «Сейчас играет»: тонкая капсула 6 pt, при перетаскивании 14 pt; зона нажатия — 44 pt.
        case large
        /// Панель воспроизведения Mac: капсула 4 pt, при наведении и перетаскивании 8 pt.
        case compact
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var style: Style = .large
    /// Позиция, с которой начался жест; значение под пальцем — `dragValue`.
    @State private var dragStart: Double?
    @State private var dragValue: Double?
    /// Только что отпустили: до ответа плеера полоса стоит там, куда её отпустили, а не прыгает назад.
    @State private var released: Double?
    @State private var hovering = false
    @State private var began = 0
    @State private var ended = 0

    var body: some View {
        let player = model.services.player
        let duration = max(player.duration, 0.1)
        let value = dragValue ?? released ?? min(player.position, duration)
        let dragging = dragValue != nil
        let thickness: CGFloat = switch style {
        case .large: dragging ? 14 : 6
        case .compact: dragging || hovering ? 8 : 4
        }
        let times = style == .large
        let bar = GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18))
                Capsule().fill(.primary.opacity(dragging ? 1 : 0.8))
                    .frame(width: max(thickness, width * value / duration))
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0, player.duration > 0 else { return }
                        if dragStart == nil {
                            dragStart = min(player.position, duration)
                            began += 1
                        }
                        let start = dragStart ?? 0
                        dragValue = min(duration, max(0, start + drag.translation.width / width * duration))
                    }
                    .onEnded { _ in
                        defer { dragStart = nil }
                        guard let target = dragValue else { return }
                        dragValue = nil
                        released = target
                        ended += 1
                        player.seek(to: target)
                    }
            )
        }
        .frame(height: times ? Design.Size.minTap - 8 : 16)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: thickness)
        let left = Text(verbatim: Durations.format(seconds: value))
        let right = Text(verbatim: "−" + Durations.format(seconds: max(0, duration - value)))
        Group {
            if times {
                // «Сейчас играет»: время под полосой
                VStack(spacing: 0) {
                    bar
                    HStack {
                        left
                        Spacer()
                        right
                    }
                    .font(.playerTime)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            } else {
                // Панель Mac: время по краям полосы в одну строку
                HStack(spacing: Design.Space.xs) {
                    left.frame(width: 42, alignment: .trailing)
                    bar
                    right.frame(width: 46, alignment: .leading)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .onHover { hovering = $0 }
        .disabled(player.duration <= 0)
        #if os(macOS)
        // С клавиатуры: Tab — на полосу, ← и → — на 5 секунд (как стрелки у ползунка системы)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: player.seek(to: max(0, player.position - 5))
            case .right: player.seek(to: min(duration, player.position + 5))
            default: break
            }
        }
        #endif
        .task(id: released) {
            guard released != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            released = nil
        }
        .sensoryFeedback(.impact(weight: .light), trigger: began)
        .sensoryFeedback(.selection, trigger: ended)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player.position"))
        .accessibilityValue(Text(verbatim: Durations.format(seconds: value)))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10.0 : -10.0
            player.seek(to: min(duration, max(0, player.position + step)))
        }
    }
}

extension PlaybackFailure {
    /// Текст карточки ошибки (REWRITE §3.10.9).
    var text: LocalizedStringResource {
        switch kind {
        case .network: "player.error.network"
        case .botCheck: "player.error.botCheck"
        case .geo: "player.error.geo"
        case .unavailable: "player.error.unavailable"
        case .age: "player.error.age"
        case .timeout: "player.error.timeout"
        case .extractor: "player.error.extractor"
        case .manySkips: "player.error.manySkips"
        case .noAudioRoute: "player.error.noRoute"
        }
    }

    /// Причина в плашке пропуска: «Пропущен „Трек“: недоступен в регионе».
    var shortText: LocalizedStringResource {
        switch kind {
        case .network: "player.skip.network"
        case .botCheck: "player.skip.botCheck"
        case .geo: "player.skip.geo"
        case .unavailable: "player.skip.unavailable"
        case .age: "player.skip.age"
        case .timeout: "player.skip.timeout"
        case .extractor, .manySkips: "player.skip.extractor"
        case .noAudioRoute: "player.skip.noRoute"
        }
    }
}

/// ♡ текущего трека: «В Избранное» и «Убрать из Избранного» сразу (docs/PROMPT.md §5.7). Заполненное сердце —
/// единственный цветной значок управления (`Design`).
struct LikeButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3
    /// В стеклянном круге (`TrackActionCircles`), а не просто значком.
    var circle = false
    /// Зона нажатия значка без круга: 44 pt на сенсорных экранах, меньше — на панели Mac.
    var tap: CGFloat = Design.Size.minTap
    @State private var taps = 0

    var body: some View {
        if let track = model.services.player.currentTrack, model.library != nil {
            let liked = model.isLiked(track)
            Button {
                taps += 1
                model.toggleLike(track)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(size.weight(.semibold))
                    .foregroundStyle(liked ? AnyShapeStyle(.pink) : AnyShapeStyle(circle ? .primary : .secondary))
                    .frame(minWidth: circle ? Design.Size.actionCircle : tap,
                           minHeight: circle ? Design.Size.actionCircle : tap)
                    .contentShape(circle ? AnyShape(Circle()) : AnyShape(Rectangle()))
                    .contentTransition(.symbolEffect(.replace))
                    .modifier(ActionCircleGlass(enabled: circle))
                    .hoverHighlight(Circle(), enabled: !circle)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
            .accessibilityLabel(Text(liked ? "menu.unlike" : "menu.like"))
        }
    }
}

/// ⇄: перемешать очередь после текущего трека.
struct ShuffleToggle: View {
    @Environment(AppModel.self) private var model
    var size: Font = .body
    /// Выключенный — приглушённым (ряд транспорта «Сейчас играет»).
    var muted = false
    /// Зона нажатия: 44 pt на сенсорных экранах, меньше — на панели Mac.
    var tap: CGFloat = Design.Size.minTap

    var body: some View {
        let player = model.services.player
        Button { player.setShuffled(!player.shuffled) } label: {
            Image(systemName: "shuffle")
                .font(size.weight(.semibold))
                .controlSymbol(active: player.shuffled, muted: muted)
                .frame(minWidth: tap, minHeight: tap)
                .contentShape(Rectangle())
                .hoverHighlight(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: player.shuffled)
        .accessibilityLabel(Text("player.shuffle"))
        .accessibilityValue(Text(player.shuffled ? "common.on" : "common.off"))
    }
}

/// ⟲: повтор — выкл · все · один.
struct RepeatToggle: View {
    @Environment(AppModel.self) private var model
    var size: Font = .body
    /// Выключенный — приглушённым (ряд транспорта «Сейчас играет»).
    var muted = false
    /// Зона нажатия: 44 pt на сенсорных экранах, меньше — на панели Mac.
    var tap: CGFloat = Design.Size.minTap

    var body: some View {
        let player = model.services.player
        Button {
            player.repeatMode = switch player.repeatMode {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        } label: {
            Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                .font(size.weight(.semibold))
                .controlSymbol(active: player.repeatMode != .off, muted: muted)
                .frame(minWidth: tap, minHeight: tap)
                .contentShape(Rectangle())
                .hoverHighlight(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
        .accessibilityLabel(Text("player.repeat"))
        .accessibilityValue(Text(player.repeatMode == .off ? "player.repeat.off" : player.repeatMode == .all ? "player.repeat.all" : "player.repeat.one"))
    }
}

/// Громкость приложения (Mac): те же капсула и жест, что у перемотки, значки динамика по краям. На iPhone и iPad
/// громкостью управляют кнопки и системный `MPVolumeView` (HIG «Sliders»: на iOS громкость — не `Slider`).
struct VolumeBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: Float?
    @State private var hovering = false

    var body: some View {
        let player = model.services.player
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
            GeometryReader { proxy in
                let width = proxy.size.width
                let thickness: CGFloat = dragStart != nil || hovering ? 8 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.18))
                    Capsule().fill(.primary.opacity(0.8)).frame(width: max(thickness, width * CGFloat(player.volume)))
                }
                .frame(height: thickness)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard width > 0 else { return }
                            if dragStart == nil { dragStart = player.volume }
                            player.volume = min(1, max(0, (dragStart ?? 0) + Float(drag.translation.width / width)))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .animation(.snappy(duration: 0.2), value: thickness)
            }
            .frame(height: 16)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
        }
        .onHover { hovering = $0 }
        #if os(macOS)
        // С клавиатуры: Tab — на полосу, ← и → — на 5 %
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: player.volume = max(0, player.volume - 0.05)
            case .right: player.volume = min(1, player.volume + 0.05)
            default: break
            }
        }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player.volume"))
        .accessibilityValue(Text(verbatim: "\(Int((player.volume * 100).rounded())) %"))
        .accessibilityAdjustableAction { direction in
            player.volume = min(1, max(0, player.volume + (direction == .increment ? 0.1 : -0.1)))
        }
    }
}

/// Стеклянный круг кнопки у названия (♡, «…»): интерактивное стекло поверх оттенка обложки.
struct ActionCircleGlass: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.controlGlass(Circle(), interactive: true) } else { content }
    }
}
