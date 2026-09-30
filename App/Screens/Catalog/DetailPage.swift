import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Детальный экран (альбом, плейлист, исполнитель): шапка и список. В узком окне шапка — первая строка списка,
/// а название переходит в панель навигации, когда шапка уходит из вида; в широком (iPad, Mac) — две колонки:
/// шапка слева, список справа (docs/PROMPT.md §5.3, REWRITE §3.12).
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
    @ViewBuilder let header: () -> Header
    @ViewBuilder let rows: () -> Rows
    let target: (String) -> RowTarget?
    var context: (String) -> TrackMenuContext? = { _ in nil }

    @State private var headerVisible = true

    var body: some View {
        GeometryReader { proxy in
            if twoColumns, proxy.size.width >= 760 {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: Design.Space.s) { header() }
                            .environment(\.detailIsColumn, true)
                            .padding(.horizontal, Design.Space.l)
                            .padding(.vertical, Design.Space.m)
                    }
                    .frame(width: min(400, proxy.size.width * 0.36))
                    Divider()
                    list(includeHeader: false, bleeds: false)
                }
            } else {
                // Фото исполнителя идёт до верхнего края только в узком окне; в широком шапка — строка с аватаром
                let bleeds = fullBleedHeader && proxy.size.width < DetailLayout.heroWide
                list(includeHeader: true, bleeds: bleeds)
                    .modifier(TopBleed(enabled: bleeds))
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(verbatim: headerVisible ? "" : title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func list(includeHeader: Bool, bleeds: Bool) -> some View {
        SelectableList(target: target, context: context, rowIds: rowIds, collectionName: collectionName ?? title,
                       showsSelectButton: showsSelectButton) {
            if includeHeader {
                VStack(spacing: Design.Space.s) { header() }
                    .environment(\.detailBleeds, bleeds)
                    .frame(maxWidth: .infinity)
                    .onScrollVisibilityChange(threshold: 0.2) { headerVisible = $0 }
                    .listRowInsets(bleeds ? EdgeInsets() : EdgeInsets(top: Design.Space.xs, leading: 20, bottom: Design.Space.m, trailing: 20))
                    .listRowSeparator(.hidden, edges: .all)
            }
            rows()
        }
        .listStyle(.plain)
        .onAppear { if !includeHeader { headerVisible = true } }
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
    static let compactCover: HeaderStyle = .hero
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
    let title: String
    /// Обложка по стороне квадрата, которую считает шапка.
    @ViewBuilder let artwork: (CGFloat) -> Art
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let actions: () -> Actions
    @State private var width: CGFloat = 0

    @Environment(\.detailIsColumn) private var inColumn
    @Environment(\.dynamicTypeSize) private var typeSize
    /// В колонке широкого окна фото-шапка становится обложкой по центру.
    private var effectiveStyle: Style { inColumn && style == .hero ? .cover : style }
    private var leading: Bool { effectiveStyle == .hero }
    private var wide: Bool { effectiveStyle == .hero && width >= DetailLayout.heroWide }

    var body: some View {
        Group {
            if wide {
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
            // Крупный шрифт: «Слушать» и «Перемешать» друг под другом — рядом обе обрезались до «Слу…»
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Design.Space.s)) : AnyLayout(HStackLayout(spacing: Design.Space.s))) {
                actions()
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: leading ? (wide ? 420 : .infinity) : 420)
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
            .padding(.top, Design.Space.xxs)
            .padding(.bottom, leading ? Design.Space.s : 0)
        }
    }

    @ViewBuilder
    private var art: some View {
        switch effectiveStyle {
        case .cover:
            // Пока ширина не измерена, обложка стоит на запасном размере: шапка не прыгает на первом кадре
            let side = width > 0 ? min(340, max(200, width - 2 * Design.Space.xl)) : 280
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
    init(artworkURL: String?, style: Style = .cover, wideCircle: Bool = false, title: String, @ViewBuilder subtitle: @escaping () -> Subtitle,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(style: style, wideCircle: wideCircle, title: title, artwork: { side in
            ArtworkView(url: artworkURL, size: side, shape: style == .avatar ? .circle : style == .hero ? .square : .rounded,
                        cornerRadius: style == .cover ? Design.Radius.cover : nil)
        }, subtitle: subtitle, actions: actions)
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
        .buttonStyle(.borderedProminent)
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
        .buttonStyle(.bordered)
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
