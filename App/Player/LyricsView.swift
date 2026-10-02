import SwiftUI
import MelogoldCore
import MelogoldLyrics
import MelogoldPlayback

/// Текст в «Сейчас играет» (docs/PROMPT.md §5.7, `spec/lyrics.md` «Отображение»): текущая строка яркая, прошедшие
/// приглушены сильнее будущих, без размытия и масштаба; пословный текст загорается по словам; подпевка мельче, под
/// строкой; строки второго исполнителя дуэта — у конечного края; нажатие по строке перематывает; ручная прокрутка
/// останавливает слежение на 3 с, есть «К текущей строке»; в паузе без слов точки появляются по одной и лопаются перед
/// строкой. Нет синхронного — обычный текст.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.services.lyrics
        VStack(spacing: 0) {
            switch lyrics.state {
            case .loading where !lyrics.hasAny:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound where !lyrics.hasAny, .idle:
                ContentUnavailableView {
                    Label("lyrics.notFound", systemImage: "text.quote")
                } actions: {
                    Button("lyrics.find") { model.openLyricsSearch() }
                }
            case .offline where !lyrics.hasAny:
                ContentUnavailableView {
                    Label("lyrics.offline", systemImage: "wifi.slash")
                } actions: {
                    Button("common.retry") { lyrics.retry() }
                }
            default:
                if lyrics.showingSynced {
                    // Свой вид на каждый трек: состояние прокрутки и рамок строк не переезжает на другой текст
                    SyncedLyricsView().id(lyrics.track?.videoId)
                } else {
                    PlainLyricsView(text: lyrics.plain ?? "")
                }
            }
            if lyrics.isCommunity {
                Text("lyrics.community")
                    .font(.caption)
                    .secondaryOnTint()
                    .padding(.vertical, 6)
            }
        }
        .onAppear { if let track = model.services.player.currentTrack { lyrics.load(track) } }
        .onChange(of: model.services.player.currentTrack?.videoId) {
            if let track = model.services.player.currentTrack { lyrics.load(track) }
        }
        #if os(iOS)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = model.settings.lyricsKeepScreenOn }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }
}

/// Пункты меню текста (docs/PROMPT.md §5.7): вид (подпись — по тому, что на экране), «Найти текст», «Редактировать текст»,
/// сдвиг ±0,1 и ±0,5 с. Живут в меню «…» плеера, в панели управления, а не отдельной кнопкой поверх первой строки
/// текста (`PlayerMenuItems`).
struct LyricsMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.services.lyrics
        if lyrics.synced != nil {
            Button {
                lyrics.preferSynced.toggle()
            } label: {
                if lyrics.showingSynced {
                    Label("lyrics.plainView", systemImage: "text.alignleft")
                } else {
                    Label("lyrics.syncedView", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
        }
        Button { model.openLyricsSearch() } label: { Label("lyrics.find", systemImage: "magnifyingglass") }
        #if !os(visionOS)
        Button { model.openLyricsEditor() } label: { Label("lyrics.edit", systemImage: "pencil") }
        #endif
        if lyrics.showingSynced {
            Menu {
                Button("lyrics.offset.minus05") { lyrics.shift(by: -500) }
                Button("lyrics.offset.minus01") { lyrics.shift(by: -100) }
                Button("lyrics.offset.plus01") { lyrics.shift(by: 100) }
                Button("lyrics.offset.plus05") { lyrics.shift(by: 500) }
                if lyrics.offsetMs != 0 {
                    Button("lyrics.offset.reset") { lyrics.shift(by: nil) }
                }
            } label: {
                Label {
                    Text("lyrics.offset \(OffsetFormat.label(lyrics.offsetMs))")
                } icon: {
                    Image(systemName: "timer")
                }
            }
        }
    }
}

/// «+0,3 с» по локали.
enum OffsetFormat {
    static func label(_ ms: Int64) -> String {
        let seconds = Double(ms) / 1000
        let number = seconds.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
        return number
    }
}

struct PlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.title3.weight(.semibold))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
        }
        .scrollIndicators(.hidden)
    }
}

