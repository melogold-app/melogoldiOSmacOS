import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Детальный экран (альбом, плейлист, исполнитель): шапка и список, одной прокруткой, как в «Музыке» macOS 26 и iOS 26
/// (снимки пользователя, 2026-10-02): в широком окне шапка — строкой (обложка слева, название, исполнитель, описание и
/// кнопки справа), в узком — по центру; треки — на всю ширину под ней. Прежние две колонки с линией между ними выглядели
/// «некрасиво» и устарело. Название переходит в панель навигации, когда шапка уходит из вида. На iPhone и iPad страница
/// окрашена в цвет обложки (`tintURL`), как альбом в «Музыке» iOS 26; на Mac — фон окна, как в «Музыке» macOS 26.
struct DetailPage<Header: View, Rows: View>: View {
    let title: String
    var twoColumns = true
    /// Шапка — фото-обложка во всю ширину окна и до верхнего края (iPhone): у строки списка нет полей, список ложится под
    /// строку состояния. В окне шире `DetailLayout.heroWide` и на Mac и Vision это не действует.
    var fullBleedHeader = false
    /// Метки всех строк-треков в порядке списка — включают выбор нескольких треков (задание 0013).
    var rowIds: [String] = []
    var collectionName: String?
    var showsSelectButton = true
    /// Обложка, по цвету которой окрашена страница (iPhone и iPad).
    var tintURL: String?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let rows: () -> Rows
    let target: (String) -> RowTarget?
    var context: (String) -> TrackMenuContext? = { _ in nil }

    @State private var headerVisible = true
    @State private var tint: CoverTint?

    var body: some View {
        GeometryReader { proxy in
            // Фото исполнителя идёт до верхнего края только в узком окне; в широком шапка — строка с обложкой слева
            let wide = twoColumns && proxy.size.width >= 760
            let bleeds = fullBleedHeader && proxy.size.width < DetailLayout.heroWide
            list(bleeds: bleeds)
                .environment(\.detailIsColumn, wide)
                .modifier(TopBleed(enabled: bleeds))
        }
        .modifier(CardMetricsReader())
        .modifier(PageTint(tint: tint))
        .task(id: tintURL) {
            #if os(iOS)
            guard let tintURL else { return }
            if let hit = CoverPalette.cached(tintURL) { tint = hit } else { tint = await CoverPalette.shared.tint(for: tintURL) }
            #endif
        }
        .navigationTitle(Text(verbatim: headerVisible ? "" : title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func list(bleeds: Bool) -> some View {
        SelectableList(target: target, context: context, rowIds: rowIds, collectionName: collectionName ?? title,
                       showsSelectButton: showsSelectButton) {
            VStack(spacing: Design.Space.s) { header() }
                .environment(\.detailBleeds, bleeds)
                .frame(maxWidth: .infinity)
                .onScrollVisibilityChange(threshold: 0.2) { headerVisible = $0 }
                .listRowInsets(bleeds ? EdgeInsets() : EdgeInsets(top: Design.Space.xs, leading: 20, bottom: Design.Space.m, trailing: 20))
                .listRowSeparator(.hidden, edges: .all)
                .listRowBackground(Color.clear)
            // На странице в цвете обложки строки прозрачные — иначе список лежал чёрной полосой под цветной шапкой
            Group { rows() }
                .listRowBackground(tint == nil ? nil : Color.clear)
        }
        .contentListStyle()
    }
}

/// Страница в цвете обложки (iPhone, iPad): сплошной оттенок под списком, темнее в тёмной теме и светлее в светлой,
/// чтобы текст читался. Строки списка — прозрачные, на том же цвете.
private struct PageTint: ViewModifier {
    let tint: CoverTint?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        #if os(iOS)
        if let tint {
            content
                .scrollContentBackground(.hidden)
                .background {
                    Rectangle()
                        .fill(scheme == .dark ? tint.color.mix(with: .black, by: 0.62) : tint.color.mix(with: .white, by: 0.6))
                        .ignoresSafeArea()
                }
                .animation(.easeInOut(duration: 0.4), value: tint)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct DetailColumnKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Шапка стоит в левой колонке широкого окна: фото во всю ширину там не нужно, обложка — по центру колонки.
    var detailIsColumn: Bool {
        get { self[DetailColumnKey.self] }
        set { self[DetailColumnKey.self] = newValue }
    }
}

enum HeaderStyle { case cover, avatar, hero }

private struct HeaderAlignmentKey: EnvironmentKey {
    static let defaultValue = HorizontalAlignment.center
}

extension EnvironmentValues {
    /// Как выровнен текст шапки: по центру у обложки, по левому краю у фото-шапки.
    var headerAlignment: HorizontalAlignment {
        get { self[HeaderAlignmentKey.self] }
        set { self[HeaderAlignmentKey.self] = newValue }
    }
}

/// Подзаголовок шапки: строки выровнены так же, как название (по центру или по левому краю).
struct HeaderSubtitle<Content: View>: View {
    @Environment(\.headerAlignment) private var alignment
    var spacing: CGFloat = 4
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: alignment, spacing: spacing, content: content)
    }
}

private struct DetailBleedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Шапка — строка без полей до краёв окна: свои элементы шапки (кнопка «Сохранить») ставят поля сами.
    var detailBleeds: Bool {
        get { self[DetailBleedKey.self] }
        set { self[DetailBleedKey.self] = newValue }
    }
}

private struct HeaderInset: ViewModifier {
    @Environment(\.detailBleeds) private var bleeds

