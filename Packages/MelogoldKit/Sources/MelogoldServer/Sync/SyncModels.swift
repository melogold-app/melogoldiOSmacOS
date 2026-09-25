import Foundation

// Синхронизация (API §4.7, §4.8) и тексты (§4.10). Op — плоская схема с полем `kind`: полиморфизма в API нет (§1.3).
// Ответы читаются терпимо: отсутствующий массив — пустой, неизвестные поля пропускаются.

public struct ArtistRefDto: Codable, Sendable, Equatable {
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

/// Трек в ответе сервера: любое видео YouTube (API §4.1).
public struct TrackDto: Decodable, Sendable, Equatable {
    public let videoId: String
    public let title: String
    public let artistsText: String?
    public let artists: [ArtistRefDto]
    public let albumId: String?
    public let albumTitle: String?
    public let durationMs: Int64?
    public let durationText: String?
    public let thumbnailUrl: String?
    public let explicit: Bool
    public let videoType: String?
    /// `true` — метаданных нет, `title` равен `videoId`.
    public let metadataStub: Bool

    enum CodingKeys: String, CodingKey {
        case videoId, title, artistsText, artists, albumId, albumTitle, durationMs, durationText, thumbnailUrl, explicit, videoType, metadataStub
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? videoId
        artistsText = try c.decodeIfPresent(String.self, forKey: .artistsText)
        artists = try c.decodeIfPresent([ArtistRefDto].self, forKey: .artists) ?? []
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        albumTitle = try c.decodeIfPresent(String.self, forKey: .albumTitle)
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs)
        durationText = try c.decodeIfPresent(String.self, forKey: .durationText)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit) ?? false
        videoType = try c.decodeIfPresent(String.self, forKey: .videoType)
        metadataStub = try c.decodeIfPresent(Bool.self, forKey: .metadataStub) ?? false
    }
}

/// Метаданные трека в op: другие устройства смогут его показать. Разбор на сервере мягкий (DESIGN §3.9).
public struct TrackInput: Encodable, Sendable, Equatable {
    public var videoId: String
    public var title: String?
    public var artistsText: String?
    public var artists: [ArtistRefDto]?
    public var albumId: String?
    public var albumTitle: String?
    public var durationMs: Int64?
    public var durationText: String?
    public var thumbnailUrl: String?
    public var explicit: Bool?
    public var videoType: String?

    public init(videoId: String) {
        self.videoId = videoId
    }
}

public struct BaselineEntry: Codable, Sendable, Equatable {
    public let videoId: String
    public let totalMs: Int64
}

/// Одна op `POST /sync`. Поля без значения не пишутся.
public struct SyncOp: Encodable, Sendable, Equatable {
    public var opId: String
    public var kind: String
    public var at: String
    public var base: String?
    public var videoId: String?
    public var videoIds: [String]?
    public var after: String?
    public var before: String?
    public var liked: Bool?
    public var likedAt: String?
    public var type: String?
    public var browseId: String?
    public var bookmarked: Bool?
    public var bookmarkedAt: String?
    public var title: String?
    public var subtitle: String?
    public var thumbnailUrl: String?
    public var year: String?
    public var playlistId: String?
    public var name: String?
    public var playedAt: String?
    public var playTimeMs: Int64?
    public var history: Bool?
    public var playtime: Bool?
    public var mode: String?
    public var entries: [BaselineEntry]?
    public var eventsBefore: String?
    public var resetTotal: Bool?
    public var tracks: [TrackInput]?

    public init(opId: String, kind: String, at: String, base: String?) {
        self.opId = opId
        self.kind = kind
        self.at = at
        self.base = base
    }
}

struct SyncRequest: Encodable, Sendable {
    let cursor: String
    let limit: Int?
    let streams: [String]
    let ops: [SyncOp]
}

public struct OpResult: Decodable, Sendable, Equatable {
    public let opId: String
    /// `applied`, `superseded`, `redirected`, `rejected` или `deferred`.
    public let status: String
    public let code: String?
    public let playlistId: String?
    public let retryAfterSeconds: Int?
    public let replayed: Bool

