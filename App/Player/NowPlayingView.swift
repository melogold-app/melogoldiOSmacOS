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

    var body: some View {
        @Bindable var model = model
        let player = model.services.player
        GeometryReader { proxy in
            Group {
                if let track = player.currentTrack {
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
        #if os(iOS)
        // iPhone и iPad: очередь — лист из «Сейчас играет»
        .sheet(isPresented: $model.queueVisible) {
            NavigationStack { QueueView(inSheet: true) }
                .presentationDetents([.medium, .large])
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
            } else if model.lyricsVisible {
                stackedLyrics(track, size: size, margin: margin)
            } else if typeSize.isAccessibilitySize {
                scrollingCover(track, size: size, margin: margin)
            } else {
                stackedCover(track, size: size, margin: margin)
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: model.lyricsVisible)
    }

    /// Портрет: обложка занимает то, что осталось от управления, — на любом Dynamic Type и в любом окне.
    private func stackedCover(_ track: Track, size: CGSize, margin: CGFloat) -> some View {
        VStack(spacing: Design.Space.l) {
            artworkArea(track)
                .padding(.horizontal, margin)
            controls(track, compact: false, wide: size.width >= 700)
                .padding(.horizontal, margin)
        }
        .padding(.top, Metrics.topInset)
        .padding(.bottom, Design.Space.l)
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

    /// Портрет с текстом: шапка — маленькая обложка и название, текст, под ним компактный транспорт.
    private func stackedLyrics(_ track: Track, size: CGSize, margin: CGFloat) -> some View {
        VStack(spacing: Design.Space.s) {
            lyricsHeader(track)
                .padding(.horizontal, margin)
            LyricsPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls(track, compact: true, wide: size.width >= 700, showsTitle: false)
                .padding(.horizontal, margin)
        }
        .padding(.top, Metrics.topInset)
        .padding(.bottom, Design.Space.m)
    }

    /// Боком и в широком окне: обложка слева, управление справа; с текстом — слева управление, справа текст.
    private func landscapeLayout(_ track: Track, size: CGSize, margin: CGFloat, short: Bool) -> some View {
        HStack(spacing: Design.Space.xl) {
            if model.lyricsVisible {
                VStack(spacing: Design.Space.m) {
                    artworkArea(track, minSide: 96)
                    controls(track, compact: true, wide: false)
                }
                .frame(width: min(size.width * 0.42, 440))
                // Середина текущей строки — на уровне середины обложки (решение 2026-09-30); нет обложки — верх области
                LyricsPanel()
                    .environment(\.lyricsCoverMid, coverFrame?.midY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                artworkArea(track)
                controls(track, compact: short, wide: !short && size.width >= 900)
                    .frame(maxWidth: 460)
            }
            #if os(macOS)
            if model.queueVisible {
                QueueView()
                    .frame(width: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous))
            }
            #endif
        }
        .padding(.horizontal, margin)
        .padding(.top, Metrics.topInset)
        .padding(.bottom, Design.Space.l)
    }

    // MARK: - Части

    /// Обложка в квадрате, вписанном в оставшееся место. Меньше `minSide` — не показывается вовсе (низкое окно с текстом).
    private func artworkArea(_ track: Track, minSide: CGFloat = 0) -> some View {
        GeometryReader { area in
            // На iPad и в большом окне обложка не растёт шире 600 pt: рядом с управлением она остаётся обложкой, а не обоями
            let side = min(area.size.width, area.size.height, 600)
            if side >= max(minSide, 1) {
                artworkButton(track, side: side)
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

    private func artworkButton(_ track: Track, side: CGFloat) -> some View {
        Button {
            withAnimation(.snappy) { model.lyricsVisible = true }
        } label: {
            NowPlayingArtwork(url: track.artworkURL, side: max(96, side))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("player.lyrics"))
    }

    /// Шапка над текстом: маленькая обложка возвращает к обложке, справа ♡.
    private func lyricsHeader(_ track: Track) -> some View {
        HStack(spacing: Design.Space.s) {
            Button {
                withAnimation(.snappy) { model.lyricsVisible = false }
            } label: {
                ArtworkView(url: track.artworkURL, size: 56, cornerRadius: Design.Radius.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("lyrics.artwork"))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(2)
                PlayerStatusLine(font: .subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LikeButton(size: .title3)
        }
    }

    /// Название, полоса перемотки, транспорт, панель действий. Компактный вид — под текстом и в низком окне.
    @ViewBuilder
    private func controls(_ track: Track, compact: Bool, wide: Bool, showsTitle: Bool = true) -> some View {
        VStack(spacing: compact ? Design.Space.s : Design.Space.l) {
            if showsTitle { NowPlayingTitle(track: track, large: wide && !compact) }
            SeekBar()
            PlayerChips()
            TransportRow(compact: compact)
            #if os(macOS)
            if wide { VolumeBar().frame(height: 24) }
            #elseif os(iOS)
            if wide { SystemVolumeView().frame(height: Design.Size.minTap) }
            #endif
            PlayerActionBar(includesModes: !compact)
        }
        .frame(maxWidth: 520)
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
            .overlay(alignment: .topTrailing) {
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
                .padding(Design.Space.m)
                .help(Text("common.collapse"))
                .accessibilityLabel(Text("common.collapse"))
            }
        #else
        content
        #endif
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
            .animation(.snappy, value: wide)
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

    func updateNSView(_ view: ToolbarHiderView, context: Context) {}

    static func dismantleNSView(_ view: ToolbarHiderView, coordinator: ()) { view.restore() }

    final class ToolbarHiderView: NSView {
        private weak var hiddenIn: NSWindow?
        private var wasVisible = true
        private var title = NSWindow.TitleVisibility.visible

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, hiddenIn == nil, let toolbar = window.toolbar else { return }
            hiddenIn = window
            wasVisible = toolbar.isVisible
            title = window.titleVisibility
            toolbar.isVisible = false
            window.titleVisibility = .hidden
        }

        func restore() {
            hiddenIn?.toolbar?.isVisible = wasVisible
            hiddenIn?.titleVisibility = title
            hiddenIn = nil
        }
    }
}
#endif
