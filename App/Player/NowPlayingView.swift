import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// «Сейчас играет» (docs/PROMPT.md §5.7) на iPhone, iPad, Mac и Vision.
///
/// - Фон — размытая обложка, живая под музыку (`NowPlayingBackdrop`, задания 0030 и 0031); стекло — только у управления.
/// - Закрытие: на iPhone и iPad это лист (`.sheet`) с системным grabber и закрытием смахиванием вниз, на Mac — Esc
///   и кнопка в углу, на Vision — окно.
/// - Обложка — крупно, нажатие включает текст; на узком экране портретный вид: обложка, название, полоса, транспорт на
///   стекле, панель действий; с текстом — маленькая шапка, текст, компактный транспорт под ним.
/// - iPhone боком, iPad и Mac в широком окне (REWRITE §3.10.11): обложка слева, управление справа; с текстом колонка
///   обложки (обложка, если помещается, и компактное управление) и колонка текста — одним блоком посередине окна (0033 §4).
/// - Размер строки текста — от высоты всей области (задание 0030 §3, `nowPlayingHeight`).
/// - Крупный Dynamic Type: обложка и управление прокручиваются, значки не растут дальше ряда.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Рамка обложки рядом с текстом (`coverSlot`): по ней встаёт середина текущей строки текста.
    @State private var coverFrame: CGRect?
    /// Картинка обложки — кадр видео 16:9 (`HeroArtwork`): рядом с текстом он стоит целиком, название — сразу под ним.
    @State private var wideArtwork = false
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
        // Размер строки текста — по высоте всей области, в любой раскладке один и тот же (задание 0030 §3)
        .environment(\.nowPlayingHeight, size.height)
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
    /// те же виды в обоих видах: при переключении они только сдвигаются. `insets` — свои поля сверху и снизу; без них —
    /// внутри широкой раскладки Mac рядом с колонкой очереди (`landscapeLayout`), у которой поля свои.
    private func stackedPortrait(_ track: Track, size: CGSize, margin: CGFloat, insets: Bool = true) -> some View {
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
        .padding(.top, insets ? Metrics.topInset + Design.Space.xs : 0)
        .padding(.bottom, insets ? Design.Space.xs : 0)
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

    /// Боком и в широком окне:
    /// - без текста — две равные половины, граница ровно по середине окна (решение пользователя, 2026-09-30): обложка по
    ///   центру левой половины, управление по центру правой;
    /// - с текстом — колонка обложки (обложка, под ней сразу название, полоса и кнопки) и колонка текста одним блоком
    ///   посередине окна, на Mac — без колонки очереди (`OneBlockLayout`, задание 0033 §4: Максим отменил половины, как на
    ///   Windows и Linux); середина текущей строки стоит на уровне середины обложки (`lyricsCoverMid`), нет обложки — верх
    ///   области. На Mac рядом с колонкой очереди блоку может не хватить ширины (`NowPlayingMetrics.fitsWideLayout`) — тогда
    ///   текст над управлением, как в портрете.
    private func landscapeLayout(_ track: Track, size: CGSize, margin: CGFloat, short: Bool) -> some View {
        #if os(macOS)
        // Колонка очереди справа внутри «Сейчас играет»: половины делят остальное окно
        let queueWidth: CGFloat = model.queueVisible ? 320 + Design.Space.l : 0
        // Рядом с очередью в окне 1000 pt текст получил бы 136 pt и ломал слова посередине, в окне 800 — пропадал вовсе:
        // колонкам обложки и текста не хватает места — текст над управлением (у Linux и Windows узко — ниже 860 и 900)
        let blockWidth = size.width - (model.queueVisible ? queueWidth + margin : 0)
        let oneBlock = NowPlayingMetrics.fitsWideLayout(width: Double(blockWidth), columnMin: Double(OneBlockLayout.minColumn))
        #else
        let queueWidth: CGFloat = 0
        let blockWidth = size.width
        let oneBlock = true
        #endif
        let half = (size.width - queueWidth) / 2
        return HStack(spacing: 0) {
            if model.lyricsVisible, !oneBlock {
                stackedPortrait(track, size: CGSize(width: blockWidth, height: size.height), margin: margin, insets: false)
            } else if model.lyricsVisible {
                OneBlockLayout(lineSize: CGFloat(NowPlayingMetrics.lyricsSize(areaHeight: Double(size.height))),
                               coverAspect: wideArtwork ? 16 / 9 : 1, spacing: Design.Space.l, lyricsInset: LyricsStyle.sidePadding) {
                    coverSlot()
                    // Название и кнопки — во всю ширину колонки, как обложка: длинное название переносится под ней
                    scrollingAtLargeType { controls(track, compact: true, wide: false, maxWidth: .infinity) }
                    LyricsPanel()
                        .environment(\.lyricsCoverMid, coverFrame?.midY)
                }
                .animation(reduceMotion ? nil : .snappy, value: wideArtwork)
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

    /// Место под обложку рядом с текстом — ровно та рамка, что дал `OneBlockLayout` (квадрат или 16:9 у кадра видео);
    /// нулевая — обложка не помещается, места нет. Рамку для текста (`coverFrame`) сообщает сама геометрия: через
    /// `PreferenceKey` из листа на iPad она доходила и тут же сбрасывалась в `nil`, и строка вставала к верху, а не к
    /// середине обложки.
    private func coverSlot() -> some View {
        let space = nowPlayingSpace
        return GeometryReader { slot in
            if slot.size.width >= 1, slot.size.height >= 1 {
                Color.clear
                    .artworkSlot(big: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { coverFrame = $0 }
                    .onDisappear { coverFrame = nil }
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
                HeroArtwork(url: track.artworkURL, big: slot.big, onShape: { wideArtwork = $0 }) {
                    withMotion(.snappy) { model.lyricsVisible.toggle() }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// Название, полоса перемотки, транспорт, громкость, нижний ряд — широкая раскладка. Компактный вид — рядом с
    /// текстом и в низком окне. Рядом с обложкой без текста — не шире 520 pt; под обложкой рядом с текстом — во всю
    /// ширину колонки обложки.
    @ViewBuilder
    private func controls(_ track: Track, compact: Bool, wide: Bool, showsTitle: Bool = true, maxWidth: CGFloat = 520) -> some View {
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
        .frame(maxWidth: maxWidth)
    }
}

/// «Сейчас играет» в широком окне с текстом (задание 0033 §4; Linux `now_playing::wide_layout`, Windows
/// `NowPlayingMetrics.WideLayout`): колонка обложки и колонка текста — одним блоком посередине области, поля слева и
/// справа поровну. Подвиды: место под обложку, управление (название, полоса, кнопки), текст.
///
/// Числа — `NowPlayingMetrics.wideLayout`; здесь меряется то, что под обложкой, при ширине колонки: длинное название
/// переносится, и в узкой колонке — на строку больше. Мерим от самой узкой колонки к итоговой: обложка от раза к разу
/// только растёт, а то, что под ней, — только убывает, поэтому колонка не вылезает за низ. Колонка обложки — посередине по
/// высоте, название и кнопки сразу под обложкой; текст — во всю высоту, его колонка раздвинута на собственные поля
/// (`lyricsInset`), чтобы строки стояли ровно в 72 pt от обложки.
private struct OneBlockLayout: Layout {
    /// Размер строки текста — по высоте всей области (задание 0030 §3).
    var lineSize: CGFloat
    /// Ширина к высоте у обложки: кадр видео 16:9 стоит целиком, и название — сразу под ним, а не под пустым квадратом.
    var coverAspect: CGFloat
    /// Промежуток между обложкой и названием.
    var spacing: CGFloat
    /// Поле, которое текст держит внутри своей области по бокам (`LyricsStyle.sidePadding`).
    var lyricsInset: CGFloat
    /// Колонка обложки не уже этого, как и раньше рядом с текстом (и не уже ряда кнопок).
    static let minColumn: CGFloat = 320

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard subviews.count == 3 else { return }
        let (cover, controls, lyrics) = (subviews[0], subviews[1], subviews[2])
        // Управление не выше самой области: прокручиваемое (крупный шрифт) отдаёт всю высоту содержимого
        func controlsHeight(_ width: CGFloat) -> CGFloat {
            min(controls.sizeThatFits(ProposedViewSize(width: width, height: nil)).height, bounds.height)
        }
        let columnMin = max(Self.minColumn, controls.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
        func measure(at width: CGFloat) -> NowPlayingMetrics.WideLayout {
            NowPlayingMetrics.wideLayout(width: bounds.width, height: bounds.height, below: controlsHeight(width) + spacing,
                                         columnMin: columnMin, lineSize: lineSize)
        }
        var measured = columnMin
        var layout = measure(at: measured)
        for _ in 0..<2 where layout.column != measured {
            measured = layout.column
            layout = measure(at: measured)
        }
        let column = CGFloat(layout.column)
        let side = CGFloat(layout.cover)
        let coverHeight = (side / coverAspect).rounded()
        let controlsHeight = controlsHeight(column)
        let group = (side > 0 ? coverHeight + spacing : 0) + controlsHeight
        let midX = bounds.minX + layout.edge + column / 2
        var y = bounds.minY + max(0, (bounds.height - group) / 2)
        cover.place(at: CGPoint(x: midX, y: y), anchor: .top, proposal: ProposedViewSize(width: side, height: side > 0 ? coverHeight : 0))
        if side > 0 { y += coverHeight + spacing }
        controls.place(at: CGPoint(x: midX, y: y), anchor: .top, proposal: ProposedViewSize(width: column, height: controlsHeight))
        lyrics.place(at: CGPoint(x: bounds.minX + layout.edge + column + NowPlayingMetrics.wideGap - lyricsInset, y: bounds.minY),
                     anchor: .topLeading, proposal: ProposedViewSize(width: layout.lyrics + 2 * lyricsInset, height: bounds.height))
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
/// окна без своего фона. Поверх размытой обложки текст и кнопки всегда светлые (задание 0030): тёмная схема, какая бы ни
/// была тема приложения; при повышенной контрастности фона нет — схема темы.
private struct NowPlayingChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var surfaceScheme: ColorScheme { contrast == .increased ? scheme : .dark }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .presentationBackground { NowPlayingBackdrop(cover: model.nowPlayingCover) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationSizing(FullSheetSizing())
            .environment(\.colorScheme, surfaceScheme)
        #elseif os(macOS)
        content
            .background { NowPlayingBackdrop(cover: model.nowPlayingCover) }
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
            .environment(\.colorScheme, surfaceScheme)
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
/// крупной — в шапке та же картинка, без подмены; пока крупная грузится, на её месте та же обложка меньшего размера из
/// памяти (задание 0033 §6). Кадр видео 16:9 в большом месте — целиком по ширине (задание 0008), в шапке — квадратом. В
/// паузе большая обложка отступает, как у Apple Music: чуть меньше и с короткой тенью.
private struct HeroArtwork: View {
    let url: String?
    let big: Bool
    /// Картинка — кадр видео шире 1,2 : 1: раскладка рядом с текстом ставит его целиком (`OneBlockLayout`).
    let onShape: (Bool) -> Void
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
        .onChange(of: wide, initial: true) { onShape(wide) }
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
        let loader = ArtworkLoader.shared
        if let ready = await loader.cached(sized) {
            show(ready)
            return
        }
        // Пока крупная грузится — та же обложка меньшего размера: она уже есть у мини-плеера (или он её как раз грузит),
        // а не нота на пустом месте и не обложка прежнего трека. Крупная закрывает её, когда загрузится (задание 0033 §6,
        // как у Linux f26b7e6 и Windows 69f4a58)
        show(await loader.otherSize(of: sized, wait: false))
        let waitsForSmall = image == nil
        await withTaskGroup(of: (big: Bool, picture: CGImage?).self) { group in
            group.addTask { (true, await loader.image(sized)) }
            if waitsForSmall { group.addTask { (false, await loader.otherSize(of: sized, wait: true)) } }
            for await result in group {
                guard !Task.isCancelled else { break }
                if let picture = result.picture { show(picture) }
                // Крупная пришла — маленькая, если ещё в пути, уже не нужна; не пришла — остаётся маленькая
                if result.big, result.picture != nil { break }
            }
        }
    }

    private func show(_ picture: CGImage?) {
        image = picture
        wide = picture.map { Double($0.width) > Double($0.height) * 1.2 } ?? false
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
        /// Полосы под заголовком окна, которые спрятал этот вид: их и возвращает.
        private var hiddenAccessories: [NSTitlebarAccessoryViewController] = []

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
            // Полосы под заголовком живут отдельно от панели: области поиска «Всё · Музыка · YouTube» (`searchScopes`)
            // оставались поверх «Сейчас играет», когда под ним открыт Поиск (пользователь, 2026-10-20). Прячем и их —
            // на каждом такте: SwiftUI показывает полосу заново при перестройке экрана под плеером
            for accessory in window.titlebarAccessoryViewControllers where !accessory.isHidden {
                accessory.isHidden = true
                if !hiddenAccessories.contains(where: { $0 === accessory }) { hiddenAccessories.append(accessory) }
            }
        }

        func restore() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            hiddenIn?.toolbar?.isVisible = wasVisible
            hiddenIn?.titleVisibility = title
            for accessory in hiddenAccessories { accessory.isHidden = false }
            hiddenAccessories = []
            hiddenIn = nil
        }
    }
}
#endif