    func body(content: Content) -> some View {
        content.padding(.horizontal, bleeds ? Design.Space.m : 0)
    }
}

extension View {
    /// Поля шапки для элемента, который стоит в ней рядом с `CollectionHeader`.
    func headerInset() -> some View { modifier(HeaderInset()) }
}

enum DetailLayout {
    /// Обложка альбома и плейлиста в узком окне: `.hero` — фото-обложка во всю ширину от верхнего края, `.cover` — по центру.
    /// Фото-шапка во всю ширину — только на iPhone и iPad в узком окне. На Mac окно с панелью инструментов и боковой панелью,
    /// на Vision — стеклянное окно: фото там заняло бы высоту окна и легло бы под его кромку, поэтому обложка по центру.
    #if os(iOS)
    // Альбом и плейлист на iPhone — квадрат по центру с полями на цвете обложки, как в «Музыке» iOS 26 (снимок
    // пользователя, 2026-10-02), а не фото во всю ширину
    static let compactCover: HeaderStyle = .cover
    static let artistStyle: HeaderStyle = .hero
    #else
    static let compactCover: HeaderStyle = .cover
    static let artistStyle: HeaderStyle = .avatar
    #endif

    /// Шире этого окна шапка исполнителя — строка с аватаром слева, а не фото во всю ширину (на Mac оно было бы в высоту окна).
    static let heroWide: CGFloat = 600
}

/// Список поднимается под строку состояния: первая строка — шапка с фото — начинается у самого верхнего края, а кнопки
/// панели навигации лежат на фото на своём стекле.
private struct TopBleed: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

/// Шапка коллекции (docs/PROMPT.md §5.9): крупная обложка, название, подзаголовок и кнопки «Слушать · Перемешать».
/// - `.hero` (iPhone): квадратная обложка или фото исполнителя во всю ширину от верхнего края, название крупно слева под ней;
///   в окне шире `DetailLayout.heroWide` — аватар или обложка 200 pt слева от текста.
/// - `.cover` (колонка iPad, Mac, Vision): квадрат по центру, не больше 340 pt, радиус как у «Сейчас играет», мягкая тень.
/// - `.avatar` (канал YouTube): круг по центру.
/// `backgroundExtensionEffect` включён на фото-шапке; внутри прокручиваемого списка система его не рисует, а у обложки по
/// центру он давал полосу над ней (опыты `apple-shots/s3/fx-*`), поэтому до верхнего края шапку доводит сама картинка.
struct CollectionHeader<Art: View, Subtitle: View, Actions: View>: View {
    typealias Style = HeaderStyle

    var style: Style = .cover
    /// Фото-шапка в широком окне: аватар кругом (исполнитель) или скруглённая обложка (альбом, плейлист).
    var wideCircle = false
    /// Описание (об альбоме, о плейлисте): в шапке — три строки на Mac и две на iPhone с «ЕЩЁ», целиком — на листе.
    var description: String?
    var descriptionTitle: LocalizedStringResource = "album.about"
    let title: String
    /// Обложка по стороне квадрата, которую считает шапка.
    @ViewBuilder let artwork: (CGFloat) -> Art
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let actions: () -> Actions
    @State private var width: CGFloat = 0
    @State private var showsDescription = false

