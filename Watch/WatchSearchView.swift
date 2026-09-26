import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Поиск на часах (docs/PROMPT.md §5.6): поле — системный ввод (клавиатура, рукописный ввод, диктовка, клавиатура
/// iPhone), выдача — группы Песни, Видео, Альбомы, Исполнители, Плейлисты. Нажатие по треку играет его с радио и открывает «Сейчас играет».
struct WatchSearchView: View {
    @Environment(WatchModel.self) private var model
    @State private var query = ""
    @State private var songs: [Track] = []
    @State private var videos: [Track] = []
    @State private var collections: [MusicItem] = []
    @State private var state: State = .idle

    enum State { case idle, loading, loaded, failed(YouTubeError.Kind) }

    var body: some View {
        List {
            TextField("search.prompt", text: $query)
                .onSubmit { search() }
                .accessibilityIdentifier("watch.search.field")
            switch state {
            case .idle:
                EmptyView()
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            case .failed(let kind):
                Text(errorText(kind)).font(.footnote).foregroundStyle(.secondary)
                Button("common.retry") { search() }
            case .loaded:
                if songs.isEmpty, videos.isEmpty {
                    Text("search.nothingFound").font(.footnote).foregroundStyle(.secondary)
                }
                if !songs.isEmpty {
                    Section("search.filter.songs") { rows(songs) }
                }
                if !videos.isEmpty {
                    Section("search.filter.videos") { rows(videos) }
                }
                let albums = collections.filter { $0.album != nil }
                if !albums.isEmpty {
                    Section("search.filter.albums") { ForEach(albums) { WatchItemRow(item: $0) } }
                }
                let artists = collections.filter { if case .artist = $0 { true } else { false } }
                if !artists.isEmpty {
                    Section("search.filter.artists") { ForEach(artists) { WatchItemRow(item: $0) } }
                }
                let playlists = collections.filter { if case .playlist(let p) = $0 { !p.isMix } else { false } }
                if !playlists.isEmpty {
                    Section("search.filter.playlists") { ForEach(playlists) { WatchItemRow(item: $0) } }
                }
            }
        }
        .navigationTitle(Text(AppSection.search.title))
        .onAppear {
            if let pending = model.pendingQuery {
                model.pendingQuery = nil
                query = pending
                search()
            }
        }
    }

    private func rows(_ tracks: [Track]) -> some View {
        ForEach(tracks) { track in
            Button { model.play(single: track) } label: {
                HStack(spacing: 8) {
                    ArtworkView(url: track.artworkURL, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title).font(.footnote).lineLimit(2)
                        Text(track.artistsText ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state = .loading
        let catalog = model.services.catalog
        Task {
            async let music = catalog.search(text, filter: .songs)
            async let web = catalog.searchWeb(text, filter: .videos)
            async let summary = try? catalog.searchSummary(text)
            do {
                let (musicPage, webPage) = try await (music, web)
                let mixed = await summary
                collections = ([mixed?.topResult].compactMap { $0 } + (mixed?.items ?? [])).filter { $0.track == nil }
                songs = Array(musicPage.items.compactMap(\.track).prefix(10))
                let known = Set(songs.map(\.videoId))
                videos = Array(webPage.items.compactMap(\.track).filter { !known.contains($0.videoId) }.prefix(10))
                state = .loaded
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "MelogoldPlayFirst"), let first = songs.first { model.play(single: first) }
                #endif
            } catch {
                state = .failed(.of(error))
            }
        }
    }

    private func errorText(_ kind: YouTubeError.Kind) -> LocalizedStringResource {
        switch kind {
        case .offline: "error.offline"
        case .blocked: "error.blocked"
        case .parser: "error.parser"
        case .unknown: "error.unknown"
        }
    }
}
