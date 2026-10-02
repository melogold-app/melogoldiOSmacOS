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

    /// Сначала сеть; без сети сохранённый альбом открывается из базы (REWRITE §3.6, §4.11.2).
    private func load(force: Bool = false) async {
        let catalog = model.services.catalog
        let browseId = browseId
        let library = model.library?.library
        await loader.load(force: force) {
            do {
                return try await catalog.album(browseId)
            } catch {
                guard let album = library?.savedAlbum(browseId), let tracks = library?.albumTracks(browseId), !tracks.isEmpty else { throw error }
                return AlbumDetails(album: album, description: nil, countText: nil, tracks: tracks, shelves: [])
            }
        }
    }

    private func page(_ details: AlbumDetails) -> some View {
        let album = details.album
        let tracks = details.tracks
        return DetailPage(title: album.title, fullBleedHeader: DetailLayout.compactCover == .hero,
                          rowIds: tracks.map { RowID.make("t", $0.videoId) }, tintURL: album.thumbnailUrl) {
            CollectionHeader(artworkURL: album.thumbnailUrl, style: DetailLayout.compactCover, title: album.title,
                             description: details.description) {
                HeaderSubtitle(spacing: 2) {
                    // Исполнитель крупно — цветом акцента на Mac, цветом текста на цветной странице iPhone, как в «Музыке»
                    if let artistId = album.artists.first(where: { $0.id != nil })?.id, let name = album.artistsText {
                        Button(name) { model.open(.artist(artistId)) }
                            .font(Self.artistFont)
                            .buttonStyle(.plain)
                            .foregroundStyle(Self.artistStyle)
                    } else if let name = album.artistsText {
                        Text(name).font(Self.artistFont)
                    }
                    Text(Self.facts(details))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } actions: {
                CollectionActions(play: { model.playAll(tracks, shuffled: false) },
                                  shuffle: { model.playAll(tracks, shuffled: true) }) {
                    // «Скачать» у альбома заодно сохраняет его в библиотеку (REWRITE §3.6)
                    CollectionDownloadButton(kind: .album, key: album.browseId, title: album.title, plainGlyphs: true) {
                        model.setAlbumSaved(album, tracks: tracks, true)
                    }
                }
            }
        } rows: {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackListRow(track: track, subtitle: sameArtists(track, album) ? "" : track.artistsText,
                             number: index + 1, showsArtwork: false, target: .list(tracks, index))
                    .albumRowHeight()
                    .tag(RowID.make("t", track.videoId))
            }
            // Под треками, как в «Музыке»: сколько песен и сколько длится
            if let count = details.countText {
                Text(verbatim: count.replacingOccurrences(of: " • ", with: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.top, Design.Space.s)
            }
            ForEach(details.shelves) { shelf in
                ShelfRows(shelf: shelf)
            }
        } target: { id in
            guard let (_, key) = RowID.split(id), let index = tracks.firstIndex(where: { $0.videoId == key }) else { return nil }
            return .list(tracks, index)
        }
        .toolbar {
            ToolbarItem {
                let saved = model.isAlbumSaved(album.browseId)
                Button {
                    model.setAlbumSaved(album, tracks: tracks, !saved)
                } label: {
                    Label(saved ? "collection.inLibrary" : "collection.save", systemImage: saved ? "checkmark" : "plus")
                }
            }
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
                    ShareLink(item: ShareLinks.album(album.browseId), subject: Text(verbatim: album.title),
                              message: Text(verbatim: ShareText.line(album.title, album.artistsText))) {
                        Label("menu.share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
            }
        }
    }

    /// «Альбом · 1988» — тип и год, как «Pop · 2021» в «Музыке»; сколько песен и минут — под треками.
    static func facts(_ details: AlbumDetails) -> String {
        [details.album.typeText, details.album.year].compactMap { $0 }.joined(separator: " · ")
    }

    #if os(macOS)
    static let artistFont = Font.system(size: 24)
    static let artistStyle = AnyShapeStyle(.tint)
    #else
    static let artistFont = Font.title2
    static let artistStyle = AnyShapeStyle(.primary)
    #endif

    /// Исполнители трека совпадают с исполнителями альбома — подпись строки не нужна.
    private func sameArtists(_ track: Track, _ album: AlbumItem) -> Bool {
        track.artistsText == nil || track.artistsText == album.artistsText
    }
}
