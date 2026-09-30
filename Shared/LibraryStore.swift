import Foundation
import MelogoldCore
import MelogoldData
import MelogoldPlayback

/// Библиотека для экранов: ♡ и скрытые треки в памяти, счётчики хаба и `revision`, который растёт при любой правке
/// таблиц — своей, от синка или от загрузчика (наблюдение GRDB). Правки плана загрузок (лайки, плейлисты, коллекции)
/// через секунду сверяются с загрузками (REWRITE §4.7.3).
@MainActor
@Observable
final class LibraryStore {
    let library: Library
    let downloads: DownloadManager?

    /// Растёт при правке библиотеки — экраны перечитывают свои списки.
    private(set) var revision = 0
    /// Растёт при правке загрузок.
    private(set) var downloadsRevision = 0
    private(set) var likedIds: Set<String> = []
    private(set) var hiddenIds: Set<String> = []
    private(set) var notInterestedIds: Set<String> = []
    private(set) var counts = LibraryCounts()
    private(set) var downloadStates: [String: DownloadState] = [:]
    /// Свои названия треков (задание 0014): строки, плеер и часы показывают трек через `displayed(_:)`.
    private(set) var overrides: [String: TrackOverride] = [:]
    /// Правки изменились (своя, с другого устройства, снятая): плеер обновляет очередь и системную карточку.
    @ObservationIgnored var onOverridesChanged: (() -> Void)?

    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var planTask: Task<Void, Never>?

    init(library: Library, downloads: DownloadManager?) {
        self.library = library
        self.downloads = downloads
        reload()
        reloadDownloads()
        observe()
    }

    private func observe() {
        observation = LibraryObservation(database: library.database, library: { [weak self] in
            Task { @MainActor in self?.libraryChanged() }
        }, downloads: { [weak self] in
            Task { @MainActor in self?.downloadsChanged() }
        })
    }

    private func libraryChanged() {
        reload()
        planTask?.cancel()
        planTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.downloads?.planChanged()
        }
    }

    private var downloadsPending = false

    /// Загрузчик пишет по куску в секунду — экраны перечитываются не чаще раза в полсекунды.
    private func downloadsChanged() {
        guard !downloadsPending else { return }
        downloadsPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.downloadsPending = false
            self?.reloadDownloads()
        }
    }

    private func reload() {
        likedIds = library.likedIds()
        hiddenIds = library.hiddenIds()
        notInterestedIds = library.notInterestedIds()
        counts = library.counts()
        let newOverrides = library.allTrackOverrides()
        if newOverrides != overrides {
            overrides = newOverrides
            onOverridesChanged?()
        }
        revision &+= 1
    }

    private func reloadDownloads() {
        downloadStates = downloads?.store.states() ?? [:]
        counts.downloads = downloadStates.values.filter { $0 == .completed }.count
        downloadsRevision &+= 1
    }

    func isLiked(_ videoId: String) -> Bool { likedIds.contains(videoId) }

    /// Трек, как его показывать: со своим названием, исполнителем и альбомом (задание 0014). Одна точка для строк, плеера
    /// и часов; чтение наблюдаемое — экран обновляется, когда правка меняется. Показанный трек помнит оригинал.
    func displayed(_ track: Track) -> Track {
        overrides[track.videoId]?.apply(to: track) ?? track.raw
    }

    func isDownloaded(_ videoId: String) -> Bool { downloadStates[videoId] == .completed }

    func toggleLike(_ track: Track) {
        library.setLiked(track, !isLiked(track.videoId))
    }
}
