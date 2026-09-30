import SwiftUI
import MelogoldCore

/// Размеры карточек полок: на iPhone мельче, на iPad, Mac и Vision крупнее.
struct CardMetrics {
    let compact: Bool

    var square: CGFloat { compact ? 150 : 176 }
    var wide: CGFloat { compact ? 240 : 280 }
    var avatar: CGFloat { compact ? 110 : 132 }
    /// Поля страницы: как у больших заголовков и строк списка — 16 pt на iPhone, 20 pt на широком экране.
    var margin: CGFloat { Design.Layout.rowMargin(regular: !compact) }
    /// Между карточками в карусели и сетке.
    var gap: CGFloat { compact ? 12 : 16 }
}

private struct CardMetricsKey: EnvironmentKey {
    static let defaultValue = CardMetrics(compact: true)
}

extension EnvironmentValues {
    var cardMetrics: CardMetrics {
        get { self[CardMetricsKey.self] }
        set { self[CardMetricsKey.self] = newValue }
    }
}

/// Задаёт `cardMetrics` по классу ширины (на Mac — всегда крупные).
struct CardMetricsReader: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.cardMetrics, CardMetrics(compact: sizeClass != .regular))
        #else
        content.environment(\.cardMetrics, CardMetrics(compact: false))
        #endif
    }
}

/// Заголовок полки: название (как у системных приложений — крупное и жирное) и «Все ›», если у полки есть полный список.
/// Кнопка «Все ›» остаётся мелкой по виду, но нажимается с запасом: зона нажатия шире текста на 12 pt с каждой стороны.
struct ShelfHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: Text
    var more: Route?
    var moreTitle: LocalizedStringResource = "catalog.seeAll"

    var body: some View {
        // На крупном шрифте «Все ›» встаёт под название: в одной строке оба ломались по слогам
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Design.Space.xs))
        layout {
            title
                .font(.title2.bold())
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize == false { Spacer(minLength: 0) }
            if let more {
                Button {
                    model.open(more)
                } label: {
                    HStack(spacing: 2) {
                        Text(moreTitle)
                        Image(systemName: "chevron.forward").imageScale(.small).fontWeight(.semibold).accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle().inset(by: -12))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// Карусель карточек (альбомы, плейлисты, исполнители, клипы): листается вбок, следующая карточка выглядывает.
struct CardCarousel: View {
    @Environment(\.cardMetrics) private var metrics
    let items: [MusicItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: metrics.gap) {
                ForEach(items) { item in
                    ItemCard(item: item)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, metrics.margin, for: .scrollContent)
    }
}

/// Карточка элемента полки. Нажатие открывает коллекцию; трек (клип) играет — трек и радио.
struct ItemCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardMetrics) private var metrics
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: MusicItem
    /// В сетке карточка занимает всю колонку; в карусели — фиксированную ширину.
    var fill = false

    var body: some View {
        Button {
            model.activate(item)
        } label: {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            if let track = item.track { TrackMenuItems(track: track) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .album(let album):
            card(album.thumbnailUrl, album.title, [album.typeText, album.year].compactMap { $0 }.joined(separator: " · "),
                 width: metrics.square)
        case .playlist(let playlist):
            card(playlist.thumbnailUrl, playlist.title, playlist.subtitle ?? "", width: metrics.square)
        case .artist(let artist):
            VStack(spacing: Design.Space.xs) {
                if fill {
                    SquareFill { ArtworkView(url: artist.thumbnailUrl, size: $0, shape: .circle) }
                } else {
                    ArtworkView(url: artist.thumbnailUrl, size: metrics.avatar, shape: .circle)
                }
                Text(artist.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: fill ? nil : metrics.avatar)
        case .track(let track):
            if track.isVideo {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if fill {
                            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay { GeometryReader { ArtworkView(url: track.artworkURL, size: $0.size.width, shape: .wide,
                                                                        cornerRadius: Design.Radius.artwork($0.size.width / 2)) } }
                        } else {
                            ArtworkView(url: track.artworkURL, size: metrics.wide, shape: .wide, cornerRadius: Design.Radius.artwork(metrics.wide / 2))
                        }
                    }
                    .padding(.bottom, Design.Space.xxs)
                    Text(track.title).font(.subheadline).lineLimit(2)
                    Text(track.artistsText ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: fill ? nil : metrics.wide, alignment: .leading)
            } else {
                card(track.artworkURL, track.title, track.artistsText ?? "", width: metrics.square)
            }
        case .mood(let mood):
            MoodTileLabel(mood: mood)
                .frame(width: fill ? nil : metrics.square)
        }
    }

    private func card(_ url: String?, _ title: String, _ subtitle: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if fill {
                    SquareFill { ArtworkView(url: url, size: $0, cornerRadius: Design.Radius.artwork($0)) }
                } else {
                    ArtworkView(url: url, size: width, cornerRadius: Design.Radius.artwork(width))
                }
            }
            .padding(.bottom, Design.Space.xxs)
            Text(title)
                .font(.subheadline)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .frame(width: fill ? nil : width, alignment: .leading)
    }
}

/// Плитка настроения: название на фоне, подкрашенном цветом из ответа YouTube (REWRITE §3.3). Цвет приглушён до лёгкого
/// оттенка поверх системной заливки — плитка читается в светлой и тёмной теме, а без цвета в ответе остаётся нейтральной.
/// (Прежняя полоска цвета у прозрачных цветов рисовалась бледной линией — выглядела как ошибка.)
struct MoodTileLabel: View {
    let mood: MoodItem

    var body: some View {
        Text(mood.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, Design.Space.s)
            .background {
                let shape = RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                ZStack {
                    shape.fill(.fill.tertiary)
                    if let color = tint { shape.fill(color.opacity(0.22)) }
                }
            }
    }

    /// ARGB из API; прозрачный цвет — без оттенка (VT#1379).
    private var tint: Color? {
        guard let argb = mood.color, argb >> 24 != 0 else { return nil }
        return Color(red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255)
    }
}

/// Сетка плиток настроений.
struct MoodGrid: View {
    @Environment(AppModel.self) private var model
    let moods: [MoodItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(moods) { mood in
                Button {
                    model.open(.mood(mood))
                } label: {
                    MoodTileLabel(mood: mood)
                }
                .buttonStyle(CardPressStyle())
            }
        }
    }
}

