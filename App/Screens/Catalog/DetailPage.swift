import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Детальный экран (альбом, плейлист, исполнитель): шапка и список. В узком окне шапка — первая строка списка,
/// а название переходит в панель навигации, когда шапка уходит из вида; в широком (iPad, Mac) — две колонки:
/// шапка слева, список справа (docs/PROMPT.md §5.3, REWRITE §3.12).
struct DetailPage<Header: View, Rows: View>: View {
    let title: String
    var twoColumns = true
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
                        header()
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                    }
                    .frame(width: min(400, proxy.size.width * 0.36))
                    Divider()
                    list(includeHeader: false)
                }
            } else {
                list(includeHeader: true)
            }
        }
        .modifier(CardMetricsReader())
        .navigationTitle(Text(verbatim: headerVisible ? "" : title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func list(includeHeader: Bool) -> some View {
        SelectableList(target: target, context: context) {
            if includeHeader {
                header()
                    .frame(maxWidth: .infinity)
                    .onScrollVisibilityChange(threshold: 0.2) { headerVisible = $0 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
                    .listRowSeparator(.hidden, edges: .all)
            }
            rows()
        }
        .listStyle(.plain)
        .onAppear { if !includeHeader { headerVisible = true } }
    }
}

/// Шапка коллекции: обложка, название, подзаголовок и кнопки «Слушать · Перемешать» (docs/PROMPT.md §5.9).
struct CollectionHeader<Subtitle: View, Actions: View>: View {
    let artworkURL: String?
    var circle = false
    let title: String
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            ArtworkView(url: artworkURL, size: circle ? 140 : 240, shape: circle ? .circle : .rounded)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
            subtitle()
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                actions()
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: 420)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

/// «Слушать» — главная кнопка коллекции.
struct PlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("collection.play", systemImage: "play.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// «Перемешать» (у канала — «Перемешать видео»).
struct ShuffleButton: View {
    var title: LocalizedStringResource = "collection.shuffle"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "shuffle")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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
