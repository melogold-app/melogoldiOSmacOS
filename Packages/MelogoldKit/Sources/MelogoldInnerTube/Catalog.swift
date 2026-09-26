import Foundation
import MelogoldCore

/// Страницы каталога (срез 3): обзор, настроения, альбом, плейлист, исполнитель, канал. Порт `YouTubeMusic.cs`
/// Windows; разбор — по ключам рендереров, а не по локализованным заголовкам (REWRITE §4.8.2).
extension YouTubeMusic {
    // MARK: - Разделы

    /// «Обзор» YTM (`FEmusic_explore`): новые альбомы, настроения, «В тренде», новые клипы — одним запросом
    /// для Трендов и Нового (REWRITE §3.3).
    public func explore() async throws -> ExplorePage {
        ExplorePage(shelves: try await browseShelves("FEmusic_explore", params: nil), loadedAt: Date())
    }

    public func moods() async throws -> [Shelf] {
        try await browseShelves("FEmusic_moods_and_genres", params: nil)
    }

    public func newReleases() async throws -> [Shelf] {
        try await browseShelves("FEmusic_new_releases_albums", params: nil)
    }

    /// Полки произвольной страницы: настроение, «Все» полки исполнителя и т. п.
    public func browseShelves(_ browseId: String, params: String?) async throws -> [Shelf] {
        var body: [String: any Sendable] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try Self.parseShelves(try await client.postJSON(.webRemix, "browse", body: body), browseId: browseId)
    }

    static func parseShelves(_ response: JSON, browseId: String) throws -> [Shelf] {
        let sections = response.first(
            ["contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents"],
            ["contents", "twoColumnBrowseResultsRenderer", "secondaryContents", "sectionListRenderer", "contents"]
        )
        guard sections.exists else { throw YouTubeError(.parser, "нет секций в \(browseId)") }
        return MusicParsers.shelves(sections)
    }

    // MARK: - Альбом

    public func album(_ browseId: String) async throws -> AlbumDetails {
        try Self.parseAlbum(try await client.postJSON(.webRemix, "browse", body: ["browseId": browseId]), browseId: browseId)
    }

