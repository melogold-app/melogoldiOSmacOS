import SwiftUI
import MelogoldCore
import MelogoldInnerTube

/// Альбом (REWRITE §3.6): шапка, треки с номером вместо обложки, карусель «Другие версии» под заголовком
/// YouTube Music, «Об альбоме». Нажатие по треку — список альбома с этого трека. «Сохранить» и «Скачать» —
/// со срезом 4.
struct AlbumView: View {
    @Environment(AppModel.self) private var model
    let browseId: String
    @State private var loader = PageLoader<AlbumDetails>()

    var body: some View {
        Group {
            if let album = loader.value {
                page(album)
            } else {
                PageStateView(state: loader.state) { Task { await load(force: true) } }
            }
        }
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        let browseId = browseId
        await loader.load(force: force) { try await catalog.album(browseId) }
    }

    private func page(_ details: AlbumDetails) -> some View {
        let album = details.album
        let tracks = details.tracks
        return DetailPage(title: album.title) {
            CollectionHeader(artworkURL: album.thumbnailUrl, title: album.title) {
                VStack(spacing: 4) {
                    if let artistId = album.artists.first(where: { $0.id != nil })?.id, let name = album.artistsText {
                        Button(name) { model.open(.artist(artistId)) }
                            .font(.title3)
                            .buttonStyle(.borderless)
                    } else if let name = album.artistsText {
                        Text(name).font(.title3)
                    }
                    Text(Self.facts(details))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } actions: {
                PlayButton { model.playAll(tracks, shuffled: false) }
                ShuffleButton { model.playAll(tracks, shuffled: true) }
            }
        } rows: {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackListRow(track: track, subtitle: sameArtists(track, album) ? "" : track.artistsText,
                             number: index + 1, showsArtwork: false, target: .list(tracks, index))
                    .tag(RowID.make("t", track.videoId))
            }
            ForEach(details.shelves) { shelf in
                ShelfRows(shelf: shelf)
            }
            if let description = details.description, !description.isEmpty {
                AboutRow(title: "album.about", text: description)
                    .listRowSeparator(.hidden)
                    .padding(.top, 8)
            }
        } target: { id in
            guard let (_, key) = RowID.split(id), let index = tracks.firstIndex(where: { $0.videoId == key }) else { return nil }
            return .list(tracks, index)
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
                    if let playlistId = album.playlistId {
                        Button { model.playMix("RDAMPL" + playlistId) } label: {
                            Label("album.radio", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    if let artistId = album.artists.first(where: { $0.id != nil })?.id {
                        Button { model.open(.artist(artistId)) } label: {
                            Label("menu.goToArtist", systemImage: "music.mic")
                        }
                    }
                    ShareLink(item: ShareLinks.album(album.browseId)) {
                        Label("menu.share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
            }
        }
    }

    /// «Альбом · 1988 · 11 треков · 47 минут».
    static func facts(_ details: AlbumDetails) -> String {
        let count = details.countText.map { $0.replacingOccurrences(of: " • ", with: " · ") }
        return [details.album.typeText, details.album.year, count].compactMap { $0 }.joined(separator: " · ")
    }

    /// Исполнители трека совпадают с исполнителями альбома — подпись строки не нужна.
    private func sameArtists(_ track: Track, _ album: AlbumItem) -> Bool {
        track.artistsText == nil || track.artistsText == album.artistsText
    }
}