/// Как выглядит текст песни: размер зависит от области (шире окно — крупнее текст, как у Windows и Android) и от Dynamic
/// Type; отступы подложки, подпевка и перевод считаются от него (задание 0012 §2).
enum LyricsStyle {
    /// Размер строки при обычной области и обычном Dynamic Type: `title` iPhone — 28.
    static let baseSize: CGFloat = 28
    /// Узкая раскладка: верх текущей строки — на 24 pt ниже верха области текста, сразу под полосой затухания кромки
    /// (задание 0016 §2, Android `LyricsAnchor`).
    static let anchor: CGFloat = 24
    /// Полоса затухания снизу — над панелью управления.
    static let bottomFade: CGFloat = 48

    /// Размер по области: растёт вместе с окном (как в «Музыке»: колонка 400 pt — 30, 600 pt — 45, 800 pt — 60), но не
    /// меньше `title` и не больше 64. Высота тоже ограничивает: в низком широком окне строки не должны занимать пол-экрана.
    static func fontSize(in size: CGSize) -> CGFloat {
        min(64, max(baseSize, min(size.width * 0.075, size.height * 0.08))).rounded()
    }

    /// Крупный Dynamic Type растит текст до 1,7 раза, но не шире, чем позволяет область: ширина ÷ 300 (iPhone в портрете —
    /// 1,34; колонка текста боком — 1,05…1,25; от 510 pt — 1,7), и всего не больше десятой доли ширины. Иначе длинное
    /// слово («клетчатый») не влезает в строку и ломается посередине.
    static func fontSize(in size: CGSize, typeScale: CGFloat) -> CGFloat {
        let base = fontSize(in: size)
        let scaled = base * min(typeScale, min(1.7, max(1, size.width / 300)))
        return min(scaled, max(base, size.width * 0.1)).rounded()
    }
}

/// Пространство координат «Сейчас играет»: обложка и текст сверяют в нём свои рамки.
let nowPlayingSpace = "nowPlaying.space"

/// Где стоит середина обложки в пространстве «Сейчас играет». Задаётся только в широкой раскладке (обложка слева, текст
/// справа): там середина текущей строки и её подложки — на уровне середины обложки (решение пользователя, 2026-09-30,
/// как в Linux-клиенте: взгляд идёт от обложки к строке по одной линии). В узкой раскладке и без обложки значения нет —
/// верх строки у верха области.
private struct LyricsCoverMidKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var lyricsCoverMid: CGFloat? {
        get { self[LyricsCoverMidKey.self] }
        set { self[LyricsCoverMidKey.self] = newValue }
    }
}

/// Рамки строк в координатах содержимого, вместе с полями строки: по ним стоят подложка и прокрутка к строке.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private let lyricsSpace = "lyrics.content"

