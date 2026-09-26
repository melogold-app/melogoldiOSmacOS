import SwiftUI
import MelogoldCore

/// Где открыто меню трека: добавляет пункт «по месту» после разделителя (REWRITE §3.11.3).
enum TrackMenuContext: Hashable {
    case playlist(Int64)
    case history
    case queue(UUID)
    case favorites
}

/// Запрос листа «Добавить в плейлист…».
struct PlaylistPickerRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

/// Пункты меню трека — порядок по REWRITE §3.11.3, одинаково на всех клиентах (docs/PROMPT.md §5.8).
struct TrackMenuItems: View {
    @Environment(AppModel.self) private var model
    let track: Track
    var context: TrackMenuContext?

    var body: some View {
        let liked = model.isLiked(track)
        Section {
            Button {
                if liked { model.removeFromFavorites(track) } else { model.toggleLike(track) }
            } label: {
                Label(liked ? "menu.unlike" : "menu.like", systemImage: liked ? "heart.slash" : "heart")
            }
        }
        Section {
            Button { model.playNext([track]) } label: {
                Label("menu.playNext", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { model.enqueue([track]) } label: {
                Label("menu.addToQueue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button { model.playlistPicker = PlaylistPickerRequest(tracks: [track]) } label: {
                Label("menu.addToPlaylist", systemImage: "text.badge.plus")
            }
        }
        Section {
            downloadItem
            Button { model.searchOtherVersions(of: track) } label: {
                Label("menu.otherVersions", systemImage: "square.on.square")
            }
            Button { model.startRadio(track) } label: {
                Label("menu.startRadio", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        Section {
            if track.albumId != nil {
                Button { model.openAlbum(of: track) } label: {
                    Label("menu.goToAlbum", systemImage: "square.stack")
                }
            }
            if track.primaryArtistId != nil {
                Button { model.openArtist(of: track) } label: {
                    if track.isVideo && track.videoType != VideoType.video {
                        Label("menu.goToChannel", systemImage: "play.rectangle")
                    } else {
                        Label("menu.goToArtist", systemImage: "music.mic")
                    }
                }
            }
        }
        Section {
            ShareLink(item: ShareLinks.track(track)) {
                Label("menu.share", systemImage: "square.and.arrow.up")
            }
            #if !os(watchOS)
            Button { model.saveAsFile(track) } label: {
                Label("menu.saveFile", systemImage: "square.and.arrow.down.on.square")
            }
            #endif
            Button { model.hide(track) } label: {
                Label("menu.hide", systemImage: "eye.slash")
            }
        }
        if let context {
            Section {
                switch context {
                case .playlist(let id):
                    Button(role: .destructive) { model.removeFromPlaylist(track, playlistId: id) } label: {
                        Label("menu.removeFromPlaylist", systemImage: "minus.circle")
                    }
                case .history:
                    Button(role: .destructive) { model.removeFromHistory(track) } label: {
                        Label("menu.removeFromHistory", systemImage: "clock.badge.xmark")
                    }
                case .queue(let itemId):
                    Button(role: .destructive) { model.services.player.remove(itemId) } label: {
                        Label("menu.removeFromQueue", systemImage: "minus.circle")
                    }
                case .favorites:
                    EmptyView()
                }
            }
        }
    }

    /// «Скачать» или состояние загрузки (REWRITE §4.7.5a): отменить, скачать снова, удалить.
    @ViewBuilder
    private var downloadItem: some View {
        switch model.library?.downloadStates[track.videoId] {
        case .completed?:
            Button(role: .destructive) { model.removeDownload(track) } label: {
                Label("menu.removeDownload", systemImage: "trash")
            }
        case .failed?:
            Button { model.services.downloads?.retry(track.videoId) } label: {
                Label("menu.downloadAgain", systemImage: "arrow.clockwise")
            }
        case .some:
            Button { model.services.downloads?.remove(track.videoId) } label: {
                Label("menu.cancelDownload", systemImage: "xmark.circle")
            }
        case nil:
            if model.services.downloads != nil, track.videoType != VideoType.live {
                Button { model.download(track) } label: {
                    Label("menu.download", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

/// Кнопка «…» в строке трека (iPhone, iPad, Vision). На Mac меню — правым щелчком.
struct TrackMenuButton: View {
    let track: Track
    var context: TrackMenuContext?

    var body: some View {
        #if !os(macOS)
        Menu {
            TrackMenuItems(track: track, context: context)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("menu.more"))
        #endif
    }
}

extension AppModel {
    /// «Другие версии»: поиск по названию и исполнителю.
    func searchOtherVersions(of track: Track) {
        let query = [track.title, track.artistsText].compactMap { $0 }.joined(separator: " ")
        section = .search
        routes[.search] = []
        searchQuery = query
        search.submit(query)
    }
}

/// Нажатие по строке и меню строк в `List` (docs/PROMPT.md §5.4, §5.8): на iPhone, iPad и Vision нажатие играет
/// или открывает, долгое нажатие — меню; на Mac щелчок выделяет, двойной щелчок или Return играет, правый щелчок —
/// меню. Строки помечаются `tag(<id>)`, `target` переводит id в действие.
struct RowActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: (String) -> RowTarget?
    var context: (String) -> TrackMenuContext? = { _ in nil }

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let target = target(id) {
                switch target {
                case .list(let tracks, let index): TrackMenuItems(track: tracks[index], context: context(id))
                case .single(let track): TrackMenuItems(track: track, context: context(id))
                case .open, .mix: EmptyView()
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let target = target(id) else { return }
            model.activate(target)
        }
    }
}

extension View {
    func rowActions(_ target: @escaping (String) -> RowTarget?,
                    context: @escaping (String) -> TrackMenuContext? = { _ in nil }) -> some View {
        modifier(RowActions(target: target, context: context))
    }
}

/// Id строки: раздел страницы и ключ элемента — один трек может стоять в двух разделах.
enum RowID {
    static func make(_ section: String, _ key: String) -> String { section + "|" + key }

    static func split(_ id: String) -> (section: String, key: String)? {
        guard let bar = id.firstIndex(of: "|") else { return nil }
        return (String(id[..<bar]), String(id[id.index(after: bar)...]))
    }
}