/// Сетка треков из 4 рядов, листается вбок, следующая колонка выглядывает («В тренде», REWRITE §3.3).
/// Нажатие — список с этого трека. Высота ряда и обложка растут вместе с Dynamic Type: название и исполнитель не режутся.
struct TrackGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardMetrics) private var metrics
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60
    let tracks: [Track]
    var numbered = true
    var rows = 4
    /// «Не интересно» — только в «Для вас».
    var notInterested: ((Track) -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            // Крупный шрифт: четыре ряда вбок не помещают названий — один столбец во всю ширину, первые десять треков
            VStack(alignment: .leading, spacing: Design.Space.s) {
                ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                    cell(index, track)
                }
            }
            .shelfInset()
        } else {
            carousel
        }
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(rowHeight), spacing: 4), count: rows), spacing: metrics.gap + 4) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    cell(index, track)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            metrics.compact ? length * 0.86 : min(360, max(280, length / 3 - 16))
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, metrics.margin, for: .scrollContent)
    }

    private func cell(_ index: Int, _ track: Track) -> some View {
        let isCurrent = model.services.player.currentTrack?.videoId == track.videoId
        return HStack(spacing: 0) {
            Button {
                model.play(tracks, startAt: index)
            } label: {
                HStack(spacing: Design.Space.s) {
                    if numbered {
                        Text(verbatim: "\(index + 1)")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 22)
                    }
                    ArtworkView(url: track.artworkURL, size: Design.Layout.rowArtwork, cornerRadius: Design.Radius.artwork(Design.Layout.rowArtwork))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        Text(track.artistsText ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                TrackMenuItems(track: track)
                if let notInterested {
                    Button { notInterested(track) } label: { Label("new.notInterested", systemImage: "hand.thumbsdown") }
                }
            }
            .accessibilityElement(children: .combine)
            TrackMenuButton(track: track)
        }
    }
}

/// «Данные от 14:02» — без сети показана сохранённая копия (GLOSSARY §4.3).
struct CachedDataChip: View {
    let date: Date

    var body: some View {
        Label {
            Text("catalog.dataFrom \(Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened))")
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: Capsule())
    }
}
