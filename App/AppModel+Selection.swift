import SwiftUI
import MelogoldCore
import MelogoldData

/// Вопрос с полем ввода для выделенного: название нового плейлиста и альбом (`RootView` показывает его окном).
enum SelectionPrompt: Identifiable {
    case newPlaylist(tracks: [Track], name: String)
    case setAlbum(videoIds: [String], name: String)

    var id: String {
        switch self {
        case .newPlaylist: "newPlaylist"
        case .setAlbum: "setAlbum"
        }
    }
}

/// Что делает «Убрать…» для выделенного там, где список это допускает (плейлист, Избранное, История).
enum SelectionRemoval: Equatable {
    case playlist(Int64)
    case favorites
    case history

    init?(_ context: TrackMenuContext?) {
        switch context {
        case .playlist(let id)?: self = .playlist(id)
        case .favorites?: self = .favorites
        case .history?: self = .history
        default: return nil
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .playlist: "menu.removeFromPlaylist"
        case .favorites: "menu.unlike"
        case .history: "menu.removeFromHistory"
        }
    }

    var systemImage: String {
        switch self {
        case .playlist: "minus.circle"
        case .favorites: "heart.slash"
        case .history: "clock.badge.xmark"
        }
    }
}

extension AppModel {
    /// Трек, как его показывать: со своим названием, исполнителем и альбомом (задание 0014).
    func displayed(_ track: Track) -> Track {
        library?.displayed(track) ?? track
    }

    // MARK: - Действия с выделенными треками (задание 0013)

    private func tracksText(_ count: Int) -> String {
        String(localized: "library.tracks \(count)")
    }

    /// «Слушать»: выделенные в порядке списка — новой очередью.
    func playSelection(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        play(tracks, startAt: 0)
    }

    /// «В конец очереди»: «В конец очереди: N треков».
    func enqueueSelection(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        services.player.enqueue(tracks)
        toast = Toast(text: String(localized: "selection.enqueued \(tracksText(tracks.count))"))
    }

    /// «В Избранное» всем сразу: одна транзакция — одна запись в синк.
    func likeSelection(_ tracks: [Track]) {
        guard !tracks.isEmpty, let library else { return }
        library.library.setLiked(tracks, true)
        toast = Toast(text: String(localized: "selection.favorited \(tracksText(tracks.count))"))
    }

    /// «Скачать»: скачанные, скачивающиеся и трансляции пропускаются.
    func downloadSelection(_ tracks: [Track]) {
        guard let library, let downloads = services.downloads else { return }
        let busy = Set(library.downloadStates.filter { $0.value != .failed }.keys)
        let fresh = SelectionRules.toDownload(tracks, busy: busy)
        fresh.forEach(downloads.download)
        toast = Toast(text: fresh.isEmpty
            ? String(localized: "selection.alreadyDownloaded")
            : String(localized: "selection.downloading \(tracksText(fresh.count))"))
    }

    /// «Новый плейлист…»: название по умолчанию — общий альбом выделенного.
    func promptNewPlaylist(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        selectionPrompt = .newPlaylist(tracks: tracks, name: SelectionRules.commonAlbum(of: tracks) ?? defaultPlaylistName)
    }

    var defaultPlaylistName: String {
        String(localized: "playlist.defaultName \((library?.counts.playlists ?? 0) + 1)")
    }

    func createPlaylist(from tracks: [Track], name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPlaylistName : name
        guard let id = createPlaylist(name: title, tracks: tracks) else { return }
        selectionFinished += 1
        toast = Toast(text: String(localized: "selection.playlistCreated \(title) \(tracksText(tracks.count))"),
                      actionTitle: "selection.open") { [weak self] in self?.open(.localPlaylist(id)) }
    }

    /// «Указать альбом…»: по умолчанию — общий альбом выделенного, иначе название плейлиста, из которого выделяли.
    func promptSetAlbum(_ tracks: [Track], collectionName: String?) {
        guard !tracks.isEmpty else { return }
        selectionPrompt = .setAlbum(videoIds: tracks.map(\.videoId), name: SelectionRules.commonAlbum(of: tracks) ?? collectionName ?? "")
    }

    func setAlbum(_ name: String, for videoIds: [String]) {
        library?.library.setAlbum(name, for: videoIds)
        selectionFinished += 1
        toast = Toast(text: String(localized: "selection.albumSet \(name.trimmingCharacters(in: .whitespacesAndNewlines))"))
    }

    /// «Убрать…» из плейлиста, Избранного или Истории — с «Отменить», как у одного трека.
    func removeSelection(_ tracks: [Track], _ removal: SelectionRemoval) {
        guard let library, !tracks.isEmpty else { return }
        switch removal {
        case .playlist(let id):
            let ids = tracks.map(\.videoId)
            deferChange(String(localized: "library.removedFromPlaylist"), hides: Set(ids.map { PendingKey.item(id, $0) })) {
                for videoId in ids { library.library.remove(videoId, fromPlaylist: id) }
            }
        case .favorites:
            deferChange(String(localized: "library.removedFromFavorites"), hides: Set(tracks.map { PendingKey.like($0.videoId) })) {
                library.library.setLiked(tracks, false)
            }
        case .history:
            let text = sync.historyReachesAccount
                ? String(localized: "library.removedFromHistoryEverywhere") : String(localized: "library.removedFromHistory")
            let now = EpochMs.now()
            let ids = tracks.map(\.videoId)
            deferChange(text, hides: Set(ids.map { PendingKey.history($0) })) {
                for videoId in ids { library.library.removeFromHistory(videoId, at: now) }
            }
        }
    }
}
