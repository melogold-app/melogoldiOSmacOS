import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// «Сейчас играет» (docs/PROMPT.md §5.7) на iPhone, iPad, Mac и Vision.
///
/// - Фон — мягкий статичный оттенок цвета обложки (`NowPlayingBackground`, §5.1); стекло — только у управления.
/// - Закрытие: на iPhone и iPad это лист (`.sheet`) с системным grabber и закрытием смахиванием вниз, на Mac — Esc
///   и кнопка в углу, на Vision — окно.
/// - Обложка — крупно, нажатие включает текст; на узком экране портретный вид: обложка, название, полоса, транспорт на
///   стекле, панель действий; с текстом — маленькая шапка, текст, компактный транспорт под ним.
/// - iPhone боком, iPad и Mac в широком окне (REWRITE §3.10.11): обложка слева, управление справа; с текстом слева
///   обложка (если помещается) и компактное управление, справа текст.
/// - Крупный Dynamic Type: обложка и управление прокручиваются, значки не растут дальше ряда.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Рамка обложки в широкой раскладке: по ней встаёт середина текущей строки текста.
    @State private var coverFrame: CGRect?
    /// Название перетекает между местом под обложкой и шапкой текста.
    @Namespace private var heroSpace

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            Group {
                if let track = model.playingTrack {
                    content(track, size: proxy.size)
                } else {
                    ContentUnavailableView { Label("player.nothingPlaying", systemImage: "music.note") }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: nowPlayingSpace)
            .onPreferenceChange(CoverFrameKey.self) { coverFrame = $0 }
        }
        .modifier(NowPlayingChrome())
        .sheet(item: $model.lyricsSearch) { LyricsSearchSheet(track: $0) }
        #if !os(macOS)
        // «Устройство» поверх листа «Сейчас играет» (задание 0020)
        .background {
            Color.clear.sheet(isPresented: Binding(get: { model.remoteSheet && model.nowPlayingIsSheet }, set: { model.remoteSheet = $0 })) {
                RemoteSheet()
            }
        }
        #endif
        #if os(iOS)
        // iPhone и iPad: очередь — лист из «Сейчас играет»
        .sheet(isPresented: $model.queueVisible) {
            NavigationStack { QueueView(inSheet: true) }
                .sheetDetents([.medium, .large])
        }
        #elseif os(visionOS)
        .sheet(isPresented: $model.queueVisible) {
            NavigationStack { QueueView(inSheet: true) }.frame(minWidth: 480, minHeight: 560)
        }
        #endif
        #if os(macOS)
        .sheet(item: $model.lyricsEditor) { LyricsEditorView(track: $0) }
        #elseif os(iOS)
        .fullScreenCover(item: $model.lyricsEditor) { LyricsEditorView(track: $0) }
        #endif
    }

    // MARK: - Раскладки

    @ViewBuilder
    private func content(_ track: Track, size: CGSize) -> some View {
        let landscape = size.width > size.height * 1.1
        let margin = size.width >= 700 ? Design.Space.xl : Design.Space.l
        let short = size.height < 520
        Group {
            if landscape {
                landscapeLayout(track, size: size, margin: margin, short: short)
            } else if !model.lyricsVisible, typeSize.isAccessibilitySize {
                scrollingCover(track, size: size, margin: margin)
            } else {
                // Обложка и текст — одна раскладка: при переключении обложка перетекает в шапку текста, а кнопки остаются
                // теми же видами и только сдвигаются (раньше весь экран растворялся и собирался заново — две раскладки
                // сразу, с текстом, давали рывки; пользователь, 2026-10-02: «анимации отстой»)
                stackedPortrait(track, size: size, margin: margin)
            }
        }
        .transition(.opacity)
        // Одна обложка на весь экран: места под неё (`ArtworkSlotKey`) только сообщают, где ей стоять
        .overlayPreferenceValue(ArtworkSlotKey.self) { slots in
            heroArtwork(track, slots: slots)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: model.lyricsVisible)
    }

    /// Портрет, как у Apple Music, но живой (пользователь, 2026-10-02). Без текста: обложка у верха во всю ширину (пока
    /// влезает управление), под ней название с ♡ и «…», полоса, ряд транспорта, громкость и нижний ряд — ровным шагом;
    /// лишняя высота уходит в зазор под обложкой. С текстом: шапка — обложка 84 pt (крупнее, чем у Apple Music, по просьбе
    /// пользователя), название, ♡ и «…»; текст; под ним те же полоса, компактный транспорт и нижний ряд. Кнопки — одни и
    /// те же виды в обоих видах: при переключении они только сдвигаются.
    private func stackedPortrait(_ track: Track, size: CGSize, margin: CGFloat) -> some View {
        let lyrics = model.lyricsVisible
        let wide = size.width >= 700
        #if os(iOS)
        let volume = !lyrics && size.height >= 760
        #else
        let volume = false
        #endif
        return VStack(spacing: 0) {
            if lyrics {
                lyricsHeader(track)
                    .padding(.horizontal, margin)
                LyricsPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .offset(y: 28)))
            } else {
                // Обложка берёт место первой (приоритет); что осталось — треть над ней, две трети под ней
                Spacer(minLength: 0)
                artworkArea(track)
                    .frame(maxHeight: size.width - 2 * margin)
                    .layoutPriority(1)
                    .padding(.horizontal, margin)
                Spacer(minLength: Design.Space.l)
                Spacer(minLength: 0)
                NowPlayingTitle(track: track, large: wide)
                    .matchedGeometryEffect(id: "title", in: heroSpace)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, margin)
            }
            VStack(spacing: 0) {
                SeekBar()
                    .padding(.top, lyrics ? 0 : Design.Space.m)
                PlayerChips()
                TransportRow(compact: lyrics)
                    .padding(.top, lyrics ? 0 : Design.Space.xs)
                #if os(iOS)
                if volume {
                    VolumeRow()
                        .padding(.top, Design.Space.s)
                        .transition(.opacity)
                }
                #endif
                PlayerActionBar()
                    .padding(.top, lyrics ? Design.Space.xs : (volume ? Design.Space.m : Design.Space.l))
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, margin)
        }
        .padding(.top, Metrics.topInset + Design.Space.xs)
        .padding(.bottom, Design.Space.xs)
    }

    /// Крупный Dynamic Type без текста: всё в прокрутке, обложка не сжимается до точки.
    private func scrollingCover(_ track: Track, size: CGSize, margin: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: Design.Space.l) {
                artworkButton(track, side: min(size.width - 2 * margin, 320))
                controls(track, compact: false, wide: false)
            }
            .padding(.horizontal, margin)
            .padding(.top, Metrics.topInset)
            .padding(.bottom, Design.Space.l)
        }
        .scrollIndicators(.hidden)
    }

    /// Боком и в широком окне — две равные половины, граница ровно по середине окна (решение пользователя, 2026-09-30):
    /// - без текста: обложка по центру левой половины, управление по центру правой;
    /// - с текстом: слева обложка, под ней сразу название, полоса и кнопки — одной группой по центру половины и по
    ///   вертикали, справа колонка текста по центру своей половины (строки — по левому краю, ширина не больше 620 pt);
    ///   середина текущей строки стоит на уровне середины обложки (`lyricsCoverMid`), нет обложки — верх области.
    private func landscapeLayout(_ track: Track, size: CGSize, margin: CGFloat, short: Bool) -> some View {
        #if os(macOS)
        // Колонка очереди справа внутри «Сейчас играет»: половины делят остальное окно
        let queueWidth: CGFloat = model.queueVisible ? 320 + Design.Space.l : 0
        #else
        let queueWidth: CGFloat = 0
        #endif
        let half = (size.width - queueWidth) / 2
        return HStack(spacing: 0) {
            if model.lyricsVisible {
                CoverAboveControls(spacing: Design.Space.l) {
                    coverSlot(track)
                    scrollingAtLargeType { controls(track, compact: true, wide: false) }
                }
                .padding(.horizontal, margin)
                .frame(width: half)
                LyricsPanel()
                    .environment(\.lyricsCoverMid, coverFrame?.midY)
                    .frame(width: min(half - 2 * margin, 620))
                    .frame(width: half)
            } else {
                artworkArea(track)
                    .padding(.horizontal, margin)
                    .frame(width: half)
                scrollingAtLargeType { controls(track, compact: short, wide: !short && size.width >= 900) }
                    .frame(maxWidth: 460)
                    .padding(.horizontal, margin)
                    .frame(width: half)
            }
            #if os(macOS)
            if model.queueVisible {
                QueueView()
                    .frame(width: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous))
                    .padding(.leading, Design.Space.l)
                    .padding(.trailing, margin)
            }
            #endif
        }
        .padding(.top, Metrics.topInset)
        .padding(.bottom, Design.Space.l)
    }

    /// Крупный Dynamic Type: название, полоса и кнопки не помещаются в низкую половину окна (iPhone боком) — управление
    /// прокручивается. На обычном размере содержимое остаётся как есть.
    @ViewBuilder
    private func scrollingAtLargeType<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if typeSize.isAccessibilitySize {
            ScrollView { content().padding(.vertical, Design.Space.s) }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
        } else {
            content()
        }
    }

    /// Место под обложку, которое размеряет `CoverAboveControls`: квадрат по предложенному размеру; у кадра видео 16:9
    /// обложка стоит посередине квадрата, поэтому середина обложки не прыгает при смене формы.
    private func coverSlot(_ track: Track) -> some View {
        GeometryReader { slot in
            let side = min(slot.size.width, slot.size.height)
            if side >= 96 {
                Color.clear
                    .frame(width: side, height: side)
                    .artworkSlot(big: true)
                    .background {
                        GeometryReader { cover in
                            Color.clear.preference(key: CoverFrameKey.self, value: cover.frame(in: .named(nowPlayingSpace)))
                        }
                    }
                    .frame(width: slot.size.width, height: slot.size.height)
            }
        }
    }

    // MARK: - Части

    /// Место под большую обложку: квадрат, вписанный в оставшееся место. Меньше `minSide` — обложки нет вовсе (низкое окно
    /// с текстом). Саму обложку рисует `heroArtwork` по этому месту.
    private func artworkArea(_ track: Track, minSide: CGFloat = 0) -> some View {
        GeometryReader { area in
            // На iPad и в большом окне обложка не растёт шире 600 pt: рядом с управлением она остаётся обложкой, а не обоями
            let side = min(area.size.width, area.size.height, 600)
            if side >= max(minSide, 1) {
                Color.clear
                    .frame(width: side, height: side)
                    .artworkSlot(big: true)
                    .background {
                        GeometryReader { cover in
                            Color.clear.preference(key: CoverFrameKey.self, value: cover.frame(in: .named(nowPlayingSpace)))
                        }
                    }
                    .frame(width: area.size.width, height: area.size.height)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    /// Обложка — кнопка «Текст». В паузе она отступает (как у Apple Music): чуть меньше и с короткой тенью, при игре
    /// пружиной возвращается; место в раскладке не меняется, середина та же.
    private func artworkButton(_ track: Track, side: CGFloat) -> some View {
        let player = model.services.player
        let resting = !model.playingIsPlaying && (model.remoteTarget != nil || player.phase != .loading)
        return Button {
            withMotion(.snappy) { model.lyricsVisible = true }
        } label: {
            NowPlayingArtwork(url: track.artworkURL, side: max(96, side))
                .shadow(color: .black.opacity(resting ? 0.12 : 0.24), radius: resting ? 8 : 22, y: resting ? 4 : 12)
                .scaleEffect(resting && !reduceMotion ? 0.84 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72), value: resting)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("player.lyrics"))
    }

    /// Шапка над текстом: обложка 84 pt (место для `heroArtwork`; нажатие возвращает к обложке), название, справа ♡ и «…»
    /// (в нём и пункты текста).
    private func lyricsHeader(_ track: Track) -> some View {
        HStack(spacing: Design.Space.m) {
            Color.clear
                .frame(width: Metrics.headerArtwork, height: Metrics.headerArtwork)
                .artworkSlot(big: false)
            HStack(spacing: Design.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.title3.weight(.bold)).lineLimit(2)
                    PlayerStatusLine(font: .subheadline, onTint: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TrackActionCircles()
            }
            .matchedGeometryEffect(id: "title", in: heroSpace)
        }
    }

    /// Обложка поверх раскладки — по месту, которое она сообщила (`ArtworkSlotKey`). Одна и та же картинка во всех видах:
    /// при переключении текста она перелетает и меняет размер, а не растворяется и не грузится заново.
    @ViewBuilder
    private func heroArtwork(_ track: Track, slots: [ArtworkSlot]) -> some View {
        // С текстом в портрете — шапка, иначе большое место; боком оба больших — последнее
        if let slot = slots.first(where: { $0.big != model.lyricsVisible }) ?? slots.last {
            GeometryReader { proxy in
                let rect = proxy[slot.anchor]
                HeroArtwork(url: track.artworkURL, big: slot.big) {
                    withMotion(.snappy) { model.lyricsVisible.toggle() }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// Название, полоса перемотки, транспорт, громкость, нижний ряд — широкая раскладка. Компактный вид — рядом с
    /// текстом и в низком окне.
    @ViewBuilder
    private func controls(_ track: Track, compact: Bool, wide: Bool, showsTitle: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsTitle { NowPlayingTitle(track: track, large: wide && !compact) }
            SeekBar()
                .padding(.top, showsTitle ? (compact ? Design.Space.s : Design.Space.m) : 0)
            PlayerChips()
            TransportRow(compact: compact)
                .padding(.top, compact ? 0 : Design.Space.xs)
            #if os(macOS)
            if wide { VolumeBar().frame(height: 24).padding(.top, Design.Space.s) }
            #elseif os(iOS)
            if wide { VolumeRow().padding(.top, Design.Space.s) }
            #endif
            PlayerActionBar()
                .padding(.top, compact ? Design.Space.xs : Design.Space.l)
        }
        .frame(maxWidth: 520)
    }
}

/// Обложка над блоком управления — одна группа по центру своей половины и по вертикали, без провала между ними:
/// обложка берёт высоту, которая осталась от управления (не выше 560 pt); не помещается (низкое окно) — остаётся одно
/// управление. Ширина управления — ширина обложки, но не меньше 320 pt.
private struct CoverAboveControls: Layout {
    var spacing: CGFloat
    let maxCover: CGFloat = 560
    let minCover: CGFloat = 96
    let minControls: CGFloat = 320

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        CGSize(width: proposal.width ?? maxCover, height: proposal.height ?? maxCover)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard subviews.count == 2 else { return }
        let column = min(bounds.width, maxCover)
        // Управление не выше самого окна: прокручиваемое (крупный шрифт) отдаёт всю высоту содержимого и без этого вылезло бы за край
        let natural = min(subviews[1].sizeThatFits(ProposedViewSize(width: column, height: nil)).height, bounds.height)
        let side = min(column, bounds.height - natural - spacing, maxCover)
        let showsCover = side >= minCover
        let controlsWidth = showsCover ? min(column, max(side, minControls)) : column
        let controlsHeight = min(subviews[1].sizeThatFits(ProposedViewSize(width: controlsWidth, height: nil)).height, bounds.height)
        let controls = ProposedViewSize(width: controlsWidth, height: controlsHeight)
        let group = (showsCover ? side + spacing : 0) + controlsHeight
        var y = bounds.minY + max(0, (bounds.height - group) / 2)
        if showsCover {
            subviews[0].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(width: side, height: side))
            y += side + spacing
        } else {
            subviews[0].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(width: 0, height: 0))
        }
        subviews[1].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: controls)
    }
}

