import Foundation
import MelogoldCore

/// Фильтр выдачи YouTube Music (чипы «Музыки»: Песни · Альбомы · Исполнители · Клипы · Плейлисты).
public enum MusicSearchFilter: String, CaseIterable, Sendable {
    case songs, videos, albums, artists, communityPlaylists, featuredPlaylists

    var params: String {
        switch self {
        case .songs: "EgWKAQIIAWoSEAMQCRAEEAUQChAQEBUQDhAR"
        case .videos: "EgWKAQIQAWoSEAMQCRAEEAUQChAQEBUQDhAR"
        case .albums: "EgWKAQIYAWoSEAMQCRAEEAUQChAQEBUQDhAR"
        case .artists: "EgWKAQIgAWoSEAMQCRAEEAUQChAQEBUQDhAR"
        case .communityPlaylists: "EgeKAQQoAEABahIQAxAJEAQQBRAKEBAQFRAOEBE="
        case .featuredPlaylists: "EgeKAQQoADgBahIQAxAJEAQQBRAKEBAQFRAOEBE="
        }
    }
}

/// Фильтр выдачи обычного YouTube (чипы «YouTube»: Видео · Каналы · Трансляции · Плейлисты, REWRITE §4.8.1).
public enum WebSearchFilter: String, CaseIterable, Sendable {
    case videos, channels, live, playlists

    var params: String {
        switch self {
        case .videos: "EgIQAQ=="
        case .channels: "EgIQAg=="
        case .live: "EgJAAQ=="
        case .playlists: "EgIQAw=="
        }
    }
}

/// Каталог YouTube Music и обычного YouTube: поиск, «Далее», поток. Ошибки — `YouTubeError` с классом для экрана.
/// Страницы каталога (альбом, исполнитель, плейлист, Тренды, Новое) добавляются в срезе 3.
public struct YouTubeMusic: Sendable {
    public let client: InnerTubeClient

    public init(client: InnerTubeClient) {
        self.client = client
    }

    private func music(_ endpoint: String, _ body: [String: any Sendable]) async throws -> JSON {
        try await client.postJSON(.webRemix, endpoint, body: body)
    }

    private func web(_ endpoint: String, _ body: [String: any Sendable]) async throws -> JSON {
        try await client.postJSON(.web, endpoint, body: body)
    }

    // MARK: - Поиск

    /// YTM без фильтра: лучший результат и смешанная выдача (секция «Всё», REWRITE §4.8.5).
    public func searchSummary(_ query: String) async throws -> SearchSummary {
        Self.parseSearchSummary(try await music("search", ["query": query]))
    }

    static func parseSearchSummary(_ response: JSON) -> SearchSummary {
        let sections = response.at("contents", "tabbedSearchResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents")
        var top: MusicItem?
        var items: [MusicItem] = []
        for section in sections.array {
            let card = section["musicCardShelfRenderer"]
            if card.exists {
                if top == nil { top = cardTop(card) }
                items += MusicParsers.items(of: card["contents"])
            } else if section["itemSectionRenderer"].exists {
                items += MusicParsers.items(of: section.at("itemSectionRenderer", "contents"))
            } else if section["musicShelfRenderer"].exists {
                items += MusicParsers.items(of: section.at("musicShelfRenderer", "contents"))
            }
        }
        return SearchSummary(topResult: top, items: distinctItems(items))
    }

