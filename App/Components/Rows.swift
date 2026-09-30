import SwiftUI
import MelogoldCore

/// Строка трека (docs/PROMPT.md §5.8): обложка (у видео квадратная), название, исполнитель и альбом, справа длительность
/// и метки — E, загрузка (`DownloadBadge`: «скачано», кольцо, «в кэше»), «YouTube». У играющего трека вместо обложки —
/// значок «играет».
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let track: Track
    var subtitle: String?
    var isCurrent = false
    var dimmed = false
    /// Номер в списке: у альбома — вместо обложки, у «Популярного» исполнителя — перед ней.
    var number: Int?
    var showsArtwork = true
    /// Текст справа вместо длительности: время прослушивания в Истории.
    var trailing: String?
    /// Вторая строка справа, мельче: число прослушиваний в «Итогах» (значок ▶ и число; длинное «11 прослушиваний» не
    /// помещалось в строку, а подпись под названием обрезалась).
    var trailingPlays: Int?

    var body: some View {
        // Своё название, исполнитель и альбом (задание 0014): одна точка показа для всех списков
        let track = model.displayed(track)
        HStack(spacing: Design.Space.s) {
            if let number {
                Text(verbatim: "\(number)")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 24, alignment: .center)
            }
            if showsArtwork {
                ZStack {
                    ArtworkView(url: track.artworkURL, size: Design.Layout.rowArtwork,
                                cornerRadius: Design.Radius.artwork(Design.Layout.rowArtwork))
                    if isCurrent {
                        RoundedRectangle(cornerRadius: Design.Radius.artwork(Design.Layout.rowArtwork), style: .continuous)
                            .fill(.black.opacity(0.45))
                            .frame(width: Design.Layout.rowArtwork, height: Design.Layout.rowArtwork)
                        // Столбики под реальный звук (docs/PROMPT.md §4).
                        MusicBars(color: .white).frame(width: 22, height: 18)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                // E стоит сразу за названием, как в «Музыке»: у длинного названия обрезается текст, а не метка
                HStack(spacing: Design.Space.xxs) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(stacked ? nil : 1)
                    if track.explicit {
                        Image(systemName: "e.square.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                            .accessibilityLabel(Text("badge.explicit"))
                    }
                }
                let line = track.unavailable ? String(localized: "badge.unavailable") : (subtitle ?? track.subtitle)
                if !line.isEmpty {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacked ? nil : 1)
                }
                // Крупный шрифт: длительность и метки уходят третьей строкой — справа им не хватает места, и название
                // обрезалось до пяти букв
                if stacked {
                    HStack(spacing: Design.Space.xs) {
                        if let duration = trailing ?? track.durationLabel { durationText(duration) }
                        playsLabel
                        badges
                    }
                }
            }
            .rowSeparatorAtText()
            if !stacked {
                Spacer(minLength: Design.Space.xs)
                badges
                if let duration = trailing ?? track.durationLabel {
                    VStack(alignment: .trailing, spacing: 2) {
                        durationText(duration)
                        playsLabel
                    }
                }
            }
        }
        .opacity(dimmed || track.unavailable ? 0.38 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // Играющий трек VoiceOver называет: столбики вместо обложки для него — картинка
        .accessibilityValue(isCurrent ? Text("queue.nowPlaying") : Text(verbatim: ""))
    }

    private var stacked: Bool { typeSize.isAccessibilitySize }

    private func durationText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var playsLabel: some View {
        if let trailingPlays {
            HStack(spacing: 2) {
                Image(systemName: "play.fill").imageScale(.small)
                Text(verbatim: "\(trailingPlays)").monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("stats.playsCount \(trailingPlays)"))
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            DownloadBadge(videoId: track.videoId)
            if track.isVideo {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: "YouTube"))
            }
        }
        .font(.footnote)
    }
}

/// Строка видео в выдаче YouTube (REWRITE §3.11.2): превью 16:9 с длительностью или «В ЭФИРЕ», название до двух строк,
/// «канал · просмотры». Строки из ответа YouTube только показываются, числа из них не разбираются. На размерах
/// доступности превью встаёт над текстом во всю ширину (рядом 114 pt превью оставляли названию пять букв), текст переносится
/// целиком, а значки на превью не растут с шрифтом.
struct VideoRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let track: Track
    var isCurrent = false
    var dimmed = false

    var body: some View {
        let track = model.displayed(track)
        let stacked = typeSize.isAccessibilitySize
        AdaptiveStack(spacing: Design.Space.s, alignment: .top) {
            thumbnail(track, stacked: stacked)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(stacked ? nil : 2)
                Text([track.artistsText, track.viewsText].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(stacked ? nil : 1)
            }
            AdaptiveSpacer()
        }
        .opacity(dimmed ? 0.38 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? Text("queue.nowPlaying") : Text(verbatim: ""))
    }

    @ViewBuilder
    private func thumbnail(_ track: Track, stacked: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if stacked {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { GeometryReader { ArtworkView(url: track.artworkURL, size: $0.size.width, shape: .wide) } }
            } else {
                ArtworkView(url: track.artworkURL, size: 114, shape: .wide)
            }
            if track.videoType == VideoType.live {
                Text("badge.live")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
                    .iconTypeSize()
            } else if let duration = track.durationLabel {
                Text(duration)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    // «Понижение прозрачности»: подложка длительности почти сплошная — текст на кадре не зависит от просвета
                    .background(.black.opacity(reduceTransparency ? 0.9 : 0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
                    .iconTypeSize()
            }
        }
    }
}

