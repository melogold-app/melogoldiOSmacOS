import SwiftUI
import MelogoldCore
import MelogoldInnerTube
import MelogoldPlayback

/// Плашка над мини-плеером (REWRITE §2.3 «Снекбары»): одна на окно, новая заменяет старую.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var actionTitle: LocalizedStringResource?
    var action: (() -> Void)?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Что делает строка списка по нажатию (Mac — двойным щелчком или Return).
enum RowTarget {
    /// Трек из списка: очередь — весь список с этого трека (REWRITE §2.3).
    case list([Track], Int)
    /// Трек из выдачи или карусели: трек и радио по нему.
    case single(Track)
    /// Альбом, исполнитель, плейлист, настроение.
    case open(Route)
    /// Микс `RD…`: очередь «Далее» этого микса.
    case mix(PlaylistItem)
}

extension AppModel {
    func activate(_ target: RowTarget) {
        switch target {
        case .list(let tracks, let index): play(tracks, startAt: index)
        case .single(let track): play(single: track)
        case .open(let route): open(route)
        case .mix(let playlist): playMix(playlist.playlistId)
        }
    }

    /// Детальный экран — в стеке текущего раздела (REWRITE §2.3).
    func open(_ route: Route) {
        open(route, in: section)
    }

    func activate(_ item: MusicItem) {
        switch item {
        case .track(let track): activate(.single(track))
        case .playlist(let playlist) where playlist.isMix: activate(.mix(playlist))
        default: if let route = Route.of(item) { open(route) }
        }
    }

    // MARK: - Очередь

    /// «Играть следующим» — сразу после текущего; «Играет следующим: …».
    func playNext(_ tracks: [Track]) {
        guard let first = tracks.first else { return }
        services.player.playNext(tracks)
        toast = Toast(text: String(localized: "queue.playingNext \(tracks.count == 1 ? first.title : String(localized: "queue.tracks \(tracks.count)"))"))
    }

    /// «В конец очереди» — перед блоком автовоспроизведения; «Добавлено в конец очереди: …» (GLOSSARY §5 п. 7).
    func enqueue(_ tracks: [Track]) {
        guard let first = tracks.first else { return }
        services.player.enqueue(tracks)
        toast = Toast(text: String(localized: "queue.added \(tracks.count == 1 ? first.title : String(localized: "queue.tracks \(tracks.count)"))"))
    }

    /// «Включить радио» — трек и похожие.
    func startRadio(_ track: Track) {
        play(single: track)
    }

    /// Микс или радио плейлиста: первая страница «Далее» — очередь с автовоспроизведением.
    func playMix(_ playlistId: String) {
        Task {
            do {
                let page = try await services.catalog.next(videoId: nil, playlistId: playlistId)
                guard let first = page.tracks.first else { return }
                services.player.playRadio(playlistId: playlistId, seed: first)
            } catch {
                notice = Notice(title: "error.offline", message: nil)
            }
        }
    }

    /// Список целиком: «Слушать» и «Перемешать». Перемешанный список начинается со случайного трека.
    func playAll(_ tracks: [Track], shuffled: Bool) {
        let playable = tracks.filter { !$0.unavailable }
        guard !playable.isEmpty else { return }
        play(shuffled ? playable.shuffled() : playable, startAt: 0)
    }

    func openAlbum(of track: Track) {
        if let albumId = track.albumId { open(.album(albumId)) }
    }

    func openArtist(of track: Track) {
        if let artistId = track.primaryArtistId { open(.artist(artistId)) }
    }

    // MARK: - Ссылки (REWRITE §2.3, §4.9)

    /// Вставленная, перетащенная или открытая ссылка YouTube или текст: цель ссылки, иначе — поиск.
    func openLink(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("melogold://"), let url = URL(string: trimmed) {
            handle(url: url)
            return
        }
        let target = YouTubeLinkParser.parse(trimmed)
        Log.info("links", "Ссылка: \(target.logName)")
        switch target {
        case .search(let query):
            section = .search
            routes[.search] = []
            searchQuery = query
            search.submit(query)
        case .video(let videoId, let playlistId, _, let startMs):
            Task { await playVideoLink(videoId: videoId, playlistId: playlistId, startMs: startMs) }
        case .playlist(let playlistId):
            openPlaylistLink(playlistId)
        case .album(let browseId):
            open(.album(browseId))
        case .channel(let channelId):
            open(.artist(channelId))
        case .handle(let name):
            resolveChannel("https://www.youtube.com/@\(name)")
        case .legacyChannel(let url):
            resolveChannel(url)
        case .external:
            toast = Toast(text: String(localized: "link.importLater"))
        case .unsupported(.empty):
            break
        case .unsupported:
            toast = Toast(text: String(localized: "link.unsupported"))
        }
    }

