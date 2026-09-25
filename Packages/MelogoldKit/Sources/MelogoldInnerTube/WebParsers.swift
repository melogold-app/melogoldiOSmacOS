import Foundation
import MelogoldCore

/// Страница канала обычного YouTube: шапка и вкладка «Видео».
public struct ChannelPage: Hashable, Sendable {
    public var channelId: String
    public var name: String
    public var thumbnailUrl: String?
    public var subscribersText: String?
    public var description: String?
    public var videos: [Track]
    public var continuation: String?
}

/// Разбор ответов обычного YouTube (клиент WEB, REWRITE §4.8.1–§4.8.2): `videoRenderer`, `channelRenderer`,
/// `lockupViewModel` (видео и плейлисты в новой разметке), страница канала. Shorts, полки Shorts и промо
/// отбрасываются. Порт `WebParsers.cs` Windows.
enum WebParsers {
    static func searchPage(_ sections: JSON) -> ItemsPage {
        var items: [MusicItem] = []
        var continuation: String?
        for section in sections.array {
            if section["itemSectionRenderer"].exists {
                for entry in section.items("itemSectionRenderer", "contents") {
                    if let parsed = item(entry) { items.append(parsed) }
                }
            } else if section["continuationItemRenderer"].exists {
                continuation = section.str("continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token")
            } else if let parsed = item(section) {
                items.append(parsed)
            }
        }
        return ItemsPage(items: items, continuation: continuation)
    }

    static func gridPage(_ contents: JSON) -> ItemsPage {
        var items: [MusicItem] = []
        var continuation: String?
        for entry in contents.array {
            if entry["continuationItemRenderer"].exists {
                continuation = entry.str("continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token")
            } else {
                let content = entry.at("richItemRenderer", "content")
                if let parsed = item(content.exists ? content : entry) { items.append(parsed) }
            }
        }
        return ItemsPage(items: items, continuation: continuation)
    }

    private static func item(_ node: JSON) -> MusicItem? {
        guard node.exists else { return nil }
        if node["videoRenderer"].exists { return video(node["videoRenderer"]).map(MusicItem.track) }
        if node["channelRenderer"].exists { return channel(node["channelRenderer"]).map(MusicItem.artist) }
        if node["lockupViewModel"].exists { return lockup(node["lockupViewModel"]) }
        let playlist = node["playlistRenderer"]
        if playlist.exists {
            guard let id = playlist.str("playlistId"), let title = playlist["title"].text, !title.isEmpty else { return nil }
            return .playlist(PlaylistItem(
                playlistId: id, title: title, subtitle: playlist["longBylineText"].text,
                thumbnailUrl: playlist.at("thumbnails", 0, "thumbnails").bestThumbnail
            ))
        }
        return nil
    }

    static func video(_ r: JSON) -> Track? {
        guard let videoId = r.str("videoId"), let title = r["title"].text, !title.isEmpty else { return nil }
        let overlays = r["thumbnailOverlays"].array
        let isShort = r.at("navigationEndpoint", "reelWatchEndpoint").exists
            || overlays.contains { $0.str("thumbnailOverlayTimeStatusRenderer", "style") == "SHORTS" }
        if isShort { return nil }
        let isLive = r["badges"].array.contains { $0.str("metadataBadgeRenderer", "style") == "BADGE_STYLE_TYPE_LIVE_NOW" }
            || overlays.contains { $0.str("thumbnailOverlayTimeStatusRenderer", "style") == "LIVE" }
        let owner = r["ownerText"].runs.first ?? r["longBylineText"].runs.first
        let channelName = owner?.text.trimmingCharacters(in: .whitespaces)
        let duration = isLive ? nil : r["lengthText"].text
        return Track(
            videoId: videoId, title: title,
            artists: channelName.map { [ArtistRef(id: owner?.browseId, name: $0)] } ?? [],
            artistsText: channelName, durationMs: Durations.parse(duration),
            thumbnailUrl: r.at("thumbnail", "thumbnails").bestThumbnail,
            videoType: isLive ? VideoType.live : VideoType.ugc,
            viewsText: r["shortViewCountText"].text ?? r["viewCountText"].text
        )
    }

