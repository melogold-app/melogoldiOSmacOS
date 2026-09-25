import Foundation
import MelogoldCore

/// Разбор рендереров YouTube Music (WEB_REMIX). Тип элемента определяется по переходу (`pageType`,
/// `musicVideoType`), а не по локализованной подписи; поля трека — по ссылкам внутри подписи (`UC…` — исполнитель,
/// `MPREb_…` — альбом), а не по позиции (REWRITE §4.8.2). Порт `MusicParsers.cs` Windows.
enum MusicParsers {
    /// Подписи типа в смешанной выдаче: первая группа подписи, её выбрасываем.
    private static let typeLabels: Set<String> = [
        "song", "video", "album", "single", "ep", "playlist", "artist", "episode", "podcast", "profile", "composition",
        "композиция", "песня", "трек", "видео", "клип", "альбом", "сингл", "плейлист", "исполнитель", "выпуск", "подкаст", "профиль",
    ]

    private static let pageAlbum = "MUSIC_PAGE_TYPE_ALBUM"
    private static let pageAudiobook = "MUSIC_PAGE_TYPE_AUDIOBOOK"
    private static let pageArtist = "MUSIC_PAGE_TYPE_ARTIST"
    private static let pageUserChannel = "MUSIC_PAGE_TYPE_USER_CHANNEL"
    private static let pagePlaylist = "MUSIC_PAGE_TYPE_PLAYLIST"

    static func isDuration(_ text: String) -> Bool {
        text.wholeMatch(of: /\d{1,2}(:\d{2}){1,2}/) != nil
    }

    private static func isYear(_ text: String) -> Bool {
        text.wholeMatch(of: /\d{4}/) != nil
    }

    private static func musicVideoType(_ watchEndpoint: JSON) -> String? {
        watchEndpoint.str("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType")
    }

    private static func isArtistRun(_ run: Run) -> Bool {
        if let id = run.browseId, id.hasPrefix("UC") || id.hasPrefix("FEmusic_library_privately_owned_artist") { return true }
        return run.pageType == pageArtist || run.pageType == pageUserChannel
    }

    private static func isAlbumRun(_ run: Run) -> Bool {
        run.browseId?.hasPrefix("MPREb_") == true || run.pageType == pageAlbum
    }

    /// Подпись, разбитая по « • » на группы.
    private static func groups(_ runs: [Run]) -> [[Run]] {
        var groups: [[Run]] = [[]]
        for run in runs {
            if run.isSeparator {
                if !groups[groups.count - 1].isEmpty { groups.append([]) }
                continue
            }
            groups[groups.count - 1].append(run)
        }
        if groups.last?.isEmpty == true { groups.removeLast() }
        return groups
    }

    private static func groupText(_ group: [Run]) -> String {
        group.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }

    private static func artists(of group: [Run]) -> [ArtistRef] {
        let linked = group.filter(isArtistRun).map { ArtistRef(id: $0.browseId, name: $0.text.trimmingCharacters(in: .whitespaces)) }
        return linked.isEmpty ? [ArtistRef(id: nil, name: groupText(group))] : linked
    }

    private static func isExplicit(_ node: JSON, badges: String = "badges") -> Bool {
        node[badges].array.contains { $0.str("musicInlineBadgeRenderer", "icon", "iconType") == "MUSIC_EXPLICIT_BADGE" }
    }