    /// Видео по ссылке: с `list=` (не микс) — очередь плейлиста с этого видео, с `RD…` — радио, иначе одиночный
    /// трек и радио; `t=` — стартовая позиция. Открывается только мини-плеер.
    private func playVideoLink(videoId: String, playlistId: String?, startMs: Int64?) async {
        let catalog = services.catalog
        if let list = playlistId, !(list.hasPrefix("RD") && !list.hasPrefix("RDCLAK")) {
            if let tracks = try? await catalog.playlistTracks(list, max: 1000),
               let index = tracks.firstIndex(where: { $0.videoId == videoId }) {
                play(tracks, startAt: index)
                return
            }
        }
        let next = try? await catalog.next(videoId: videoId, playlistId: playlistId)
        let track = next?.tracks.first { $0.videoId == videoId } ?? Track(videoId: videoId, title: videoId)
        if let list = playlistId, list.hasPrefix("RD"), !list.hasPrefix("RDCLAK") {
            services.player.playRadio(playlistId: list, seed: track)
            return
        }
        guard services.network.isOnline || cachedIds.contains(videoId) else {
            notice = Notice(title: "notice.offline", message: nil)
            return
        }
        services.player.playSingle(track, from: Double(startMs ?? 0) / 1000)
    }

    /// Плейлист по ссылке; `OLAK5uy_…` — плейлист альбома: открывается альбом по первому треку.
    private func openPlaylistLink(_ playlistId: String) {
        if playlistId.hasPrefix("RD"), !playlistId.hasPrefix("RDCLAK") {
            playMix(playlistId)
            return
        }
        guard playlistId.hasPrefix("OLAK5uy_") else {
            open(.playlist(playlistId))
            return
        }
        Task {
            let page = try? await services.catalog.playlist(playlistId)
            if let albumId = page?.tracks.first(where: { $0.albumId != nil })?.albumId {
                open(.album(albumId))
            } else {
                open(.playlist(playlistId))
            }
        }
    }

    private func resolveChannel(_ url: String) {
        Task {
            do {
                if let browseId = try await services.catalog.resolveURL(url) {
                    open(.artist(browseId))
                } else {
                    toast = Toast(text: String(localized: "link.unsupported"))
                }
            } catch {
                notice = Notice(title: "error.offline", message: nil)
            }
        }
    }
}

extension LinkTarget {
    /// Строка подсказки при вводе: «Открыть ссылку: видео YouTube» и т. п. (GLOSSARY §4.1); `nil` — не ссылка.
    var openTitle: LocalizedStringResource? {
        switch self {
        case .video: "link.open.video"
        case .playlist: "link.open.playlist"
        case .album: "link.open.album"
        case .channel, .handle, .legacyChannel: "link.open.channel"
        case .external, .unsupported(.invalidVideoId), .unsupported(.privatePlaylist), .unsupported(.clip), .unsupported(.post):
            "link.open.other"
        case .search, .unsupported: nil
        }
    }

    /// Тип цели для журнала — без самой ссылки.
    var logName: String {
        switch self {
        case .video: "video"
        case .playlist: "playlist"
        case .album: "album"
        case .channel: "channel"
        case .handle: "handle"
        case .legacyChannel: "legacyChannel"
        case .search: "search"
        case .external(let service, _): "external \(service)"
        case .unsupported(let reason): "unsupported \(reason.rawValue)"
        }
    }
}

/// Ссылки «Поделиться»: песни и альбомы — на YouTube Music, видео и каналы — на YouTube.
enum ShareLinks {
    static func track(_ track: Track) -> URL {
        let host = track.isVideo && track.videoType != VideoType.video ? "www.youtube.com" : "music.youtube.com"
        return URL(string: "https://\(host)/watch?v=\(track.videoId)")!
    }

    static func album(_ browseId: String) -> URL {
        URL(string: "https://music.youtube.com/browse/\(browseId)")!
    }

    static func playlist(_ playlistId: String) -> URL {
        URL(string: "https://music.youtube.com/playlist?list=\(playlistId)")!
    }

    static func artist(_ browseId: String, isChannel: Bool) -> URL {
        URL(string: isChannel ? "https://www.youtube.com/channel/\(browseId)" : "https://music.youtube.com/channel/\(browseId)")!
    }
}