    private static func channel(_ r: JSON) -> ArtistItem? {
        guard let id = r.str("channelId"), let title = r["title"].text, !title.isEmpty else { return nil }
        var thumbnail = r.at("thumbnail", "thumbnails").bestThumbnail
        if let value = thumbnail, value.hasPrefix("//") { thumbnail = "https:" + value }
        return ArtistItem(
            browseId: id, name: title, subtitle: r["videoCountText"].text ?? r["subscriberCountText"].text,
            thumbnailUrl: thumbnail, isChannel: true
        )
    }

    /// `lockupViewModel`: видео или плейлист новой разметки YouTube.
    private static func lockup(_ r: JSON) -> MusicItem? {
        let meta = r.at("metadata", "lockupMetadataViewModel")
        guard let id = r.str("contentId"), let title = meta.str("title", "content"), !title.isEmpty else { return nil }
        let rows: [[String]] = meta.at("metadata", "contentMetadataViewModel", "metadataRows").array
            .map { row in row["metadataParts"].array.compactMap { part in part.str("text", "content").flatMap { $0.isEmpty ? nil : $0 } } }
            .filter { !$0.isEmpty }
        let image = r.first(["contentImage", "thumbnailViewModel", "image", "sources"],
                            ["contentImage", "collectionThumbnailViewModel", "primaryThumbnail", "thumbnailViewModel", "image", "sources"])
        let badges = r.findAll("thumbnailBadgeViewModel")
        let durationBadge = badges.compactMap { $0.str("text") }.first { MusicParsers.isDuration($0) }

        switch r.str("contentType") {
        case "LOCKUP_CONTENT_TYPE_VIDEO":
            // В поиске строки метаданных — «канал», затем «просмотры · дата»; на канале — только «просмотры · дата».
            let channelName = rows.count > 1 ? rows[0].first : nil
            let channelId = meta.findAll("browseEndpoint").compactMap { $0.str("browseId") }.first { $0.hasPrefix("UC") }
            let isLive = durationBadge == nil && badges.contains { $0.str("badgeStyle") == "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE" }
            return .track(Track(
                videoId: id, title: title,
                artists: channelName.map { [ArtistRef(id: channelId, name: $0)] } ?? [],
                artistsText: channelName, durationMs: Durations.parse(durationBadge),
                thumbnailUrl: image.bestThumbnail, videoType: isLive ? VideoType.live : VideoType.ugc,
                viewsText: rows.last?.first
            ))
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_ALBUM":
            // Миксы RD… — бесконечные очереди, а не плейлисты.
            if id.hasPrefix("RD"), !id.hasPrefix("RDCLAK") { return nil }
            return .playlist(PlaylistItem(
                playlistId: id, title: title, subtitle: rows.first.map { $0.joined(separator: " · ") },
                thumbnailUrl: image.bestThumbnail
            ))
        default:
            return nil
        }
    }

    static func channelPage(channelId: String, response: JSON) -> ChannelPage {
        let header = response.at("header", "pageHeaderRenderer", "content", "pageHeaderViewModel")
        let metadata = response.at("metadata", "channelMetadataRenderer")
        let name = (metadata.str("title") ?? header.str("title", "dynamicTextViewModel", "text", "content")
            ?? response.str("header", "pageHeaderRenderer", "pageTitle") ?? "").trimmingCharacters(in: .whitespaces)
        let avatar = metadata.at("avatar", "thumbnails").bestThumbnail
            ?? header.at("image", "decoratedAvatarViewModel", "avatar", "avatarViewModel", "image", "sources").bestThumbnail
        let subscribers = header.at("metadata", "contentMetadataViewModel", "metadataRows").array
            .flatMap { $0["metadataParts"].array }
            .compactMap { $0.str("text", "content") }
            .first { $0.contains(where: \.isNumber) && !$0.hasPrefix("@") }
        let selected = response.at("contents", "twoColumnBrowseResultsRenderer", "tabs").array
            .map { $0["tabRenderer"] }
            .first { $0.flag("selected") }
        let grid = selected?.at("content", "richGridRenderer", "contents") ?? JSON(nil)
        let page = grid.exists ? gridPage(grid) : ItemsPage(items: [], continuation: nil)
        let videos = page.items.compactMap(\.track).map { track -> Track in
            var copy = track
            copy.artists = [ArtistRef(id: channelId, name: name)]
            copy.artistsText = name
            return copy
        }
        return ChannelPage(
            channelId: channelId, name: name, thumbnailUrl: avatar, subscribersText: subscribers,
            description: metadata.str("description"), videos: videos, continuation: page.continuation
        )
    }
}