    enum CodingKeys: String, CodingKey { case opId, status, code, playlistId, retryAfterSeconds, replayed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opId = try c.decode(String.self, forKey: .opId)
        status = try c.decode(String.self, forKey: .status)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        playlistId = try c.decodeIfPresent(String.self, forKey: .playlistId)
        retryAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

public struct PlaylistRow: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let browseId: String?
    public let thumbnailUrl: String?
    public let createdAt: String
    public let deleted: Bool
}

public struct PlaylistItemRow: Decodable, Sendable, Equatable {
    public let playlistId: String
    public let videoId: String
    public let present: Bool
    public let sortKey: String
    public let addedAt: String
}

public struct LikeRow: Decodable, Sendable, Equatable {
    public let videoId: String
    public let liked: Bool
    public let likedAt: String?
}

public struct BookmarkRow: Decodable, Sendable, Equatable {
    public let type: String
    public let browseId: String
    public let bookmarked: Bool
    public let bookmarkedAt: String?
    public let title: String?
    public let subtitle: String?
    public let thumbnailUrl: String?
    public let year: String?
}

public struct PlayRow: Decodable, Sendable, Equatable {
    public let eventId: String
    public let videoId: String
    public let playedAt: String
    public let playTimeMs: Int64
    public let deviceId: String?
}

public struct PlayStatRow: Decodable, Sendable, Equatable {
    public let videoId: String
    public let totalPlayTimeMs: Int64
    public let lastPlayedAt: String?
}

public struct PlayForgetRow: Decodable, Sendable, Equatable {
    /// `videoId` или `*` — вся история.
    public let videoId: String
    public let eventsBefore: String
    public let totalBefore: String?
}

public struct SyncResponse: Decodable, Sendable, Equatable {
    public let results: [OpResult]
    public let cursor: String
    public let hasMore: Bool
    public let serverTime: String
    public let tracks: [TrackDto]
    public let playlists: [PlaylistRow]
    public let items: [PlaylistItemRow]
    public let likes: [LikeRow]
    public let bookmarks: [BookmarkRow]
    public let plays: [PlayRow]
    public let playStats: [PlayStatRow]
    public let playForgets: [PlayForgetRow]

    enum CodingKeys: String, CodingKey {
        case results, cursor, hasMore, serverTime, tracks, playlists, items, likes, bookmarks, plays, playStats, playForgets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([OpResult].self, forKey: .results) ?? []
        cursor = try c.decode(String.self, forKey: .cursor)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime) ?? ""
        tracks = try c.decodeIfPresent([TrackDto].self, forKey: .tracks) ?? []
        playlists = try c.decodeIfPresent([PlaylistRow].self, forKey: .playlists) ?? []
        items = try c.decodeIfPresent([PlaylistItemRow].self, forKey: .items) ?? []
        likes = try c.decodeIfPresent([LikeRow].self, forKey: .likes) ?? []
        bookmarks = try c.decodeIfPresent([BookmarkRow].self, forKey: .bookmarks) ?? []
        plays = try c.decodeIfPresent([PlayRow].self, forKey: .plays) ?? []
        playStats = try c.decodeIfPresent([PlayStatRow].self, forKey: .playStats) ?? []
        playForgets = try c.decodeIfPresent([PlayForgetRow].self, forKey: .playForgets) ?? []
    }
}

struct MergePlanRequest: Encodable, Sendable {
    let playlists: [MergePlanInput]
}

struct MergePlanInput: Encodable, Sendable {
    let localKey: String
    let syncId: String?
    let name: String
    let browseId: String?
}

public struct MergePlanResponse: Decodable, Sendable, Equatable {
    public let plan: [MergePlanEntry]
}

public struct MergePlanEntry: Decodable, Sendable, Equatable {
    public let localKey: String
    /// `merge`, `deleted` или `create`.
    public let action: String
    public let playlistId: String
    public let serverName: String?
}

// MARK: - Тексты песен (API §4.10)

/// Текст трека: обе стороны со своими источниками (`user|file|youtube_music|lrclib|kugou`).
public struct LyricsText: Codable, Sendable, Equatable {
    public var plain: String?
    public var plainSource: String?
    public var synced: String?
    /// `lrc` или `ttml`; есть вместе с `synced`.
    public var syncedFormat: String?
    public var syncedSource: String?
    /// Где в треке начинается синхронный текст.
    public var startTimeMs: Int64?
    /// BCP 47.
    public var language: String?
}

/// Своя версия для `PUT`: нужен `plain` или `synced`; `syncedFormat` — вместе с `synced`. Пустые поля не пишутся.
typealias LyricsPut = LyricsText

public struct MyLyrics: Decodable, Sendable, Equatable {
    public let id: String
    public let videoId: String
    /// Счётчик изменений пользователя: растёт с каждым `PUT` и `DELETE`.
    public let rev: Int64
    /// Надгробие `DELETE`; `text` тогда `nil`.
    public let deleted: Bool
    public let text: LyricsText?
    public let updatedAt: String
}

/// Общая версия другого пользователя; автор не раскрывается.
public struct SharedLyrics: Decodable, Sendable, Equatable {
    public let id: String
    public let videoId: String
    public let text: LyricsText
    public let updatedAt: String
}

public struct LyricsResponse: Decodable, Sendable, Equatable {
    public let mine: MyLyrics?
    public let shared: SharedLyrics?
    public let serverTime: String
}

struct LyricsChangesRequest: Encodable, Sendable {
    let after: Int64
    let limit: Int?
}

public struct MyLyricsPage: Decodable, Sendable, Equatable {
    /// `rev > after`, по возрастанию `rev`.
    public let items: [MyLyrics]
    /// `after` для следующего запроса.
    public let rev: Int64
    public let more: Bool
}