    @Environment(\.detailIsColumn) private var inColumn
    @Environment(\.dynamicTypeSize) private var typeSize
    /// В широком окне фото-шапка становится обложкой.
    private var effectiveStyle: Style { inColumn && style == .hero ? .cover : style }
    private var leading: Bool { effectiveStyle == .hero }
    private var wide: Bool { effectiveStyle == .hero && width >= DetailLayout.heroWide }
    /// Шапка строкой, как альбом в «Музыке» macOS 26: обложка слева, всё остальное справа.
    private var row: Bool { inColumn && effectiveStyle == .cover && !typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if row {
                musicRow
            } else if wide {
                HStack(alignment: .center, spacing: Design.Space.l) {
                    Group {
                        if wideCircle { artwork(200).clipShape(Circle()) } else { artwork(200).clipShape(RoundedRectangle(cornerRadius: Design.Radius.cover, style: .continuous)) }
                    }
                    .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
                    texts
                }
                .padding(.vertical, Design.Space.s)
            } else {
                VStack(spacing: Design.Space.s) {
                    art
                    texts.padding(.horizontal, leading ? Design.Space.m : 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(isPresented: $showsDescription) {
            DescriptionSheet(title: descriptionTitle, heading: title, text: description ?? "")
        }
    }

    /// Альбом в «Музыке» macOS 26: обложка 200–280 pt слева, справа название крупно, подзаголовок (исполнитель цветом
    /// акцента, тип и год), описание в три строки с «ЕЩЁ», ряд кнопок ⇄ · «Слушать» · ↓.
    private var musicRow: some View {
        let side = width > 0 ? min(280, max(200, width * 0.3)) : 240
        return HStack(alignment: .center, spacing: Design.Space.xl) {
            artwork(side)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                subtitle()
                    .environment(\.headerAlignment, .leading)
                    .multilineTextAlignment(.leading)
                if let description, !description.isEmpty {
                    DescriptionPreview(text: description, lines: 3) { showsDescription = true }
                        .padding(.top, Design.Space.s)
                }
                actions()
                    .padding(.top, Design.Space.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Тени обложки хватает места внутри строки: обрезанная краем строки, она рисовала прямоугольник вокруг шапки
        .padding(.vertical, Design.Space.l)
    }

    private var texts: some View {
        VStack(spacing: Design.Space.s) {
            Text(title)
                .font(leading ? .largeTitle.bold() : .title2.bold())
                .multilineTextAlignment(leading ? .leading : .center)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
            subtitle()
                .environment(\.headerAlignment, leading ? .leading : .center)
                .multilineTextAlignment(leading ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
            actions()
                .frame(maxWidth: leading ? (wide ? 420 : .infinity) : 420)
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
                .padding(.top, Design.Space.xxs)
                .padding(.bottom, leading ? Design.Space.s : 0)
            // Описание под кнопками, две строки с «ЕЩЁ», как альбом в «Музыке» iOS 26
            if let description, !description.isEmpty {
                DescriptionPreview(text: description, lines: 2) { showsDescription = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Design.Space.xs)
            }
        }
    }

    @ViewBuilder
    private var art: some View {
        switch effectiveStyle {
        case .cover:
            // Пока ширина не измерена, обложка стоит на запасном размере: шапка не прыгает на первом кадре. Как в «Музыке»
            // iOS 26 — квадрат с полями по бокам, не во всю ширину
            let side = width > 0 ? min(330, max(200, width - 2 * Design.Space.xxl)) : 280
            artwork(side)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        case .avatar:
            artwork(min(200, max(140, width * 0.5)))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        case .hero:
            artwork(max(width, 1))
                .backgroundExtensionEffect()
        }
    }
}

extension CollectionHeader where Art == ArtworkView {
    /// Шапка с обложкой по адресу: квадрат с радиусом плеера у альбома и плейлиста, круг у канала, фото без скругления у исполнителя.
    init(artworkURL: String?, style: Style = .cover, wideCircle: Bool = false, title: String, description: String? = nil,
         @ViewBuilder subtitle: @escaping () -> Subtitle, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(style: style, wideCircle: wideCircle, description: description, title: title, artwork: { side in
            ArtworkView(url: artworkURL, size: side, shape: style == .avatar ? .circle : style == .hero ? .square : .rounded,
                        cornerRadius: style == .cover ? Design.Radius.cover : nil)
        }, subtitle: subtitle, actions: actions)
    }
}

/// Ряд кнопок шапки альбома и плейлиста, как в «Музыке» macOS 26 и iOS 26 (снимки пользователя, 2026-10-02): ⇄ в
/// стеклянном круге, «Слушать» капсулой посередине, справа ещё круг (↓ загрузка) или ничего. На iPhone «Слушать» —
/// сплошная капсула цвета текста (белая на тёмной странице), на Mac — стеклянная со значком и словом цвета акцента.
struct CollectionActions<Trailing: View>: View {
    let play: () -> Void
    let shuffle: () -> Void
    var shuffleTitle: LocalizedStringResource = "collection.shuffle"
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Button(action: shuffle) {
                Image(systemName: "shuffle")
            }
            .modifier(HeaderCircle())
            .help(Text(shuffleTitle))
            .accessibilityLabel(Text(shuffleTitle))
            Button(action: play) {
                Label("collection.play", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.5 : 0.8)
            }
            .modifier(HeaderPlayCapsule())
            trailing()
                .modifier(HeaderCircle())
        }
    }
}

extension CollectionActions where Trailing == EmptyView {
    init(play: @escaping () -> Void, shuffle: @escaping () -> Void, shuffleTitle: LocalizedStringResource = "collection.shuffle") {
        self.init(play: play, shuffle: shuffle, shuffleTitle: shuffleTitle, trailing: { EmptyView() })
    }
}

extension View {
    /// Строка трека альбома на Mac — высокая, как в «Музыке» macOS 26 (около 44 pt): низкие строки во всю ширину выглядели
    /// старой таблицей.
    func albumRowHeight() -> some View {
        #if os(macOS)
        frame(minHeight: 40)
        #else
        self
        #endif
    }
}

/// Круглая стеклянная кнопка шапки: 44 pt на Mac, 52 pt на iPhone; значок цвета акцента на Mac, цвета текста на iPhone.
private struct HeaderCircle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .font(.title3.weight(.semibold))
            .labelStyle(.iconOnly)
            .foregroundStyle(.tint)
            .frame(width: 28, height: 28)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        #elseif os(visionOS)
        content
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        #else
        content
            .font(.title3.weight(.semibold))
            .labelStyle(.iconOnly)
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        #endif
    }
}

/// «Слушать» в шапке: капсула 170+ pt.
private struct HeaderPlayCapsule: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .font(.headline)
            .foregroundStyle(.tint)
            .frame(minWidth: 150, minHeight: 28)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        #elseif os(visionOS)
        content
            .frame(minWidth: 150)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        #else
        content
            .buttonStyle(SolidCapsuleStyle())
        #endif
    }
}

#if os(iOS)
/// Сплошная капсула цвета текста: белая с чёрным словом в тёмной теме, чёрная с белым — в светлой.
private struct SolidCapsuleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .padding(.horizontal, Design.Space.l)
            .frame(minWidth: 170, minHeight: 52)
            .background(Capsule().fill(Color.primary))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

/// Описание в несколько строк, в конце «ЕЩЁ» — целиком на листе.
struct DescriptionPreview: View {
    let text: String
    let lines: Int
    let more: () -> Void