struct SyncedLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lyricsCoverMid) private var coverMid
    @ScaledMetric(relativeTo: .title) private var typeScale: CGFloat = 1
    @State private var manualUntil: Date?
    @State private var followTick = 0
    @State private var frames: [Int: CGRect] = [:]
    /// Где текущая строка стоит сейчас: первая постановка — без анимации, смена строки — плавно.
    @State private var lastPlaced: Placement?

    var body: some View {
        let lyrics = model.services.lyrics
        let player = model.services.player
        let rows = lyrics.rows
        let position = lyrics.lyricsPosition(player.position)
        let active = LyricRows.activeIndex(rows, at: position)
        let following = manualUntil.map { $0 < Date() } ?? true
        GeometryReader { proxy in
            let fontSize = LyricsStyle.fontSize(in: proxy.size, typeScale: typeScale)
            let scale = fontSize / LyricsStyle.baseSize
            let height = proxy.size.height
            // Точка, где встаёт середина текущей строки, от верха области: по обложке, но не ближе пятой части высоты к краю
            let mid: CGFloat? = coverMid.map { min(max($0 - proxy.frame(in: .named(nowPlayingSpace)).minY, height * 0.2), height * 0.8) }
            let pill = rows.indices.contains(active) && rows[active].isSung ? frames[active] : nil
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4 * scale) {
                        // Широкая раскладка: над первой строкой место до точки, чтобы и она могла встать на середину обложки
                        if let mid {
                            Color.clear.frame(height: max(0, mid - (frames[0]?.height ?? 40) / 2 - LyricsStyle.anchor - 4 * scale))
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            LyricRowView(row: row, index: index, active: active, fontSize: fontSize)
                                .id(index)
                        }
                        // Последняя строка тоже может встать на своё место
                        Color.clear.frame(height: height)
                    }
                    .padding(.horizontal, Design.Space.s)
                    .coordinateSpace(name: lyricsSpace)
                    .onPreferenceChange(RowFramesKey.self) { frames = $0 }
                    .background(alignment: .topLeading) {
                        ActiveLinePill(target: pill, radius: Design.Radius.medium * scale)
                    }
                }
                .contentMargins(.top, LyricsStyle.anchor, for: .scrollContent)
                .scrollIndicators(.hidden)
                // Верх затухает на 24 pt, низ — над панелью управления; строки уходят в фон, а не обрезаются
                .mask(fadeMask(height: height))
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { manualUntil = Date().addingTimeInterval(3) }
                }
                // Одна задача ставит текущую строку на место после любой перемены, от которой оно зависит: строка, точка у
                // обложки, высота области, высота строки (известна, когда её показали), первая раскладка. Отдельные
                // `onChange` срабатывали раньше раскладки и терялись (Mac: строка оставалась внизу, 2026-09-30); `yield` —
                // прокрутка на следующем такте, по новой раскладке, с отступом над первой строкой
                .task(id: Placement(active: active, mid: mid, height: height, row: frames[active]?.height,
                                    laidOut: !frames.isEmpty, following: following)) {
                    guard following, active >= 0, !frames.isEmpty else { return }
                    await Task.yield()
                    let animation: Animation? = if reduceMotion || lastPlaced == nil {
                        nil
                    } else if lastPlaced?.active != active {
                        .smooth(duration: 0.45)
                    } else {
                        .smooth(duration: 0.25)
                    }
                    withAnimation(animation) {
                        reader.scrollTo(active, anchor: anchorPoint(active, height: height, mid: mid))
                    }
                    lastPlaced = Placement(active: active, mid: mid, height: height, row: frames[active]?.height,
                                           laidOut: true, following: true)
                }
                .overlay(alignment: .bottom) {
                    if !following, active >= 0 {
                        Button {
                            manualUntil = nil
                            withMotion { reader.scrollTo(active, anchor: anchorPoint(active, height: height, mid: mid)) }
                        } label: {
                            Label("lyrics.backToCurrent", systemImage: "arrow.down")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, Design.Space.m)
                                .padding(.vertical, Design.Space.xs)
                        }
                        .buttonStyle(.plain)
                        .controlGlass(Capsule(), interactive: true)
                        .padding(.bottom, Design.Space.s)
                        .slideUpTransition()
                    }
                }
                // Через 3 с после ручной прокрутки кнопка уходит, слежение возвращается.
                .task(id: manualUntil) {
                    guard let until = manualUntil else { return }
                    try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 0.1))
                    followTick += 1
                    if active >= 0 {
                        withAnimation(reduceMotion ? nil : .smooth) {
                            reader.scrollTo(active, anchor: anchorPoint(active, height: height, mid: mid))
                        }
                    }
                }
            }
        }
    }

    /// Куда встаёт строка `index` при прокрутке. Узкая раскладка — верх строки у верха области (после отступа). Широкая —
    /// середина строки в точке `mid`: `scrollTo` совмещает долю `y` строки с той же долей высоты области, поэтому доля
    /// считается по высоте самой строки (`frames`, у ещё не показанной — запас 44 pt).
    private func anchorPoint(_ index: Int, height: CGFloat, mid: CGFloat?) -> UnitPoint {
        guard let mid else { return .top }
        let row = frames[index]?.height ?? 44
        let free = height - LyricsStyle.anchor - row
        guard free > 1 else { return .top }
        return UnitPoint(x: 0.5, y: min(1, max(0, (mid - row / 2 - LyricsStyle.anchor) / free)))
    }

    private func fadeMask(height: CGFloat) -> some View {
        let top = min(0.4, LyricsStyle.anchor / max(1, height))
        let bottom = min(0.4, LyricsStyle.bottomFade / max(1, height))
        // Сверху затухание круче: прошедшая строка под шапкой едва видна, а не висит огрызком над текущей
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.08), location: top * 0.6),
            .init(color: .black, location: top),
            .init(color: .black, location: 1 - bottom),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