    static func parseAlbum(_ response: JSON, browseId: String) throws -> AlbumDetails {
        let header = response.at("contents", "twoColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content",
                                 "sectionListRenderer", "contents", 0, "musicResponsiveHeaderRenderer")
        let secondary = response.at("contents", "twoColumnBrowseResultsRenderer", "secondaryContents", "sectionListRenderer", "contents")
        guard header.exists, secondary.exists else { throw YouTubeError(.parser, "у альбома \(browseId) нет шапки") }
        let title = header["title"].text ?? ""
        let subtitle = header["subtitle"].runs
        let year = subtitle.map { $0.text.trimmingCharacters(in: .whitespaces) }.first { $0.count == 4 && $0.allSatisfy(\.isNumber) }
        let typeText = subtitle.first { !$0.isSeparator && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?
            .text.trimmingCharacters(in: .whitespaces)
        let strapline = header["straplineTextOne"]
        let artists = strapline.runs.filter { $0.browseId != nil }.map { ArtistRef(id: $0.browseId, name: $0.text) }
        let artistsText = strapline.text
        let thumbnail = header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail

        let shelf = secondary.array.map { $0["musicShelfRenderer"] }.first { $0.exists } ?? JSON(nil)
        let rows = MusicParsers.items(of: shelf["contents"]).compactMap(\.track)
        let playlistId = shelf["contents"].array.compactMap {
            $0.str("musicResponsiveListItemRenderer", "flexColumns", 0, "musicResponsiveListItemFlexColumnRenderer", "text", "runs", 0,
                   "navigationEndpoint", "watchEndpoint", "playlistId")
        }.first
        let album = AlbumItem(browseId: browseId, title: title, artists: artists, artistsText: artistsText, year: year,
                              typeText: typeText, thumbnailUrl: thumbnail, playlistId: playlistId)
        let tracks = rows.map { row -> Track in
            var track = row
            track.albumId = browseId
            track.albumTitle = title
            if track.thumbnailUrl == nil { track.thumbnailUrl = thumbnail }
            if !row.artists.contains(where: { $0.id != nil }) {
                track.artists = artists
                track.artistsText = artistsText
            }
            if track.videoType == nil { track.videoType = VideoType.song }
            return track
        }
        let shelves = MusicParsers.shelves(secondary).filter { shelf in
            guard let first = shelf.items.first else { return false }
            return first.track == nil
        }
        return AlbumDetails(
            album: album, description: header.at("description", "musicDescriptionShelfRenderer", "description").text,
            countText: header["secondSubtitle"].text, tracks: tracks, shelves: shelves
        )
    }

    // MARK: - Плейлист

    public func playlist(_ playlistId: String) async throws -> PlaylistDetails {
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        return try Self.parsePlaylist(try await client.postJSON(.webRemix, "browse", body: ["browseId": browseId]), browseId: browseId)
    }

    static func parsePlaylist(_ response: JSON, browseId: String) throws -> PlaylistDetails {
        let first = response.at("contents", "twoColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents", 0)
        let header = [first["musicResponsiveHeaderRenderer"],
                      first.at("musicEditablePlaylistDetailHeaderRenderer", "header", "musicResponsiveHeaderRenderer"),
                      response.at("header", "musicDetailHeaderRenderer")].first { $0.exists } ?? JSON(nil)
        let secondary = response.first(
            ["contents", "twoColumnBrowseResultsRenderer", "secondaryContents", "sectionListRenderer", "contents"],
            ["contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents"]
        )
        let shelf = secondary.array.map { $0["musicPlaylistShelfRenderer"].exists ? $0["musicPlaylistShelfRenderer"] : $0["musicShelfRenderer"] }
            .first { $0.exists } ?? JSON(nil)
        guard header.exists || shelf.exists else { throw YouTubeError(.parser, "плейлист \(browseId) пуст") }
        let id = String(browseId.dropFirst(2))
        let thumbnail = header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail
            ?? header.at("thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail
        let author = header["straplineTextOne"].text ?? header.str("facepile", "avatarStackViewModel", "text", "content")
        let tracks = MusicParsers.items(of: shelf["contents"]).compactMap(\.track)
        return PlaylistDetails(
            playlist: PlaylistItem(playlistId: id, title: header["title"].text ?? "", subtitle: author, thumbnailUrl: thumbnail),
            description: header.at("description", "musicDescriptionShelfRenderer", "description").text,
            authorText: author, countText: header["secondSubtitle"].text, tracks: tracks,
            continuation: MusicParsers.continuation(shelf)
        )
    }

    /// Следующая страница плейлиста — и старый, и новый формат продолжений (REWRITE §4.8.3).
    public func playlistContinuation(_ token: String) async throws -> ItemsPage {
        Self.parsePlaylistContinuation(try await client.postJSON(.webRemix, "browse", body: ["continuation": token]))
    }

    static func parsePlaylistContinuation(_ response: JSON) -> ItemsPage {
        let old = response.first(["continuationContents", "musicPlaylistShelfContinuation"], ["continuationContents", "musicShelfContinuation"])
        if old.exists {
            return ItemsPage(items: MusicParsers.items(of: old["contents"]), continuation: MusicParsers.continuation(old))
        }
        let appended = response.at("onResponseReceivedActions", 0, "appendContinuationItemsAction", "continuationItems")
        return ItemsPage(items: MusicParsers.items(of: appended), continuation: MusicParsers.continuation(appended))
    }

    /// Весь плейлист со всеми продолжениями — для «Слушать» длинного списка и «Сохранить».
    public func playlistTracks(_ playlistId: String, max: Int = 5000) async throws -> [Track] {
        let page = try await playlist(playlistId)
        var tracks = page.tracks
        var seen = Set(tracks.map(\.videoId))
        var token = page.continuation
        while let current = token, tracks.count < max {
            let next = try await playlistContinuation(current)
            let fresh = next.items.compactMap(\.track).filter { seen.insert($0.videoId).inserted }
            tracks += fresh
            if next.continuation == current || next.items.isEmpty { break }
            token = next.continuation
        }
        return tracks
    }

    // MARK: - Исполнитель и канал

    /// Исполнитель YTM; если музыкального профиля нет (обычный канал `UC…`) — канал YouTube (REWRITE §4.8.5).
    public func artist(_ browseId: String) async throws -> ArtistDetails {
        let response = try await client.postJSON(.webRemix, "browse", body: ["browseId": browseId])
        if let details = Self.parseArtist(response, browseId: browseId) { return details }
        let channel = try await channel(browseId)
        return ArtistDetails(
            browseId: browseId, name: channel.name, description: channel.description, thumbnailUrl: channel.thumbnailUrl,
            subscribersText: channel.subscribersText, isChannel: true,
            shelves: channel.videos.isEmpty ? [] : [Shelf(title: nil, items: channel.videos.map(MusicItem.track))],
            continuation: channel.continuation
        )
    }

    /// Страница исполнителя, если у YTM есть музыкальные секции («Популярное», альбомы или синглы); иначе `nil`.
    static func parseArtist(_ response: JSON, browseId: String) -> ArtistDetails? {
        let header = response.first(["header", "musicImmersiveHeaderRenderer"], ["header", "musicVisualHeaderRenderer"],
                                    ["header", "musicHeaderRenderer"])
        let sections = response.at("contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content",
                                   "sectionListRenderer", "contents")
        let shelves = sections.exists ? MusicParsers.shelves(sections) : []
        // Одних клипов мало: архивный канал с парой клипов читается лучше как канал (REWRITE §3.7.2).
        let musical = shelves.contains { shelf in
            shelf.items.contains { item in
                switch item {
                case .album: return true
                case .track(let track): return !track.isVideo
                default: return false
                }
            }
        }
        guard header.exists, !shelves.isEmpty, musical else { return nil }
        let songsShelf = sections.array.map { $0["musicShelfRenderer"] }.first { $0.exists } ?? JSON(nil)
        let songsBrowse = songsShelf.str("title", "runs", 0, "navigationEndpoint", "browseEndpoint", "browseId")
            ?? songsShelf.str("bottomEndpoint", "browseEndpoint", "browseId")
        return ArtistDetails(
            browseId: browseId, name: header["title"].text ?? "", description: header["description"].text,
            thumbnailUrl: header.at("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails").bestThumbnail,
            subscribersText: header.at("subscriptionButton", "subscribeButtonRenderer", "longSubscriberCountText").text
                ?? header["monthlyListenerCount"].text,
            shelves: shelves,
            songsPlaylistId: songsBrowse.flatMap { $0.hasPrefix("VL") ? String($0.dropFirst(2)) : nil },
            radioPlaylistId: header.str("startRadioButton", "buttonRenderer", "navigationEndpoint", "watchPlaylistEndpoint", "playlistId")
                ?? header.str("startRadioButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint", "playlistId")
        )
    }

    /// Канал обычного YouTube (клиент WEB): шапка и вкладка «Видео».
    public func channel(_ channelId: String) async throws -> ChannelPage {
        let response = try await client.postJSON(.web, "browse", body: ["browseId": channelId, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        return WebParsers.channelPage(channelId: channelId, response: response)
    }

    public func channelContinuation(_ token: String) async throws -> ItemsPage {
        let response = try await client.postJSON(.web, "browse", body: ["continuation": token])
        return WebParsers.gridPage(response.at("onResponseReceivedActions", 0, "appendContinuationItemsAction", "continuationItems"))
    }

    /// Ссылка `/@handle`, `/c/…`, `/user/…` → browseId канала (`navigation/resolve_url` клиента WEB). Часть
    /// адресов YouTube сначала переадресует (`urlEndpoint`, например `/@daftpunk` → `/daftpunk`) — второй шаг.
    public func resolveURL(_ url: String) async throws -> String? {
        var address = url
        for _ in 0..<3 {
            let response = try await client.postJSON(.web, "navigation/resolve_url", body: ["url": address])
            switch Self.parseResolvedURL(response) {
            case .browse(let browseId): return browseId
            case .redirect(let next) where next != address: address = next
            default: return nil
            }
        }
        return nil
    }

    enum ResolvedURL: Equatable {
        case browse(String)
        case redirect(String)
        case notFound
    }

    static func parseResolvedURL(_ response: JSON) -> ResolvedURL {
        if let browseId = response.str("endpoint", "browseEndpoint", "browseId") { return .browse(browseId) }
        if let url = response.str("endpoint", "urlEndpoint", "url"), let host = URL(string: url)?.host()?.lowercased(),
           host == "youtube.com" || host.hasSuffix(".youtube.com") {
            return .redirect(url)
        }
        return .notFound
    }

    /// Вкладка «Похожие» из «Далее»: треки, альбомы, исполнители («Для вас», автовоспроизведение).
    public func related(_ relatedBrowseId: String) async throws -> [Shelf] {
        let response = try await client.postJSON(.webRemix, "browse", body: ["browseId": relatedBrowseId])
        return MusicParsers.shelves(response.at("contents", "sectionListRenderer", "contents"))
    }
}

/// «Обзор» YouTube Music, разобранный по назначению полок — по ссылкам «Все», а не по локализованным заголовкам.
public struct ExplorePage: Hashable, Codable, Sendable {
    public var newReleases: Shelf?
    public var moods: Shelf?
    public var trending: Shelf?
    public var newVideos: Shelf?
    public var loadedAt: Date

    public init(shelves: [Shelf], loadedAt: Date) {
        self.loadedAt = loadedAt
        for shelf in shelves {
            switch shelf.moreBrowseId {
            case "FEmusic_new_releases_albums": newReleases = shelf
            case "FEmusic_moods_and_genres": moods = shelf
            case "FEmusic_new_releases_videos": newVideos = shelf
            case let more? where more.hasPrefix("VL") && !shelf.tracks.isEmpty && trending == nil: trending = shelf
            default: break
            }
        }
    }

    /// Плейлист «Весь список» чарта «В тренде».
    public var trendingPlaylistId: String? {
        trending?.moreBrowseId.map { $0.hasPrefix("VL") ? String($0.dropFirst(2)) : $0 }
    }
}