/// Рамка обложки рядом с текстом в пространстве «Сейчас играет» (`nowPlayingSpace`).
private struct CoverFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

/// Размеры по платформе.
private enum Metrics {
    /// Обложка в шапке над текстом — крупнее, чем у Apple Music (пользователь, 2026-10-02).
    static let headerArtwork: CGFloat = 84

    /// Верхний отступ содержимого: на iPhone и iPad — место под grabber листа, на Mac — под кнопками окна.
    static var topInset: CGFloat {
        #if os(macOS)
        56
        #elseif os(iOS)
        28
        #else
        Design.Space.l
        #endif
    }
}

#if os(iOS)
/// Лист «Сейчас играет» на iPad — во всю ширину и высоту окна (docs/PROMPT.md §5.3: «во весь экран»), а не карточка
/// `.page`: в ней «Сейчас играет» боком не получает широкой раскладки. Grabber и закрытие смахиванием остаются системными.
private struct FullSheetSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        // Просим больше любого экрана: система ужимает лист до доступного места окна
        ProposedViewSize(width: 10_000, height: 10_000)
    }
}
#endif

/// Фон и способ показа: лист с grabber на iPhone и iPad, слой поверх окна на Mac (кнопка закрытия и Esc), Vision — стекло
/// окна без своего фона.
private struct NowPlayingChrome: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .presentationBackground { NowPlayingBackground(tint: model.coverTint) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationSizing(FullSheetSizing())
        #elseif os(macOS)
        content
            .background { NowPlayingBackground(tint: model.coverTint) }
            // Панель инструментов окна скрыта, пока открыт «Сейчас играет»: в ней поле поиска и заголовок раздела из
            // экрана под ним. Скрывает её AppKit, а не `toolbar(.hidden, for: .windowToolbar)` — тот гасит и кнопки окна.
            .background { MacToolbarHidden() }
            // «Свернуть» — слева, сразу за кнопками окна: на Mac закрывающее окно и слой стоит в левом верхнем углу (HIG
            // «Windows»), там его и ищут; справа он был не на месте
            .overlay(alignment: .topLeading) {
                Button {
                    model.showNowPlaying = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .controlGlass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(.top, Design.Space.xs)
                // Кнопки окна занимают ~70 pt слева
                .padding(.leading, 84)
                .help(Text("common.collapse"))
                .accessibilityLabel(Text("common.collapse"))
            }
        #else
        content
        #endif
    }
}