private extension LyricRow {
    var isSung: Bool {
        if case .sung = self { true } else { false }
    }
}

/// Подложка под текущей строкой (задание 0012): скруглённый прямоугольник по размеру строки — самая длинная строка
/// переноса, подпевка и перевод плюс поля. На следующую строку переезжает и меняет размер пружиной; без текущей строки
/// (до первой, проигрыш) гаснет за 0,2 с, а с новой строкой проявляется на её месте, не переезжая. Если строка сдвинулась
/// после раскладки (поворот, размер окна, Dynamic Type), догоняет. При «Уменьшении движения» встаёт на место сразу.
/// Нажатие не перехватывает.
private struct ActiveLinePill: View {
    let target: CGRect?
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var frame = CGRect.zero
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            #if os(visionOS)
            .fill(.regularMaterial)
            #else
            .fill(Color.primary.opacity(contrast == .increased ? 0.16 : 0.08))
            #endif
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            // Пока подложка не показана, рамка меняется без переезда: она проявляется там, где строка
            .animation(reduceMotion || !shown ? nil : .spring(response: 0.25, dampingFraction: 0.78), value: frame)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown)
            .allowsHitTesting(false)
            .onChange(of: target) { _, new in move(to: new) }
            .onAppear { move(to: target) }
    }

    private func move(to new: CGRect?) {
        guard let new else {
            shown = false
            return
        }
        frame = new
        guard !shown else { return }
        // Рамка встала без анимации; показ — на следующем кадре, уже с включённой анимацией рамки
        Task { @MainActor in
            await Task.yield()
            shown = target != nil
        }
    }
}

/// Строка текста: спетая — по словам, если есть время слов; проигрыш — три точки, пока он идёт.
private struct LyricRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let row: LyricRow
    let index: Int
    let active: Int
    /// Размер основной строки; поля подложки, подпевка, перевод и точки — от него (`LyricsStyle.baseSize` = 28).
    let fontSize: CGFloat

    private var scale: CGFloat { fontSize / LyricsStyle.baseSize }

    var body: some View {
        switch row {
        case .sung(let line):
            sung(line)
        case .interlude(let start, let end, let side):
            if index == active {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    InterludeDots(progress: progress(start, end), scale: scale)
                }
                .padding(.horizontal, 16 * scale)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: RowFramesKey.self, value: [index: proxy.frame(in: .named(lyricsSpace))])
                    }
                }
                .frame(maxWidth: .infinity, alignment: side == .end ? .trailing : .leading)
                .accessibilityHidden(true)
            }
        }
    }

    private func progress(_ start: Int64, _ end: Int64) -> Double {
        let position = model.services.lyrics.lyricsPosition(model.services.player.livePosition())
        return min(1, max(0, Double(position - start) / Double(max(1, end - start))))
    }

    private func sung(_ line: SyncedLine) -> some View {
        let isActive = index == active
        let isPast = index < active
        let alignment: HorizontalAlignment = line.side == .end ? .trailing : .leading
        return Button {
            let target = Double(line.startMs - model.services.lyrics.offsetMs) / 1000
            model.services.player.seek(to: max(0, target))
        } label: {
            // Подложка обводит строку вместе с полями: ширина — по самой длинной строке переноса, высота — вся строка
            // с подпевкой и переводом; строка второй стороны дуэта у конечного края — подложка тоже
            ShrinkWrap {
                VStack(alignment: alignment, spacing: 4 * scale) {
                    if isActive, !line.words.isEmpty {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                            words(line.words, size: fontSize, weight: .bold)
                        }
                    } else {
                        Text(verbatim: line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(color(isActive: isActive, isPast: isPast))
                    }
                    if let background = line.background {
                        if isActive, background.words.count > 1 {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                                words(background.words, size: fontSize * 0.64, weight: .semibold)
                            }
                        } else {
                            Text(verbatim: background.text)
                                .font(.system(size: fontSize * 0.64, weight: .semibold))
                                .foregroundStyle(color(isActive: isActive, isPast: isPast).opacity(0.8))
                        }
                    }
                    if let translation = line.translation {
                        Text(verbatim: translation)
                            .font(.system(size: fontSize * 0.57))
                            .secondaryOnTint()
                    }
                }
                .multilineTextAlignment(line.side == .end ? .trailing : .leading)
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 10 * scale)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: RowFramesKey.self, value: [index: proxy.frame(in: .named(lyricsSpace))])
                }
            }
            .frame(maxWidth: .infinity, alignment: line.side == .end ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: isActive)
        // VoiceOver: строка целиком, подпевка и перевод — значением; текущая строка отмечена; двойное касание перематывает
        .accessibilityLabel(Text(verbatim: line.text))
        .accessibilityValue(Text(verbatim: [line.background?.text, line.translation].compactMap { $0 }.joined(separator: ". ")))
        .accessibilityHint(Text("lyrics.tapToSeek"))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// Прошедшие строки приглушены сильнее будущих (docs/PROMPT.md §5.7), но обе читаются (`Design.lyricsDim`).
    private func color(isActive: Bool, isPast: Bool) -> AnyShapeStyle {
        if isActive { return AnyShapeStyle(Color.fullContrast) }
        return AnyShapeStyle(Design.lyricsDim(past: isPast, increasedContrast: contrast == .increased))
    }

    /// Слова загораются по времени; текущее — по мере звучания.
    private func words(_ words: [SyncedWord], size: CGFloat, weight: Font.Weight) -> Text {
        let position = model.services.lyrics.lyricsPosition(model.services.player.livePosition())
        let font = Font.system(size: size, weight: weight)
        // Одна `AttributedString` со своим шрифтом и цветом у каждого слова: `Text + Text` в iOS 26 устарел
        var line = AttributedString()
        for word in words {
            let fill: Double = if position >= word.endMs {
                1
            } else if position <= word.startMs {
                0
            } else {
                Double(position - word.startMs) / Double(max(1, word.endMs - word.startMs))
            }
            var run = AttributedString(word.text)
            run.font = font
            // Ещё не спетое слово — не тусклее следующей строки (`Design.lyricsDim`), спетое — полностью яркое
            let floor = contrast == .increased ? 0.6 : 0.45
            run.foregroundColor = Color.fullContrast.opacity(floor + (1 - floor) * fill)
            line.append(run)
        }
        return Text(line)
    }
}

