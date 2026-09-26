import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldPlayback

/// Отложенное разрушающее действие (docs/PROMPT.md §5.10, Android `PendingMutations`): удалённое сразу пропадает
/// из списков (`hides`), а в базу пишется через 5 секунд. Плашка одна: новая сразу выполняет предыдущее действие.
struct PendingChange: Identifiable {
    let id = UUID()
    let text: String
    /// Ключи строк, которые списки прячут, пока действие не выполнено.
    let hides: Set<String>
    let commit: () -> Void
}

/// Ключи прячущихся строк.
enum PendingKey {
    static func like(_ videoId: String) -> String { "like:" + videoId }
    static func item(_ playlistId: Int64, _ videoId: String) -> String { "item:\(playlistId):" + videoId }
    static func playlist(_ id: Int64) -> String { "playlist:\(id)" }
    static func history(_ videoId: String) -> String { "history:" + videoId }
    static let allHistory = "history:*"
    static func download(_ videoId: String) -> String { "download:" + videoId }
}

extension AppModel {
    var library: LibraryStore? { services.library }

    // MARK: - Замена очереди

    /// Заменить очередь; если в прежней было два трека пользователя и больше — «Очередь заменена · Отменить»
    /// (REWRITE §2.3) возвращает прежнюю очередь, трек и позицию.
    func replaceQueue(_ perform: () -> Void) {
        let player = services.player
        let previous = player.userItemsCount >= 2 ? player.snapshot() : nil
        perform()
        guard let previous else { return }
        toast = Toast(text: String(localized: "queue.replaced"), actionTitle: "common.undo") { [weak self] in
            self?.services.player.restore(previous, play: true)
        }
    }

    func playRadio(playlistId: String, seed: Track) {
        replaceQueue { services.player.playRadio(playlistId: playlistId, seed: seed) }
    }

    // MARK: - Отложенные действия

    func isHidden(_ key: String) -> Bool {
        pending?.hides.contains(key) == true
    }

