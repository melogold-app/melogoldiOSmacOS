import Foundation
import MelogoldCore
import MelogoldData
import MelogoldInnerTube

/// «Для вас» (REWRITE §3.4, §4.10.5): до 3 затравок (последний лайк, самый частый за 30 дней, последний прослушанный) →
/// «Похожие» по каждой → слияние по кругу без повторов → фильтр (скрытые, «Не интересно», E при «Скрывать E») → 20
/// треков. Из тех же ответов — похожие исполнители, альбомы и плейлисты. Последняя подборка лежит в `Caches` — без
/// сети показывается она с подписью «обновлено …».
@MainActor
@Observable
final class ForYouStore {
    struct Picks: Codable, Equatable {
        var seeds: [Track] = []
        var tracks: [Track] = []
        var artists: [ArtistItem] = []
        var albums: [AlbumItem] = []
        var playlists: [PlaylistItem] = []
        var loadedAt = Date()
    }

    private(set) var picks: Picks?
    private(set) var loading = false
    private(set) var fromCache = false

    @ObservationIgnored private let catalog: YouTubeMusic
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var seedKey = ""

    init(catalog: YouTubeMusic, file: URL?) {
        self.catalog = catalog
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Picks.self, from: data) {
            picks = saved
            fromCache = true
        }
    }

    /// Собрать заново, если затравки поменялись или `force` (жест «Обновить»).
    func load(library: LibraryStore?, hideExplicit: Bool, force: Bool = false) async {
        guard let library, !loading else { return }
        let seeds = library.library.forYouSeeds()
        guard !seeds.isEmpty else {
            picks = nil
            return
        }
        let key = seeds.map(\.videoId).joined(separator: ",")
        if !force, key == seedKey, !fromCache { return }
        loading = true
        defer { loading = false }
        var trackLists: [[Track]] = []
        var artists: [ArtistItem] = []
        var albums: [AlbumItem] = []
        var playlists: [PlaylistItem] = []
        for seed in seeds {
            guard let related = try? await relatedShelves(seed) else { continue }
            trackLists.append(related.flatMap(\.tracks))
            for item in related.flatMap(\.items) {
                switch item {
                case .artist(let artist): artists.append(artist)
                case .album(let album): albums.append(album)
                case .playlist(let playlist) where !playlist.isMix: playlists.append(playlist)
                default: break
                }
            }
        }
        guard !trackLists.isEmpty else { return }
        let blocked = library.hiddenIds.union(library.notInterestedIds)
        let seedIds = Set(seeds.map(\.videoId))
        var seen = Set<String>()
        var merged: [Track] = []
        // Слияние по кругу: первый трек каждой затравки, затем второй и т. д.
        for position in 0..<(trackLists.map(\.count).max() ?? 0) {
            for list in trackLists where position < list.count {
                let track = list[position]
                guard !seedIds.contains(track.videoId), !blocked.contains(track.videoId), !(hideExplicit && track.explicit),
                      !track.unavailable, seen.insert(track.videoId).inserted else { continue }
                merged.append(track)
            }
        }
        var artistIds = Set<String>(), albumIds = Set<String>(), playlistIds = Set<String>()
        let fresh = Picks(
            seeds: seeds, tracks: Array(merged.prefix(20)),
            artists: artists.filter { artistIds.insert($0.browseId).inserted }.prefix(12).map { $0 },
            albums: albums.filter { albumIds.insert($0.browseId).inserted }.prefix(12).map { $0 },
            playlists: playlists.filter { playlistIds.insert($0.playlistId).inserted }.prefix(12).map { $0 },
            loadedAt: Date()
        )
        picks = fresh
        fromCache = false
        seedKey = key
        if let file, let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Убрать трек из подборки сразу («Не интересно»).
    func remove(_ videoId: String) {
        picks?.tracks.removeAll { $0.videoId == videoId }
    }

    private func relatedShelves(_ seed: Track) async throws -> [Shelf] {
        let next = try await catalog.next(videoId: seed.videoId)
        guard let browseId = next.relatedBrowseId else { return [] }
        return try await catalog.related(browseId)
    }
}