    /// Карточка лучшего результата — как строка `musicResponsiveListItemRenderer` из её заголовка и подписи.
    private static func cardTop(_ card: JSON) -> MusicItem? {
        guard let titleRun = card["title"].runs.first else { return nil }
        var synthetic: [String: Any] = [
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": card["title"].value ?? [:]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": card["subtitle"].value ?? [:]]],
            ],
        ]
        if let thumbnail = card["thumbnail"].value { synthetic["thumbnail"] = thumbnail }
        if let navigation = card.at("title", "runs", 0, "navigationEndpoint").value { synthetic["navigationEndpoint"] = navigation }
        if let videoId = titleRun.watchVideoId { synthetic["playlistItemData"] = ["videoId": videoId] }
        return MusicParsers.responsiveItem(JSON(synthetic))
    }

    /// YTM с фильтром; продолжение — `searchContinuation`.
    public func search(_ query: String, filter: MusicSearchFilter) async throws -> ItemsPage {
        Self.parseSearchPage(try await music("search", ["query": query, "params": filter.params]))
    }

    static func parseSearchPage(_ response: JSON) -> ItemsPage {
        let sections = response.at("contents", "tabbedSearchResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents")
        var items: [MusicItem] = []
        var continuation: String?
        for section in sections.array {
            let shelf = section["musicShelfRenderer"].exists ? section["musicShelfRenderer"] : section["itemSectionRenderer"]
            guard shelf.exists else { continue }
            items += MusicParsers.items(of: shelf["contents"])
            if continuation == nil { continuation = MusicParsers.continuation(shelf) }
        }
        return ItemsPage(items: distinctItems(items), continuation: continuation)
    }

    public func searchContinuation(_ token: String) async throws -> ItemsPage {
        Self.parseSearchContinuation(try await music("search", ["continuation": token]))
    }

    static func parseSearchContinuation(_ response: JSON) -> ItemsPage {
        let shelf = response.at("continuationContents", "musicShelfContinuation")
        if shelf.exists {
            return ItemsPage(items: MusicParsers.items(of: shelf["contents"]), continuation: MusicParsers.continuation(shelf))
        }
        let appended = response.first(["onResponseReceivedCommands", 0, "appendContinuationItemsAction", "continuationItems"],
                                      ["onResponseReceivedActions", 0, "appendContinuationItemsAction", "continuationItems"])
        return ItemsPage(items: MusicParsers.items(of: appended), continuation: MusicParsers.continuation(appended))
    }

    /// Подсказки YouTube Music к вводу (до 10).
    public func suggestions(_ input: String) async throws -> [String] {
        Self.parseSuggestions(try await music("music/get_search_suggestions", ["input": input]))
    }

    static func parseSuggestions(_ response: JSON) -> [String] {
        var seen = Set<String>()
        return response.findAll("searchSuggestionRenderer")
            .compactMap { $0["suggestion"].text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(10)
            .map { $0 }
    }

    /// Обычный YouTube (клиент WEB): видео, каналы, плейлисты, трансляции.
    public func searchWeb(_ query: String, filter: WebSearchFilter) async throws -> ItemsPage {
        let response = try await web("search", ["query": query, "params": filter.params])
        return WebParsers.searchPage(response.at("contents", "twoColumnSearchResultsRenderer", "primaryContents", "sectionListRenderer", "contents"))
    }

    public func searchWebContinuation(_ token: String) async throws -> ItemsPage {
        let response = try await web("search", ["continuation": token])
        return WebParsers.searchPage(response.at("onResponseReceivedCommands", 0, "appendContinuationItemsAction", "continuationItems"))
    }

    // MARK: - «Далее»

    /// Очередь «Далее»: радио по треку (`RDAMVM<videoId>`, REWRITE §4.10.5) или плейлист с этого трека.
    public func next(videoId: String, playlistId: String? = nil, params: String? = nil) async throws -> NextPage {
        var body: [String: any Sendable] = [
            "videoId": videoId, "isAudioOnly": true, "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        if let playlistId { body["playlistId"] = playlistId }
        if let params { body["params"] = params }
        return Self.parseNext(try await music("next", body))
    }

    static func parseNext(_ response: JSON) -> NextPage {
        let tabs = response.at("contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs")
        let panel = tabs.at(0, "tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer")
        var lyrics: String?
        var related: String?
        for tab in tabs.array {
            let browse = tab.at("tabRenderer", "endpoint", "browseEndpoint")
            let pageType = browse.str("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType")
            if pageType == "MUSIC_PAGE_TYPE_TRACK_LYRICS", !tab.flag("tabRenderer", "unselectable") { lyrics = browse.str("browseId") }
            if pageType == "MUSIC_PAGE_TYPE_TRACK_RELATED" { related = browse.str("browseId") }
        }
        return NextPage(
            tracks: panelTracks(panel), continuation: MusicParsers.continuation(panel),
            playlistId: panel.str("playlistId"), lyricsBrowseId: lyrics, relatedBrowseId: related
        )
    }

    public func nextContinuation(_ token: String, playlistId: String?) async throws -> NextPage {
        var body: [String: any Sendable] = ["continuation": token, "isAudioOnly": true, "enablePersistentPlaylistPanel": true]
        if let playlistId { body["playlistId"] = playlistId }
        let response = try await music("next", body)
        let panel = response.at("continuationContents", "playlistPanelContinuation")
        return NextPage(tracks: Self.panelTracks(panel), continuation: MusicParsers.continuation(panel), playlistId: playlistId)
    }

    private static func panelTracks(_ panel: JSON) -> [Track] {
        panel["contents"].array.compactMap { item in
            let renderer = item["playlistPanelVideoRenderer"].exists
                ? item["playlistPanelVideoRenderer"]
                : item.at("playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer")
            return MusicParsers.panelVideo(renderer)
        }
    }

    // MARK: - Поток

    /// `/youtubei/v1/player` клиентом `profile`. Клиенты потока отдают прямые ссылки без расшифровки подписи.
    public func player(videoId: String, profile: ClientProfile) async throws -> PlayerResponse {
        let response = try await client.postJSON(profile, "player", body: [
            "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
        ])
        return PlayerResponse.parse(response)
    }
}