    var body: some View {
        Button(action: more) {
            HStack(alignment: .lastTextBaseline, spacing: Design.Space.xs) {
                Text(verbatim: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                Text("common.more")
                    .font(.footnote.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("common.more"))
    }
}

/// Описание целиком: «Об альбоме» и название, текст можно выделить.
private struct DescriptionSheet: View {
    let title: LocalizedStringResource
    let heading: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    Text(verbatim: heading).font(.title2.bold())
                    Text(verbatim: text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(Design.Space.l)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text(title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}

/// «Слушать» — главная кнопка коллекции. Значок и текст — одним рядом: внутри `Label` значок на главной кнопке
/// рисовался цветом фона и пропадал.
struct PlayButton: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "play.fill").accessibilityHidden(true)
                Text("collection.play")
            }
            // Крупный шрифт: слово сжимается до половины, а не делится по слогам («Переме-шать»)
            .lineLimit(1)
            .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.5 : 0.75)
            .frame(maxWidth: .infinity)
        }
        // Liquid Glass (macOS 26, iOS 26): главная кнопка — стеклянная капсула акцентного цвета, а не плоская синяя кнопка
        // AppKit (пользователь, 2026-10-02: «как будто старые стили»)
        .prominentGlassButton()
        .controlSize(.large)
    }
}

/// «Перемешать» (у канала — «Перемешать видео»).
struct ShuffleButton: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var title: LocalizedStringResource = "collection.shuffle"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "shuffle").accessibilityHidden(true)
                Text(title)
            }
            // Крупный шрифт: слово сжимается до половины, а не делится по слогам («Переме-шать»)
            .lineLimit(1)
            .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.5 : 0.75)
            .frame(maxWidth: .infinity)
        }
        .glassButton()
        .controlSize(.large)
    }
}

/// Раскрываемое описание: «Об альбоме», «Об исполнителе».
struct AboutRow: View {
    let title: LocalizedStringResource
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        } label: {
            Text(title).font(.headline)
        }
    }
}

/// Полка внутри списка детального экрана: заголовок и карусель во всю ширину.
struct ShelfRows: View {
    @Environment(\.cardMetrics) private var metrics
    let shelf: Shelf
    var title: Text?

    var body: some View {
        ShelfHeader(title: title ?? Text(verbatim: shelf.title ?? ""), more: Route.more(shelf))
            .listRowSeparator(.hidden)
            .padding(.top, 12)
        CardCarousel(items: shelf.items)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
    }
}

/// Состояние страницы вместо списка: загрузка или ошибка с «Повторить».
struct PageStateView<Value>: View {
    let state: Loadable<Value>
    let retry: () -> Void

    var body: some View {
        switch state {
        case .failed(let kind): ErrorStateView(kind: kind, retry: retry)
        default: LoadingView()
        }
    }
}