    static func thumbnail(_ renderer: JSON) -> String? {
        renderer.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail
            ?? renderer.at("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail
            ?? renderer.at("thumbnail", "thumbnails").bestThumbnail
            ?? renderer.at("thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail
    }

    /// Что из подписи трека известно по группам: исполнители, альбом, длительность, просмотры, год.
    private struct TrackMeta {
        var artists: [ArtistRef] = []
        var artistsText: String?
        var albumId: String?
        var albumTitle: String?
        var duration: String?
        var views: String?
        var year: String?
    }

    private static func meta(_ groups: [[Run]]) -> TrackMeta {
        var artistsGroup: [Run]?
        var result = TrackMeta()
        var rest: [[Run]] = []
        let anyLinks = groups.contains { $0.contains { $0.browseId != nil } }
        for (index, group) in groups.enumerated() {
            let text = groupText(group)
            if text.isEmpty { continue }
            if let album = group.first(where: isAlbumRun) {
                result.albumId = album.browseId
                result.albumTitle = album.text
            } else if artistsGroup == nil, group.contains(where: isArtistRun) {
                artistsGroup = group
            } else if isDuration(text) {
                result.duration = text
            } else if isYear(text) {
                result.year = text
            } else if index == 0, group.allSatisfy({ $0.browseId == nil }),
                      typeLabels.contains(text.lowercased()) || (anyLinks && groups.count > 2) {
                continue
            } else if group.allSatisfy({ $0.browseId == nil }), text.contains(where: \.isNumber), artistsGroup != nil {
                if result.views == nil { result.views = text }
            } else {
                rest.append(group)
            }
        }
        if artistsGroup == nil, !rest.isEmpty {
            artistsGroup = rest.removeFirst()
        }
        if result.views == nil, let first = rest.first, groupText(first).contains(where: \.isNumber) {
            result.views = groupText(first)
        }
        if let artistsGroup {
            result.artists = artists(of: artistsGroup)
            result.artistsText = groupText(artistsGroup)
        }
        return result
    }

    private static func subtitleWithoutType(_ groups: [[Run]]) -> String? {
        var parts = groups.map(groupText).filter { !$0.isEmpty }
        if parts.count > 1, typeLabels.contains(parts[0].lowercased()) { parts.removeFirst() }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func playlistId(fromBrowseId browseId: String) -> String {
        browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
    }

    // MARK: - Строки

    /// `musicResponsiveListItemRenderer` → трек, альбом, исполнитель или плейлист; прочее (подкасты) — `nil`.
    static func responsiveItem(_ r: JSON) -> MusicItem? {
        guard r.exists else { return nil }
        let columns = r["flexColumns"].array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        guard let firstColumn = columns.first,
              let title = firstColumn.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }

        let browse = r.at("navigationEndpoint", "browseEndpoint")
        let browseId = browse.str("browseId")
        let pageType = browse.str("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType")
        let separator = Run(node: JSON(["text": " • "]))
        let subtitleRuns = columns.dropFirst().flatMap { $0.runs + [separator] }
        let parts = groups(subtitleRuns)
        let thumb = thumbnail(r)
        let overlay = r.at("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint")

        if let browseId {
            switch pageType {
            case pageAlbum, pageAudiobook:
                let info = meta(parts)
                let first = parts.first
                let typeText = first.flatMap { group -> String? in
                    let text = groupText(group)
                    return group.allSatisfy({ $0.browseId == nil }) && !isYear(text) ? text : nil
                }
                return .album(AlbumItem(
                    browseId: browseId, title: title, artists: info.artists, artistsText: info.artistsText, year: info.year,
                    typeText: typeText, thumbnailUrl: thumb, playlistId: overlay.str("watchPlaylistEndpoint", "playlistId"),
                    explicit: isExplicit(r)
                ))
            case pageArtist, pageUserChannel:
                return .artist(ArtistItem(
                    browseId: browseId, name: title, subtitle: subtitleWithoutType(parts), thumbnailUrl: thumb,
                    isChannel: pageType == pageUserChannel
                ))
            case pagePlaylist:
                return .playlist(PlaylistItem(
                    playlistId: playlistId(fromBrowseId: browseId), title: title, subtitle: subtitleWithoutType(parts), thumbnailUrl: thumb
                ))
            default:
                break
            }
        }

        let titleWatch = firstColumn.runs.map { $0.node.at("navigationEndpoint", "watchEndpoint") }.first { $0.exists } ?? JSON(nil)
        let overlayWatch = overlay["watchEndpoint"]
        guard let videoId = r.str("playlistItemData", "videoId") ?? titleWatch.str("videoId") ?? overlayWatch.str("videoId") else {
            return nil
        }
        let videoType = musicVideoType(titleWatch) ?? musicVideoType(overlayWatch)
        if videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { return nil }

        let fixedText = r["fixedColumns"].array
            .compactMap { $0.at("musicResponsiveListItemFixedColumnRenderer", "text").text }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let info = meta(parts)
        let trimmedFixed = fixedText?.trimmingCharacters(in: .whitespaces)
        let durationText = trimmedFixed.flatMap { isDuration($0) ? $0 : nil } ?? info.duration
        return .track(Track(
            videoId: videoId, title: title, artists: info.artists, artistsText: info.artistsText,
            albumId: info.albumId, albumTitle: info.albumTitle, durationMs: Durations.parse(durationText),
            thumbnailUrl: thumb, explicit: isExplicit(r), videoType: VideoType.fromMusicVideoType(videoType),
            viewsText: info.views,
            unavailable: r.str("musicItemRendererDisplayPolicy") == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        ))
    }

    // MARK: - Карточки

    /// `musicTwoRowItemRenderer` → альбом, исполнитель, плейлист или трек.
    static func twoRowItem(_ r: JSON) -> MusicItem? {
        guard r.exists, let title = r["title"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let parts = groups(r["subtitle"].runs)
        let thumb = thumbnail(r)
        let navigation = r["navigationEndpoint"]

        let browse = navigation["browseEndpoint"]
        if browse.exists {
            guard let browseId = browse.str("browseId") else { return nil }
            let pageType = browse.str("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType")
            switch pageType {
            case pageAlbum, pageAudiobook:
                let info = meta(parts)
                let linked = info.artists.filter { $0.id != nil }
                let first = parts.first.map(groupText)
                let typeText: String? = if let first, parts[0].allSatisfy({ $0.browseId == nil }), !isYear(first) { first } else { nil }
                return .album(AlbumItem(
                    browseId: browseId, title: title, artists: linked, artistsText: linked.isEmpty ? nil : info.artistsText,
                    year: info.year, typeText: typeText, thumbnailUrl: thumb,
                    playlistId: r.str("thumbnailOverlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer",
                                      "playNavigationEndpoint", "watchPlaylistEndpoint", "playlistId"),
                    explicit: isExplicit(r, badges: "subtitleBadges")
                ))
            case pageArtist, pageUserChannel:
                return .artist(ArtistItem(
                    browseId: browseId, name: title, subtitle: subtitleWithoutType(parts), thumbnailUrl: thumb,
                    isChannel: pageType == pageUserChannel
                ))
            case pagePlaylist:
                return .playlist(PlaylistItem(
                    playlistId: playlistId(fromBrowseId: browseId), title: title, subtitle: subtitleWithoutType(parts), thumbnailUrl: thumb
                ))
            default:
                return nil
            }
        }

        let watch = navigation["watchEndpoint"]
        if let videoId = watch.str("videoId") {
            let videoType = musicVideoType(watch)
            if videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" { return nil }
            let info = meta(parts)
            return .track(Track(
                videoId: videoId, title: title, artists: info.artists, artistsText: info.artistsText,
                albumId: info.albumId, albumTitle: info.albumTitle, durationMs: Durations.parse(info.duration),
                thumbnailUrl: thumb, videoType: VideoType.fromMusicVideoType(videoType), viewsText: info.views
            ))
        }
        return nil
    }

    /// `musicNavigationButtonRenderer` → плитка настроения.
    static func navigationButton(_ r: JSON) -> MusicItem? {
        let browse = r.at("clickCommand", "browseEndpoint")
        guard let title = r["buttonText"].text, !title.isEmpty, let browseId = browse.str("browseId") else { return nil }
        let color = r.int("solid", "leftStripeColor").map { UInt32(truncatingIfNeeded: $0) }
        return .mood(MoodItem(title: title, browseId: browseId, params: browse.str("params"), color: color))
    }

    /// Строка очереди «Далее» (`playlistPanelVideoRenderer`).
    static func panelVideo(_ r: JSON) -> Track? {
        guard r.exists,
              let videoId = r.str("videoId") ?? r.str("navigationEndpoint", "watchEndpoint", "videoId"),
              let title = r["title"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let info = meta(groups(r["longBylineText"].runs))
        let duration = r["lengthText"].text?.trimmingCharacters(in: .whitespaces)
        let videoType = musicVideoType(r.at("navigationEndpoint", "watchEndpoint"))
        return Track(
            videoId: videoId, title: title, artists: info.artists,
            artistsText: info.artistsText ?? r["shortBylineText"].text,
            albumId: info.albumId, albumTitle: info.albumTitle, durationMs: Durations.parse(duration),
            thumbnailUrl: r.at("thumbnail", "thumbnails").bestThumbnail, explicit: isExplicit(r),
            videoType: VideoType.fromMusicVideoType(videoType), unavailable: r["unplayableText"].exists
        )
    }

    // MARK: - Полки

    static func items(of contents: JSON) -> [MusicItem] {
        contents.array.compactMap { item -> MusicItem? in
            if item["musicResponsiveListItemRenderer"].exists { return responsiveItem(item["musicResponsiveListItemRenderer"]) }
            if item["musicTwoRowItemRenderer"].exists { return twoRowItem(item["musicTwoRowItemRenderer"]) }
            if item["musicNavigationButtonRenderer"].exists { return navigationButton(item["musicNavigationButtonRenderer"]) }
            if item["playlistPanelVideoRenderer"].exists { return panelVideo(item["playlistPanelVideoRenderer"]).map(MusicItem.track) }
            return nil
        }
    }

    /// Полки `sectionListRenderer.contents`: списки, карусели, сетки.
    static func shelves(_ sectionContents: JSON) -> [Shelf] {
        var shelves: [Shelf] = []
        for section in sectionContents.array {
            let list = section["musicShelfRenderer"]
            let carousel = section["musicCarouselShelfRenderer"]
            let grid = section["gridRenderer"]
            let playlist = section["musicPlaylistShelfRenderer"]
            let itemSection = section["itemSectionRenderer"]
            if list.exists {
                let more = list.first(["bottomEndpoint", "browseEndpoint"], ["title", "runs", 0, "navigationEndpoint", "browseEndpoint"])
                shelves.append(Shelf(title: list["title"].text, items: items(of: list["contents"]),
                                     moreBrowseId: more.str("browseId"), moreParams: more.str("params")))
            } else if carousel.exists {
                let header = carousel.at("header", "musicCarouselShelfBasicHeaderRenderer")
                let more = header.first(["moreContentButton", "buttonRenderer", "navigationEndpoint", "browseEndpoint"],
                                        ["title", "runs", 0, "navigationEndpoint", "browseEndpoint"])
                shelves.append(Shelf(title: header["title"].text, items: items(of: carousel["contents"]),
                                     moreBrowseId: more.str("browseId"), moreParams: more.str("params")))
            } else if grid.exists {
                shelves.append(Shelf(title: grid.at("header", "gridHeaderRenderer", "title").text, items: items(of: grid["items"])))
            } else if playlist.exists {
                shelves.append(Shelf(title: nil, items: items(of: playlist["contents"])))
            } else if itemSection.exists {
                for inner in itemSection["contents"].array where inner["gridRenderer"].exists {
                    let innerGrid = inner["gridRenderer"]
                    shelves.append(Shelf(title: innerGrid.at("header", "gridHeaderRenderer", "title").text, items: items(of: innerGrid["items"])))
                }
            }
        }
        return shelves.filter { !$0.items.isEmpty }
    }

    /// Токен продолжения: и старый `continuations[].nextContinuationData`, и новый `continuationItemRenderer`.
    static func continuation(_ shelf: JSON) -> String? {
        if let token = shelf.first(["continuations", 0, "nextContinuationData", "continuation"],
                                   ["continuations", 0, "nextRadioContinuationData", "continuation"]).string {
            return token
        }
        let contents = shelf["contents"].exists ? shelf["contents"].array : shelf.array
        return contents.compactMap { $0.str("continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token") }.last
    }
}
