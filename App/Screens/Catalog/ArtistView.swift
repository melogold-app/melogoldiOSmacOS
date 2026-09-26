import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Исполнитель или канал (REWRITE §3.7): что показывать, решает `YouTubeMusic.artist` — страница исполнителя, если у
/// YouTube Music есть музыкальные секции, иначе канал YouTube. «Подписаться» и «В вашей библиотеке» — со срезом 4.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let browseId: String
    @State private var page = ArtistPageModel()

    var body: some View {
        Group {
            if let details = page.details {
                if details.isChannel {
                    channel(details)
                } else {
                    artist(details)
                }
            } else {
                PageStateView(state: page.state) { Task { await page.load(browseId, catalog: model.services.catalog, force: true) } }
            }
        }
        .task { await page.load(browseId, catalog: model.services.catalog) }
    }

    // MARK: - Исполнитель: одна прокрутка (REWRITE §3.7.1)

    private func artist(_ details: ArtistDetails) -> some View {
        DetailPage(title: details.name, twoColumns: false) {
            CollectionHeader(artworkURL: details.thumbnailUrl, circle: true, title: details.name) {
                if let subscribers = details.subscribersText {
                    Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                }
            } actions: {
                ShuffleButton { page.shuffleSongs(model: model) }
                if let seed = page.popular.first {
                    Button {
                        radio(details, seed: seed)
                    } label: {
                        Label("artist.radio", systemImage: "dot.radiowaves.left.and.right")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } rows: {
            ForEach(Array(details.shelves.enumerated()), id: \.offset) { index, shelf in
                if ArtistPageModel.isSongs(shelf) {
                    ShelfHeader(title: Text(verbatim: shelf.title ?? ""), more: songsRoute(details, shelf))
                        .listRowSeparator(.hidden)
                        .padding(.top, 8)
                    ForEach(Array(shelf.tracks.enumerated()), id: \.element.id) { number, track in
                        TrackListRow(track: track, subtitle: track.albumTitle ?? "", number: number + 1,
                                     target: .list(shelf.tracks, number))
                            .tag(RowID.make("s\(index)", track.videoId))
                    }
                } else {
                    ShelfRows(shelf: shelf)
                }
            }
            if let description = details.description, !description.isEmpty {
                AboutRow(title: "artist.about", text: description)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
            }
        } target: { id in
            guard let (section, key) = RowID.split(id), section.hasPrefix("s"), let index = Int(section.dropFirst()),
                  details.shelves.indices.contains(index) else { return nil }
            let tracks = details.shelves[index].tracks
            return tracks.firstIndex { $0.videoId == key }.map { .list(tracks, $0) }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    if let seed = page.popular.first {
                        Button { radio(details, seed: seed) } label: {
                            Label("artist.radio", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    ShareLink(item: ShareLinks.artist(details.browseId, isChannel: false)) {
                        Label("menu.share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
            }
        }
    }

    /// «Все ›» у «Популярного» — плейлист песен исполнителя, если YouTube Music его дал.
    private func songsRoute(_ details: ArtistDetails, _ shelf: Shelf) -> Route? {
        if let playlistId = details.songsPlaylistId { return .playlist(playlistId) }
        return Route.more(shelf)
    }

    private func radio(_ details: ArtistDetails, seed: Track) {
        if let playlistId = details.radioPlaylistId {
            model.services.player.playRadio(playlistId: playlistId, seed: seed)
        } else {
            model.startRadio(seed)
        }
    }

    // MARK: - Канал YouTube (REWRITE §3.7.2)

    private func channel(_ details: ArtistDetails) -> some View {
        DetailPage(title: details.name, twoColumns: false) {
            CollectionHeader(artworkURL: details.thumbnailUrl, circle: true, title: details.name) {
                if let subscribers = details.subscribersText {
                    Text(subscribers).font(.subheadline).foregroundStyle(.secondary)
                }
            } actions: {
                if !page.videos.isEmpty {
                    ShuffleButton(title: "channel.shuffleVideos") { model.playAll(page.videos, shuffled: true) }
                }
            }
        } rows: {
            if page.videos.isEmpty {
                ContentUnavailableView { Label("channel.noVideos", systemImage: "play.rectangle") }
                    .listRowSeparator(.hidden)
            } else {
                ShelfHeader(title: Text("channel.videos"))
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(page.videos.enumerated()), id: \.element.id) { index, video in
                TrackListRow(track: video, wide: true, target: .list(page.videos, index))
                    .tag(RowID.make("v", video.videoId))
                    .onAppear { if index >= page.videos.count - 6 { page.loadMoreVideos(catalog: model.services.catalog) } }
            }
            if page.loadingMore {
                ProgressRow()
            }
        } target: { id in
            guard let (_, key) = RowID.split(id), let index = page.videos.firstIndex(where: { $0.videoId == key }) else { return nil }
            return .list(page.videos, index)
        }
        .toolbar {
            ToolbarItem {
                ShareLink(item: ShareLinks.artist(details.browseId, isChannel: true)) {
                    Label("menu.share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

/// Данные страницы исполнителя или канала; у канала — видео с продолжениями.
@MainActor
@Observable
final class ArtistPageModel {
    private(set) var details: ArtistDetails?
    private(set) var state: Loadable<Void> = .idle
    private(set) var videos: [Track] = []
    private(set) var loadingMore = false
    @ObservationIgnored private var continuation: String?

    /// Полка «Популярное»: треки, не клипы.
    static func isSongs(_ shelf: Shelf) -> Bool {
        !shelf.items.isEmpty && shelf.items.allSatisfy { $0.track.map { !$0.isVideo } ?? false }
    }

    var popular: [Track] {
        details?.shelves.first(where: Self.isSongs)?.tracks ?? []
    }

    func load(_ browseId: String, catalog: YouTubeMusic, force: Bool = false) async {
        if details != nil, !force { return }
        state = .loading
        do {
            let loaded = try await catalog.artist(browseId)
            details = loaded
            if loaded.isChannel {
                videos = loaded.shelves.first?.tracks ?? []
                continuation = loaded.continuation
            }
            state = .loaded(())
        } catch {
            Log.warning("catalog", "Исполнитель не загрузился: \(error)")
            state = .failed(.of(error))
        }
    }

    func loadMoreVideos(catalog: YouTubeMusic) {
        guard !loadingMore, let token = continuation else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let next = try? await catalog.channelContinuation(token) else { return }
            let name = details?.name ?? ""
            let known = Set(videos.map(\.videoId))
            videos += next.items.compactMap(\.track).filter { !known.contains($0.videoId) }.map { video in
                var copy = video
                copy.artists = [ArtistRef(id: details?.browseId, name: name)]
                copy.artistsText = name
                return copy
            }
            continuation = next.continuation == token ? nil : next.continuation
        }
    }

    /// «Перемешать»: песни исполнителя (плейлист «Все треки», первая страница), иначе «Популярное».
    func shuffleSongs(model: AppModel) {
        guard let details else { return }
        guard let playlistId = details.songsPlaylistId else {
            model.playAll(popular, shuffled: true)
            return
        }
        Task {
            let songs = (try? await model.services.catalog.playlist(playlistId).tracks) ?? []
            model.playAll(songs.isEmpty ? popular : songs, shuffled: true)
        }
    }
}