/// Стягивает содержимое по ширине: перенос, при котором строки укладываются в предложенную ширину, но сама ширина —
/// по самой длинной строке, а не на всю область (текст в SwiftUI при переносе занимает всё предложенное). Ищется
/// наименьшая ширина, при которой высота та же, что при полной ширине.
private struct ShrinkWrap: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let view = subviews.first else { return .zero }
        guard let limit = proposal.width, limit.isFinite, limit > 0 else { return view.sizeThatFits(proposal) }
        let full = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        var narrow: CGFloat = 0
        var wide = min(limit, full.width)
        for _ in 0..<12 {
            let middle = (narrow + wide) / 2
            if view.sizeThatFits(ProposedViewSize(width: middle, height: nil)).height <= full.height + 0.5 {
                wide = middle
            } else {
                narrow = middle
            }
        }
        return CGSize(width: min(limit, wide.rounded(.up)), height: full.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Три точки проигрыша: выскакивают по одной и лопаются перед следующей строкой.
private struct InterludeDots: View {
    let progress: Double
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10 * scale) {
            ForEach(0..<3, id: \.self) { index in
                let appear = Double(index) / 3 * 0.85
                let visible = progress >= appear
                let popping = progress > 0.93
                Circle()
                    .fill(.primary)
                    .frame(width: 12 * scale, height: 12 * scale)
                    // «Уменьшение движения»: точки не подпрыгивают и не лопаются, а проявляются и гаснут
                    .scaleEffect(reduceMotion ? 1 : (popping ? 1.6 : (visible ? 1 : 0.2)))
                    .opacity(popping ? 0 : (visible ? 0.9 : 0))
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.55), value: visible)
                    .animation(.easeIn(duration: 0.2), value: popping)
            }
        }
        .padding(.vertical, 8 * scale)
    }
}

/// От чего зависит место текущей строки (`SyncedLyricsView`): задача постановки перезапускается при любой перемене.
private struct Placement: Equatable {
    var active: Int
    var mid: CGFloat?
    var height: CGFloat
    var row: CGFloat?
    var laidOut: Bool
    var following: Bool
}