/// Место под обложку и его вид: большое (обложка во всю ширину, рядом с управлением) или шапка над текстом.
struct ArtworkSlot {
    let anchor: Anchor<CGRect>
    let big: Bool
}

/// Все места под обложку на экране: во время перехода старое и новое на миг есть оба — обложка выбирает по виду
/// (`heroArtwork`), а не по порядку.
private struct ArtworkSlotKey: PreferenceKey {
    static let defaultValue: [ArtworkSlot] = []

    static func reduce(value: inout [ArtworkSlot], nextValue: () -> [ArtworkSlot]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Здесь должна стоять обложка `heroArtwork`.
    func artworkSlot(big: Bool) -> some View {
        anchorPreference(key: ArtworkSlotKey.self, value: .bounds) { [ArtworkSlot(anchor: $0, big: big)] }
    }
}

/// Обложка «Сейчас играет», которая перелетает между местами: картинка тянется по рамке, которую ей дают (при
/// переключении текста рамка анимируется — картинка плавно растёт или уменьшается, скругление тоже). Грузится один раз
/// крупной — в шапке та же картинка, без подмены. Кадр видео 16:9 в большом месте — целиком по ширине (задание 0008), в
/// шапке — квадратом. В паузе большая обложка отступает, как у Apple Music: чуть меньше и с короткой тенью.
private struct HeroArtwork: View {
    let url: String?
    let big: Bool
    let onTap: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var wide = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = big && wide ? width * 9 / 16 : proxy.size.height
            let radius = big ? Design.Radius.cover : Design.Radius.medium
            let resting = big && !model.playingIsPlaying && (model.remoteTarget != nil || model.services.player.phase != .loading)
            Button(action: onTap) {
                picture
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .shadow(color: .black.opacity(big ? (resting ? 0.12 : 0.24) : 0.16),
                            radius: big ? (resting ? 8 : 22) : 8, y: big ? (resting ? 4 : 12) : 4)
                    .scaleEffect(resting && !reduceMotion ? 0.84 : 1)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72), value: resting)
            }
            .buttonStyle(.plain)
            .frame(width: width, height: proxy.size.height)
            .accessibilityLabel(Text(big ? "player.lyrics" : "lyrics.artwork"))
        }
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        // Одна крупная картинка на оба места: в шапке не грузится своя, поэтому при перелёте ничего не мигает
        let sized = Thumbnails.sized(url, px: Int((600 * displayScale).rounded(.up)))
        let loaded = await ArtworkLoader.shared.image(sized)
        image = loaded
        wide = loaded.map { Double($0.width) > Double($0.height) * 1.2 } ?? false
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
        ArtworkView(url: url, size: side, shape: wide ? .wide : .rounded, cornerRadius: Design.Radius.cover)
            .motion(.snappy, value: wide)
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

