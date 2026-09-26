import Foundation

/// Исполнитель или канал в подписи трека: `id` — browseId (`UC…`), может отсутствовать.
public struct ArtistRef: Hashable, Codable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

/// Тип трека как в `TrackDto` сервера: `song | video | ugc | live | podcast_episode`. Держится строкой:
/// неизвестные значения не ломают разбор (API §1.3).
public enum VideoType {
    public static let song = "song"
    public static let video = "video"
    public static let ugc = "ugc"
    public static let live = "live"
    public static let podcastEpisode = "podcast_episode"

    /// YouTube Music `musicVideoType` → тип трека (REWRITE §4.8.2).
    public static func fromMusicVideoType(_ value: String?) -> String? {
        switch value {
        case nil: nil
        case "MUSIC_VIDEO_TYPE_ATV": song
        case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC": video
        case "MUSIC_VIDEO_TYPE_UGC": ugc
        case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": podcastEpisode
        default: video
        }
    }
}

/// Трек — любое видео YouTube (DESIGN §3.3): песня YTM, клип, обычное видео, трансляция. Видео и песни — равные
/// источники: ищутся, играют и лежат в очереди одинаково (docs/PROMPT.md §1).
public struct Track: Hashable, Codable, Sendable, Identifiable {
    public var videoId: String
    public var title: String
    public var artists: [ArtistRef]
    /// Подпись исполнителей как в YouTube («A, B и C»); у видео — имя канала.
    public var artistsText: String?
    public var albumId: String?
    public var albumTitle: String?
    public var durationMs: Int64?
    public var thumbnailUrl: String?
    public var explicit: Bool
    public var videoType: String?
    /// Только для показа: «1,2 млн просмотров» (числа из строк YouTube не разбираются).
    public var viewsText: String?
    public var unavailable: Bool

    public var id: String { videoId }

    public init(
        videoId: String, title: String, artists: [ArtistRef] = [], artistsText: String? = nil,
        albumId: String? = nil, albumTitle: String? = nil, durationMs: Int64? = nil, thumbnailUrl: String? = nil,
        explicit: Bool = false, videoType: String? = nil, viewsText: String? = nil, unavailable: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.artistsText = artistsText
        self.albumId = albumId
        self.albumTitle = albumTitle
        self.durationMs = durationMs
        self.thumbnailUrl = thumbnailUrl
        self.explicit = explicit
        self.videoType = videoType
        self.viewsText = viewsText
        self.unavailable = unavailable
    }

    /// Видео обычного YouTube (не песня каталога): метка «YouTube», квадратная обложка из превью 16:9.
    public var isVideo: Bool {
        guard let videoType else { return false }
        return videoType != VideoType.song
    }