/// Строка альбома, исполнителя или плейлиста.
struct CollectionRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: MusicItem

    var body: some View {
        HStack(spacing: Design.Space.s) {
            switch item {
            case .album(let album):
                cover(album.thumbnailUrl)
                labels(album.title, album.subtitle)
            case .artist(let artist):
                ArtworkView(url: artist.thumbnailUrl, size: Design.Layout.rowArtwork, shape: .circle)
                labels(artist.name, artist.subtitle ?? "")
            case .playlist(let playlist):
                cover(playlist.thumbnailUrl)
                labels(playlist.title, playlist.subtitle ?? "")
            case .mood(let mood):
                labels(mood.title, "")
            case .track(let track):
                TrackRow(track: track)
            }
            Spacer(minLength: 0)
            // Строки-коллекции открывают свой экран: стрелка показывает это, как у строк «Настроек»
            if case .track = item {} else {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func cover(_ url: String?) -> some View {
        ArtworkView(url: url, size: Design.Layout.rowArtwork, cornerRadius: Design.Radius.artwork(Design.Layout.rowArtwork))
    }

    private func labels(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .rowSeparatorAtText()
    }
}

/// Строка трека в списке: состояние «играет», «есть без сети», приглушение без сети и кнопка «…».
/// iPhone, iPad и Vision: нажатие — `target`, долгое нажатие — меню. Mac: действие даёт список (`SelectableList`):
/// щелчок выделяет, двойной щелчок или Return играет.
struct TrackListRow: View {
    @Environment(AppModel.self) private var model
    #if !os(macOS)
    @Environment(\.editMode) private var editMode
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let track: Track
    var subtitle: String?
    var number: Int?
    var showsArtwork = true
    var trailing: String?
    var trailingPlays: Int?
    /// Превью 16:9 — выдача YouTube и видео канала.
    var wide = false
    let target: RowTarget?
    /// Пункт меню «по месту»: «Убрать из плейлиста», «Убрать из истории».
    var context: TrackMenuContext?
    /// Кнопка «…» справа; без неё (строки «Итогов») меню — по долгому нажатию, а названию хватает места.
    var showsMenuButton = true

    var body: some View {
        let isCurrent = model.services.player.currentTrack?.videoId == track.videoId
        let cached = model.cachedIds.contains(track.videoId)
        let downloaded = model.library?.isDownloaded(track.videoId) == true
        let dimmed = !model.services.network.isOnline && !cached && !downloaded
        HStack(spacing: 4) {
            TapTarget(target: target) {
                if wide {
                    VideoRow(track: track, isCurrent: isCurrent, dimmed: dimmed)
                } else {
                    TrackRow(track: track, subtitle: subtitle, isCurrent: isCurrent, dimmed: dimmed, number: number,
                             showsArtwork: showsArtwork, trailing: trailing, trailingPlays: trailingPlays)
                }
            }
            #if !os(macOS)
            .contextMenu { if !isSelecting { TrackMenuItems(track: track, context: context) } }
            #endif
            if !isSelecting, showsMenuButton { TrackMenuButton(track: track, context: context) }
        }
        #if !os(macOS)
        // Вертикальные поля ровные у всех списков; у «…» зона нажатия 44 pt заходит под правое поле, а сам значок стоит на
        // общем поле списка (HIG «Lists and tables»: одна линия правого края)
        .listRowInsets(rowInsets)
        #endif
    }

    #if !os(macOS)
    private var rowInsets: EdgeInsets {
        let margin = Design.Layout.rowMargin(regular: sizeClass == .regular)
        let trailing = showsMenuButton && !isSelecting ? max(0, margin - Design.Layout.menuButtonSlack) : margin
        return EdgeInsets(top: Design.Layout.rowPadding, leading: margin, bottom: Design.Layout.rowPadding, trailing: trailing)
    }
    #endif

    /// Режим выбора (iPhone, iPad, Vision): нажатие отмечает строку, а не играет; кнопки «…» нет.
    private var isSelecting: Bool {
        #if os(macOS)
        false
        #else
        editMode?.wrappedValue.isEditing == true
        #endif
    }
}

/// Нажатие по строке на iPhone, iPad и Vision; на Mac строка — только содержимое, действие даёт список.
struct TapTarget<Label: View>: View {
    @Environment(AppModel.self) private var model
    #if !os(macOS)
    @Environment(\.editMode) private var editMode
    #endif
    let target: RowTarget?
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(macOS)
        label()
        #else
        if editMode?.wrappedValue.isEditing == true {
            // Режим выбора: нажатие по строке отмечает её (`List(selection:)`), а не играет
            label()
        } else {
            Button {
                if let target { model.activate(target) }
            } label: {
                label()
            }
            .buttonStyle(.plain)
        }
        #endif
    }
}

extension RowTarget {
    /// Элемент выдачи или полки: трек — одиночный трек и радио, микс — радио, прочее — свой экран.
    static func of(_ item: MusicItem) -> RowTarget? {
        switch item {
        case .track(let track): .single(track)
        case .playlist(let playlist) where playlist.isMix: .mix(playlist)
        default: Route.of(item).map(RowTarget.open)
        }
    }
}