#if os(macOS)
/// Прячет панель инструментов окна на время жизни вида и возвращает её при уходе, как «Вид › Скрыть панель
/// инструментов»: кнопки окна (красная, жёлтая, зелёная) остаются на месте, название раздела в строке заголовка
/// тоже скрыто, содержимое окна — под прозрачной строкой заголовка.
private struct MacToolbarHidden: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarHiderView { ToolbarHiderView() }

    func updateNSView(_ view: ToolbarHiderView, context: Context) { view.hide() }

    static func dismantleNSView(_ view: ToolbarHiderView, coordinator: ()) { view.restore() }

    final class ToolbarHiderView: NSView {
        private weak var hiddenIn: NSWindow?
        private var wasVisible = true
        private var title = NSWindow.TitleVisibility.visible
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hide()
            guard let window, observer == nil else { return }
            // SwiftUI возвращает название окна при любой перестройке панели (открылась очередь, сменился раздел под экраном):
            // держим его скрытым на каждом такте обновления окна
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }

        func hide() {
            guard let window, let toolbar = window.toolbar else { return }
            if hiddenIn == nil {
                hiddenIn = window
                wasVisible = toolbar.isVisible
                title = window.titleVisibility
            }
            if toolbar.isVisible { toolbar.isVisible = false }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        }

        func restore() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            hiddenIn?.toolbar?.isVisible = wasVisible
            hiddenIn?.titleVisibility = title
            hiddenIn = nil
        }
    }
}
#endif
