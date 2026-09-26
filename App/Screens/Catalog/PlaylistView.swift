import SwiftUI
import MelogoldCore
import MelogoldInnerTube
import MelogoldPlayback

/// Плейлист YouTube, он же «Весь список» чарта (REWRITE §3.8.2): шапка, «Слушать · Перемешать», продолжения при
/// прокрутке. «Слушать» и «Перемешать» до полной загрузки ставят в очередь полученное и дозагружают остальное
/// в фоне — пока очередь та же. «Сохранить» со связью с YouTube — со срезом 4.
struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistId: String
    @State private var page = PlaylistPageModel()

    var body: some View {
        Group {
            if let details = page.details {
                content(details)
            } else {
                PageStateView(state: page.state) { Task { await page.load(playlistId, catalog: model.services.catalog, force: true) } }
            }
        }
        .task { await page.load(playlistId, catalog: model.services.catalog) }
    }

    private func content(_ details: PlaylistDetails) -> some View {
        let tracks = page.tracks
        return DetailPage(title: details.playlist.title) {
            CollectionHeader(artworkURL: details.playlist.thumbnailUrl, title: details.playlist.title) {
                VStack(spacing: 4) {
                    if let author = details.authorText {
                        Text(author).font(.title3)
                    }
                    if let count = details.countText {
                        Text(count.replacingOccurrences(of: " • ", with: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if page.continuation != nil {
                        Text("playlist.received \(tracks.count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } actions: {
                PlayButton { page.playAll(model: model, shuffled: false) }
                ShuffleButton { page.playAll(model: model, shuffled: true) }
            }
        } rows: {
            if tracks.isEmpty {
                ContentUnavailableView { Label("playlist.empty", systemImage: "music.note.list") }
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackListRow(track: track, target: .list(tracks, index))
                    .tag(RowID.make("t", track.videoId))
                    .onAppear { if index >= tracks.count - 10 { page.loadMore(catalog: model.services.catalog) } }
            }
            if page.loadingMore {
                ProgressRow()
            }
            if let description = details.description, !description.isEmpty {
                AboutRow(title: "playlist.about", text: description)
                    .listRowSeparator(.hidden)
            }
        } target: { id in
            guard let (_, key) = RowID.split(id), let index = page.tracks.firstIndex(where: { $0.videoId == key }) else { return nil }
            return .list(page.tracks, index)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Section {
                        Button { model.playNext(tracks) } label: {
                            Label("menu.playNext", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { model.enqueue(tracks) } label: {
                            Label("menu.addToQueue", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    }
                    Button { model.playMix("RDAMPL" + playlistId) } label: {
                        Label("playlist.radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    ShareLink(item: ShareLinks.playlist(playlistId)) {
                        Label("menu.share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
            }
        }
    }
}

/// Страницы плейлиста: первая, продолжения при прокрутке и фоновая дозагрузка в очередь.
@MainActor
@Observable
final class PlaylistPageModel {
    private(set) var details: PlaylistDetails?
    private(set) var tracks: [Track] = []
    private(set) var continuation: String?
    private(set) var state: Loadable<Void> = .idle
    private(set) var loadingMore = false
    @ObservationIgnored private var background: Task<Void, Never>?

    func load(_ playlistId: String, catalog: YouTubeMusic, force: Bool = false) async {
        if details != nil, !force { return }
        state = .loading
        do {
            let first = try await catalog.playlist(playlistId)
            details = first
            tracks = first.tracks
            continuation = first.continuation
            state = .loaded(())
        } catch {
            Log.warning("catalog", "Плейлист не загрузился: \(error)")
            state = .failed(.of(error))
        }
    }

    /// Следующая страница при прокрутке к концу.
    func loadMore(catalog: YouTubeMusic) {
        guard !loadingMore, let token = continuation else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let next = try? await catalog.playlistContinuation(token) else { return }
            add(next, token: token)
        }
    }

    private func add(_ next: ItemsPage, token: String) {
        let known = Set(tracks.map(\.videoId))
        tracks += next.items.compactMap(\.track).filter { !known.contains($0.videoId) }
        continuation = next.continuation == token || next.items.isEmpty ? nil : next.continuation
    }

    /// «Слушать» / «Перемешать»: сразу полученное, остальное — в конец той же очереди по мере загрузки.
    func playAll(model: AppModel, shuffled: Bool) {
        let player = model.services.player
        let previous = player.queueId
        model.playAll(tracks, shuffled: shuffled)
        // Очередь не сменилась (нет сети) — дозагружать некуда.
        guard continuation != nil, player.queueId != previous else { return }
        let queueId = player.queueId
        let catalog = model.services.catalog
        background?.cancel()
        background = Task {
            while let token = continuation, !Task.isCancelled {
                guard let next = try? await catalog.playlistContinuation(token) else { return }
                let before = Set(tracks.map(\.videoId))
                add(next, token: token)
                let fresh = tracks.filter { !before.contains($0.videoId) && !$0.unavailable }
                if !player.append(shuffled ? fresh.shuffled() : fresh, toQueue: queueId) { return }
            }
        }
    }
}
