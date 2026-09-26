import Foundation
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
import MelogoldPlayback

/// Текст играющего трека (docs/PROMPT.md §5.7): сначала из базы, иначе цепочка поиска (`LyricsFetcher`); итог
/// ложится в базу. Синхронный текст — модель `SyncedLyrics` (LRC и TTML с дуэтами, подпевкой и словами), строки
/// экрана — `LyricRows`. Один на приложение — и на часах.
@MainActor
@Observable
final class LyricsModel {
    enum State: Equatable {
        case idle, loading, loaded, notFound, offline
    }

    private(set) var track: Track?
    private(set) var stored: StoredLyrics?
    private(set) var synced: SyncedLyrics?
    private(set) var rows: [LyricRow] = []
    private(set) var state: State = .idle
    /// Выбор вида у этого трека: синхронный, если он есть (переключатель в меню текста).
    var preferSynced = true

    @ObservationIgnored private let fetcher: LyricsFetcher
    @ObservationIgnored private let store: LyricsStore?
    @ObservationIgnored private let player: PlayerEngine
    @ObservationIgnored private var task: Task<Void, Never>?

    init(fetcher: LyricsFetcher, store: LyricsStore?, player: PlayerEngine) {
        self.fetcher = fetcher
        self.store = store
        self.player = player
    }

    var showingSynced: Bool { preferSynced && synced != nil }

    /// Обычный текст: своя сторона или строки синхронного.
    var plain: String? {
        if let text = stored?.plain, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return synced.map { $0.lines.map(\.text).joined(separator: "\n") }
    }

    var hasAny: Bool { synced != nil || plain != nil }

    /// Сдвиг синхронного текста трека, мс (положительный — текст раньше).
    var offsetMs: Int64 { stored?.offsetMs ?? 0 }

    /// Источник текста на экране: «Текст от сообщества Melogold» у общего текста (задание 0001 §3.5).
    var isCommunity: Bool {
        (showingSynced ? stored?.syncedSource : stored?.plainSource) == LyricsSources.melogold
    }

    /// Позиция текста: позиция трека со сдвигом, мс.
    func lyricsPosition(_ seconds: Double) -> Int64 {
        Int64(seconds * 1000) + offsetMs
    }

    /// Показать текст трека: из базы, иначе поиск. Повторный вызов для того же трека ничего не делает.
    func load(_ track: Track, force: Bool = false) {
        guard force || self.track?.videoId != track.videoId || state == .offline else { return }
        task?.cancel()
        self.track = track
        preferSynced = true
        let saved = store?.lyrics(track.videoId)
        apply(saved)
        let complete = saved.map { $0.synced != nil && $0.plain != nil } ?? false
        if complete, !force {
            state = hasAny ? .loaded : .notFound
            return
        }
        state = hasAny ? .loaded : .loading
        let current = force ? nil : saved
        let durationMs = track.durationMs ?? Int64(player.duration * 1000)
        task = Task { [fetcher, store] in
            let result = await fetcher.fetch(track, durationMs: durationMs, current: current)
            guard !Task.isCancelled, self.track?.videoId == track.videoId else { return }
            if result.anyFailure, result.synced == nil, result.plain == nil {
                self.state = self.hasAny ? .loaded : .offline
                return
            }
            // «Искали, не нашли» — пустая строка, чтобы не искать снова (как у Windows).
            let value = StoredLyrics(
                synced: result.synced ?? (result.anyFailure ? nil : ""), plain: result.plain ?? (result.anyFailure ? nil : ""),
                syncedSource: result.syncedSource, plainSource: result.plainSource,
                offsetMs: result.offsetMs ?? saved?.offsetMs ?? 0, language: result.language ?? saved?.language
            )
            store?.save(track.videoId, value)
            self.apply(value)
            self.state = self.hasAny ? .loaded : .notFound
        }
    }

    /// «Искать заново»: забыть найденное и пройти цепочку снова (свой текст не трогается).
    func searchAgain() {
        guard let track else { return }
        if stored?.isOwn != true { store?.delete(track.videoId) }
        load(track, force: true)
    }

    /// Сдвиг ±0,1 и ±0,5 с; `nil` — сбросить.
    func shift(by delta: Int64?) {
        guard let track, var value = stored else { return }
        value.offsetMs = delta.map { value.offsetMs + $0 } ?? 0
        store?.setOffset(track.videoId, value.offsetMs)
        stored = value
    }

    /// Текст из «Найти текст» (LRCLIB): не свой, на сервер не уходит.
    func use(_ result: LrcLibTrack) {
        guard let track else { return }
        let value = StoredLyrics(
            synced: result.syncedLyrics?.nilIfBlank ?? "", plain: result.plainLyrics?.nilIfBlank ?? stored?.plain,
            syncedSource: result.syncedLyrics?.nilIfBlank == nil ? nil : LyricsSources.lrclib,
            plainSource: result.plainLyrics?.nilIfBlank == nil ? stored?.plainSource : LyricsSources.lrclib
        )
        store?.save(track.videoId, value)
        apply(value)
        state = hasAny ? .loaded : .notFound
    }

    /// Свой текст: импорт файла (`file`) или редактор (`user`) — синк отправит его на сервер.
    func saveOwn(synced: String?, plain: String?, source: String, language: String? = nil) {
        guard let track else { return }
        let value = StoredLyrics(
            synced: synced ?? stored?.synced, plain: plain ?? stored?.plain,
            syncedSource: synced == nil ? stored?.syncedSource : source, plainSource: plain == nil ? stored?.plainSource : source,
            offsetMs: synced == nil ? offsetMs : 0, language: language ?? stored?.language
        )
        store?.save(track.videoId, value)
        apply(value)
        state = hasAny ? .loaded : .notFound
    }

    /// Импорт `.lrc`, `.ttml` или простого текста.
    @discardableResult
    func importFile(_ text: String) -> Bool {
        switch LyricsFormats.detect(text) {
        case .ttml, .lrc:
            guard LyricsFormats.parseSynced(text) != nil else { return false }
            saveOwn(synced: text, plain: nil, source: LyricsSources.file)
        case .plain:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            saveOwn(synced: nil, plain: text, source: LyricsSources.file)
        }
        return true
    }

    private func apply(_ value: StoredLyrics?) {
        stored = value
        synced = value?.synced.flatMap { $0.isEmpty ? nil : LyricsFormats.parseSynced($0) }
        rows = synced.map(LyricRows.build) ?? []
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
