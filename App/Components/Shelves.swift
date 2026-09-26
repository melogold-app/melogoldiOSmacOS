import SwiftUI
import MelogoldCore

/// Размеры карточек полок: на iPhone мельче, на iPad, Mac и Vision крупнее.
struct CardMetrics {
    let compact: Bool

    var square: CGFloat { compact ? 150 : 176 }
    var wide: CGFloat { compact ? 240 : 280 }
    var avatar: CGFloat { compact ? 110 : 132 }
    var margin: CGFloat { compact ? 16 : 20 }
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

/// Заголовок полки: название и «Все ›», если у полки есть полный список.
struct ShelfHeader: View {
    @Environment(AppModel.self) private var model
    let title: Text
    var more: Route?
    var moreTitle: LocalizedStringResource = "catalog.seeAll"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let more {
                Button {
                    model.open(more)
                } label: {
                    HStack(spacing: 2) {
                        Text(moreTitle)
                        Image(systemName: "chevron.forward").imageScale(.small)
                    }
                    .font(.subheadline)
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
            LazyHStack(alignment: .top, spacing: 14) {
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
    let item: MusicItem

    var body: some View {
        Button {
            model.activate(item)
        } label: {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            VStack(spacing: 6) {
                ArtworkView(url: artist.thumbnailUrl, size: metrics.avatar, shape: .circle)
                Text(artist.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: metrics.avatar)
        case .track(let track):
            if track.isVideo {
                VStack(alignment: .leading, spacing: 4) {
                    ArtworkView(url: track.artworkURL, size: metrics.wide, shape: .wide)
                    Text(track.title).font(.subheadline).lineLimit(2)
                    Text(track.artistsText ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: metrics.wide, alignment: .leading)
            } else {
                card(track.artworkURL, track.title, track.artistsText ?? "", width: metrics.square)
            }
        case .mood(let mood):
            MoodTileLabel(mood: mood)
                .frame(width: metrics.square)
        }
    }

    private func card(_ url: String?, _ title: String, _ subtitle: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(url: url, size: width)
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Плитка настроения: название и полоска цвета из ответа YouTube (REWRITE §3.3).
struct MoodTileLabel: View {
    let mood: MoodItem

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(stripe)
                .frame(width: 4)
                .padding(.vertical, 10)
            Text(mood.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(minHeight: 52)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// ARGB из API; прозрачный цвет — системная линия (VT#1379).
    private var stripe: AnyShapeStyle {
        guard let argb = mood.color, argb >> 24 != 0 else { return AnyShapeStyle(.separator) }
        return AnyShapeStyle(Color(
            red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255
        ))
    }
}

/// Сетка плиток настроений.
struct MoodGrid: View {
    @Environment(AppModel.self) private var model
    let moods: [MoodItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(moods) { mood in
                Button {
                    model.open(.mood(mood))
                } label: {
                    MoodTileLabel(mood: mood)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Сетка треков из 4 рядов, листается вбок, следующая колонка выглядывает («В тренде», REWRITE §3.3).
/// Нажатие — список с этого трека.
struct TrackGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.cardMetrics) private var metrics
    let tracks: [Track]
    var numbered = true
    var rows = 4

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 8), count: rows), spacing: 16) {
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
        return HStack(spacing: 10) {
            Button {
                model.play(tracks, startAt: index)
            } label: {
                HStack(spacing: 10) {
                    if numbered {
                        Text("\(index + 1)")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24)
                    }
                    ArtworkView(url: track.artworkURL, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        Text(track.artistsText ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { TrackMenuItems(track: track) }
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