    /// Отложить действие на 5 секунд с «Отменить»; предыдущее выполняется сразу.
    func deferChange(_ text: String, hides: Set<String>, commit: @escaping () -> Void) {
        commitPending()
        let change = PendingChange(text: text, hides: hides, commit: commit)
        pending = change
        toast = nil
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undoPending() }
        }
        undoManager?.setActionName(text)
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.pending?.id == change.id else { return }
            self?.commitPending()
        }
    }

    /// Выполнить отложенное сейчас (новая плашка, уход в фон).
    func commitPending() {
        guard let change = pending else { return }
        pending = nil
        pendingTask?.cancel()
        undoManager?.removeAllActions(withTarget: self)
        change.commit()
    }

    /// «Отменить», ⌘Z, встряхивание.
    func undoPending() {
        guard pending != nil else { return }
        pending = nil
        pendingTask?.cancel()
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Избранное

    func isLiked(_ track: Track) -> Bool {
        library?.isLiked(track.videoId) == true && !isHidden(PendingKey.like(track.videoId))
    }

    /// ♡: поставить сразу, снять — сразу (в плеере и строке); из меню и Избранного снятие — с «Отменить».
    func toggleLike(_ track: Track) {
        guard let library else { return }
        if library.isLiked(track.videoId) {
            library.library.setLiked(track, false)
        } else {
            library.library.setLiked(track, true)
        }
    }

    func removeFromFavorites(_ track: Track) {
        guard let library else { return }
        deferChange(String(localized: "library.removedFromFavorites"), hides: [PendingKey.like(track.videoId)]) {
            library.library.setLiked(track, false)
        }
    }

    // MARK: - Плейлисты

    @discardableResult
    func createPlaylist(name: String, tracks: [Track] = []) -> Int64? {
        library?.library.createPlaylist(name: name, tracks: tracks)
    }

    func add(_ tracks: [Track], toPlaylist playlist: LibraryPlaylist) {
        let added = library?.library.add(tracks, toPlaylist: playlist.id) ?? 0
        toast = Toast(text: added == 0
            ? String(localized: "library.alreadyInPlaylist \(playlist.name)")
            : String(localized: "library.addedToPlaylist \(playlist.name)"))
    }

    func removeFromPlaylist(_ track: Track, playlistId: Int64) {
        guard let library else { return }
        deferChange(String(localized: "library.removedFromPlaylist"), hides: [PendingKey.item(playlistId, track.videoId)]) {
            library.library.remove(track.videoId, fromPlaylist: playlistId)
        }
    }

    func deletePlaylist(_ playlist: LibraryPlaylist) {
        guard let library else { return }
        deferChange(String(localized: "library.playlistDeleted \(playlist.name)"), hides: [PendingKey.playlist(playlist.id)]) {
            library.library.deletePlaylist(playlist.id)
        }
        // Экран удаляемого плейлиста закрывается.
        routes[section]?.removeAll { $0 == .localPlaylist(playlist.id) }
    }

    // MARK: - История

    /// «Убрать из истории» — с «Отменить», как «Убрать из плейлиста». С аккаунтом история общая: трек уходит из Истории
    /// на всех устройствах (задание 0002 §3.4) — плашка так и говорит, и после выхода, пока действие ещё дойдёт до
    /// аккаунта (`LibrarySync.historyReachesAccount`). Граница — момент нажатия, а не выполнения через 5 с: прослушивание,
    /// закончившееся за время «Отменить», остаётся (как на Android).
    func removeFromHistory(_ track: Track) {
        guard let library else { return }
        let text = sync.historyReachesAccount
            ? String(localized: "library.removedFromHistoryEverywhere") : String(localized: "library.removedFromHistory")
        let now = EpochMs.now()
        deferChange(text, hides: [PendingKey.history(track.videoId)]) {
            library.library.removeFromHistory(track.videoId, at: now)
        }
    }

    /// «Очистить историю» после подтверждения на экране Истории — с «Отменить»; с аккаунтом — на всех устройствах.
    /// Граница — момент подтверждения.
    func clearHistory() {
        guard let library else { return }
        let text = sync.historyReachesAccount
            ? String(localized: "library.historyClearedEverywhere") : String(localized: "library.historyCleared")
        let now = EpochMs.now()
        deferChange(text, hides: [PendingKey.allHistory]) {
            library.library.clearHistory(at: now)
        }
    }

    // MARK: - Загрузки

    func download(_ track: Track) {
        services.downloads?.download(track)
    }

    func removeDownload(_ track: Track) {
        guard let downloads = services.downloads else { return }
        deferChange(String(localized: "library.downloadRemoved"), hides: [PendingKey.download(track.videoId)]) {
            downloads.remove(track.videoId)
        }
    }

    // MARK: - «Не показывать этот трек»

    /// Трек пропадает из радио, автовоспроизведения и «Для вас» (GLOSSARY №82); «Отменить» возвращает.
    func hide(_ track: Track) {
        guard let library else { return }
        library.library.setHidden(track, true)
        toast = Toast(text: String(localized: "library.trackHidden"), actionTitle: "common.undo") {
            library.library.setHidden(track, false)
        }
    }

    // MARK: - Альбомы и исполнители

    func isAlbumSaved(_ browseId: String) -> Bool {
        _ = library?.revision
        return library?.library.isAlbumSaved(browseId) == true
    }

    func setAlbumSaved(_ album: AlbumItem, tracks: [Track], _ saved: Bool) {
        library?.library.setAlbumSaved(album, tracks: tracks, saved)
        if saved { toast = Toast(text: String(localized: "library.savedToLibrary")) }
    }

    func isArtistSaved(_ browseId: String) -> Bool {
        _ = library?.revision
        return library?.library.isArtistSaved(browseId) == true
    }

    func setArtistSaved(_ artist: ArtistItem, _ saved: Bool) {
        library?.library.setArtistSaved(artist, saved)
    }
}