    /// Подпись строки: «Исполнитель · Альбом».
    public var subtitle: String {
        [artistsText, albumTitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// Первый исполнитель или канал со ссылкой: «Открыть исполнителя» / «Открыть канал».
    public var primaryArtistId: String? {
        artists.first { $0.id != nil }?.id
    }
}

/// Альбом, сингл или EP (`MPREb_…`).
public struct AlbumItem: Hashable, Codable, Sendable, Identifiable {
    public var browseId: String
    public var title: String
    public var artists: [ArtistRef]
    public var artistsText: String?
    public var year: String?
    /// «Альбом», «Сингл», «EP» — как пришло от YouTube.
    public var typeText: String?
    public var thumbnailUrl: String?
    /// `OLAK5uy_…` — плейлист альбома.
    public var playlistId: String?
    public var explicit: Bool

    public var id: String { browseId }

    public init(
        browseId: String, title: String, artists: [ArtistRef] = [], artistsText: String? = nil, year: String? = nil,
        typeText: String? = nil, thumbnailUrl: String? = nil, playlistId: String? = nil, explicit: Bool = false
    ) {
        self.browseId = browseId
        self.title = title
        self.artists = artists
        self.artistsText = artistsText
        self.year = year
        self.typeText = typeText
        self.thumbnailUrl = thumbnailUrl
        self.playlistId = playlistId
        self.explicit = explicit
    }

    /// «Альбом · Исполнитель · 2024».
    public var subtitle: String {
        [typeText, artistsText, year].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// Исполнитель YouTube Music или канал YouTube (`UC…`).
public struct ArtistItem: Hashable, Codable, Sendable, Identifiable {
    public var browseId: String
    public var name: String
    public var subtitle: String?
    public var thumbnailUrl: String?
    /// Канал обычного YouTube без музыкального профиля.
    public var isChannel: Bool

    public var id: String { browseId }

    public init(browseId: String, name: String, subtitle: String? = nil, thumbnailUrl: String? = nil, isChannel: Bool = false) {
        self.browseId = browseId
        self.name = name
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.isChannel = isChannel
    }
}

/// Плейлист YouTube; `playlistId` без префикса `VL`.
public struct PlaylistItem: Hashable, Codable, Sendable, Identifiable {
    public var playlistId: String
    public var title: String
    public var subtitle: String?
    public var thumbnailUrl: String?

    public var id: String { playlistId }
    public var browseId: String { "VL" + playlistId }

    /// Микс — бесконечная очередь «Далее», а не плейлист: `RD…`, кроме редакционных `RDCLAK…`.
    public var isMix: Bool { playlistId.hasPrefix("RD") && !playlistId.hasPrefix("RDCLAK") }

    public init(playlistId: String, title: String, subtitle: String? = nil, thumbnailUrl: String? = nil) {
        self.playlistId = playlistId
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
    }
}

/// Плитка «Настроения и жанры».
public struct MoodItem: Hashable, Codable, Sendable, Identifiable {
    public var title: String
    public var browseId: String
    public var params: String?
    /// Цвет полоски плитки, ARGB.
    public var color: UInt32?

    public var id: String { browseId + (params ?? "") }

    public init(title: String, browseId: String, params: String? = nil, color: UInt32? = nil) {
        self.title = title
        self.browseId = browseId
        self.params = params
        self.color = color
    }
}

/// Элемент выдачи, полки или страницы YouTube Music и YouTube.
public enum MusicItem: Hashable, Codable, Sendable, Identifiable {
    case track(Track)
    case album(AlbumItem)
    case artist(ArtistItem)
    case playlist(PlaylistItem)
    case mood(MoodItem)

    public var id: String {
        switch self {
        case .track(let track): "t:" + track.videoId
        case .album(let album): "a:" + album.browseId
        case .artist(let artist): "r:" + artist.browseId
        case .playlist(let playlist): "p:" + playlist.playlistId
        case .mood(let mood): "m:" + mood.id
        }
    }

    public var track: Track? {
        if case .track(let track) = self { return track }
        return nil
    }
}

/// Полка страницы: заголовок, элементы и переход «Все ›».
public struct Shelf: Hashable, Codable, Sendable, Identifiable {
    public var title: String?
    public var items: [MusicItem]
    public var moreBrowseId: String?
    public var moreParams: String?

    public var id: String { (title ?? "") + "|" + (items.first?.id ?? "") }

    public init(title: String?, items: [MusicItem], moreBrowseId: String? = nil, moreParams: String? = nil) {
        self.title = title
        self.items = items
        self.moreBrowseId = moreBrowseId
        self.moreParams = moreParams
    }

    public var tracks: [Track] { items.compactMap(\.track) }
}

/// Выдача YouTube Music без фильтра: лучший результат и смешанный список (секция «Всё», REWRITE §4.8.5).
public struct SearchSummary: Hashable, Sendable {
    public var topResult: MusicItem?
    public var items: [MusicItem]

    public init(topResult: MusicItem?, items: [MusicItem]) {
        self.topResult = topResult
        self.items = items
    }
}

/// Страница выдачи с продолжением.
public struct ItemsPage: Hashable, Sendable {
    public var items: [MusicItem]
    public var continuation: String?

    public init(items: [MusicItem], continuation: String?) {
        self.items = items
        self.continuation = continuation
    }
}

/// Очередь «Далее» (радио или плейлист), вкладки текста и похожих.
public struct NextPage: Hashable, Sendable {
    public var tracks: [Track]
    public var continuation: String?
    public var playlistId: String?
    public var lyricsBrowseId: String?
    public var relatedBrowseId: String?

    public init(tracks: [Track], continuation: String? = nil, playlistId: String? = nil,
                lyricsBrowseId: String? = nil, relatedBrowseId: String? = nil) {
        self.tracks = tracks
        self.continuation = continuation
        self.playlistId = playlistId
        self.lyricsBrowseId = lyricsBrowseId
        self.relatedBrowseId = relatedBrowseId
    }
}

/// Убирает повторы по ключу элемента, порядок сохраняется.
public func distinctItems(_ items: [MusicItem]) -> [MusicItem] {
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }
}

/// Страница альбома: шапка, треки, полки внизу («Другие версии»), описание.
public struct AlbumDetails: Hashable, Sendable {
    public var album: AlbumItem
    public var description: String?
    /// «11 треков · 45 мин» — как пришло от YouTube.
    public var countText: String?
    public var tracks: [Track]
    public var shelves: [Shelf]

    public init(album: AlbumItem, description: String?, countText: String?, tracks: [Track], shelves: [Shelf]) {
        self.album = album
        self.description = description
        self.countText = countText
        self.tracks = tracks
        self.shelves = shelves
    }
}

/// Страница исполнителя YouTube Music или, если музыкального профиля нет, канала YouTube (REWRITE §4.8.5).
public struct ArtistDetails: Hashable, Sendable {
    public var browseId: String
    public var name: String
    public var description: String?
    public var thumbnailUrl: String?
    public var subscribersText: String?
    public var isChannel: Bool
    public var shelves: [Shelf]
    /// Плейлист «Все треки» исполнителя, если YouTube его дал.
    public var songsPlaylistId: String?
    /// Радио исполнителя (`RDEM…`), если дал.
    public var radioPlaylistId: String?
    /// Продолжение видео канала.
    public var continuation: String?

    public init(browseId: String, name: String, description: String? = nil, thumbnailUrl: String? = nil,
                subscribersText: String? = nil, isChannel: Bool = false, shelves: [Shelf] = [],
                songsPlaylistId: String? = nil, radioPlaylistId: String? = nil, continuation: String? = nil) {
        self.browseId = browseId
        self.name = name
        self.description = description
        self.thumbnailUrl = thumbnailUrl
        self.subscribersText = subscribersText
        self.isChannel = isChannel
        self.shelves = shelves
        self.songsPlaylistId = songsPlaylistId
        self.radioPlaylistId = radioPlaylistId
        self.continuation = continuation
    }
}

/// Плейлист YouTube: шапка, первая страница треков и продолжение.
public struct PlaylistDetails: Hashable, Sendable {
    public var playlist: PlaylistItem
    public var description: String?
    public var authorText: String?
    /// «2 067 треков · Больше 187 ч.» — как пришло от YouTube.
    public var countText: String?
    public var tracks: [Track]
    public var continuation: String?

    public init(playlist: PlaylistItem, description: String?, authorText: String?, countText: String?,
                tracks: [Track], continuation: String?) {
        self.playlist = playlist
        self.description = description
        self.authorText = authorText
        self.countText = countText
        self.tracks = tracks
        self.continuation = continuation
    }
}
