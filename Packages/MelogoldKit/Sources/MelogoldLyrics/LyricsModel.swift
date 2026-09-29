import Foundation
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
import Observation

/// Цепочка поиска текста, какой её видит модель: по треку и уже имеющемуся тексту (`current`) находит недостающее.
public protocol LyricsFetching: Sendable {
    func fetch(_ track: Track, durationMs: Int64, current: StoredLyrics?) async -> LyricsFetchResult
}

extension LyricsFetcher: LyricsFetching {}

/// Текст играющего трека (docs/PROMPT.md §5.7): сначала из базы, иначе цепочка поиска (`LyricsFetching`); итог ложится
/// в базу. Одна на приложение — и на часах.
///
/// Всё, что меняет текст, — редактор, импорт, выбор в «Найти текст», поиск, синк, — пишет в трек по `videoId`, а не «в
/// то, что играет сейчас»: экран редактора живёт дольше одного трека. Запись — правило над строкой из базы одной
/// транзакцией (`LyricsStore`, `LyricsRules`), а не запись того, что модель помнила: поиск в полёте не затирает текст,
/// появившийся за время поиска, а строка, которую поменял синк, приходит в модель по наблюдению базы.
@MainActor
@Observable
public final class LyricsModel {
    public enum State: Equatable, Sendable {
        case idle, loading, loaded, notFound, offline
    }

    /// Итог выбора текста в «Найти текст».
    public enum UseResult: Equatable, Sendable {
        case applied
        /// Здесь набранный или импортированный текст: заменять его надо только с подтверждения.
        case needsConfirmation
    }

    public private(set) var track: Track?
    public private(set) var content = LyricsContent(nil)
    public private(set) var state: State = .idle
    /// Выбор вида у этого трека: синхронный, если он есть (переключатель в меню текста).
    public var preferSynced = true

    @ObservationIgnored private let fetcher: any LyricsFetching
    @ObservationIgnored private let store: LyricsStore?
    @ObservationIgnored private let playerDurationMs: @MainActor () -> Int64
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observation: LyricsObservation?

    /// `playerDurationMs` — длительность играющего трека, мс, если её нет у самого трека.
    public init(fetcher: any LyricsFetching, store: LyricsStore?, playerDurationMs: @escaping @MainActor () -> Int64 = { 0 }) {
        self.fetcher = fetcher
        self.store = store
        self.playerDurationMs = playerDurationMs
    }

    public var stored: StoredLyrics? { content.stored }
    public var synced: SyncedLyrics? { content.synced }
    public var rows: [LyricRow] { content.rows }
    public var plain: String? { content.plain }
    public var hasAny: Bool { content.hasAny }
    public var offsetMs: Int64 { content.offsetMs }
    public var showingSynced: Bool { preferSynced && synced != nil }

    /// Источник текста на экране: «Текст от сообщества Melogold» у общего текста (задание 0001 §3.5).
    public var isCommunity: Bool {
        (showingSynced ? stored?.syncedSource : stored?.plainSource) == LyricsSources.melogold
    }

    /// Позиция текста: позиция трека со сдвигом, мс.
    public func lyricsPosition(_ seconds: Double) -> Int64 {
        Int64(seconds * 1000) + offsetMs
    }

    /// Строка текста трека из базы: редактор и другие экраны читают её, а не то, что показано сейчас — показан может
    /// быть уже другой трек.
    public func stored(for videoId: String) -> StoredLyrics? {
        if let store { return store.lyrics(videoId) }
        return track?.videoId == videoId ? content.stored : nil
    }

    // MARK: - Показ

    /// Показать текст трека: из базы, иначе поиск. Повторный вызов для того же трека ничего не делает (кроме «нет сети»:
    /// он ищет снова). `force` — пройти цепочку поиска ещё раз: заново ищутся только стороны, которых нет.
    public func load(_ track: Track, force: Bool = false) {
        guard force || self.track?.videoId != track.videoId || state == .offline else { return }
        start(track, saved: store?.lyrics(track.videoId), force: force)
    }

    /// «Повторить» в пустом состоянии «нет сети».
    public func retry() {
        guard let track else { return }
        load(track, force: true)
    }

    /// «Искать заново»: забыть найденное и пройти цепочку снова. Свой, импортированный и выбранный текст не трогается.
    public func searchAgain() {
        guard let track else { return }
        task?.cancel()
        observation?.cancel()
        let remaining = store.map { $0.forgetFound(track.videoId) } ?? LyricsRules.forgetFound(content.stored)
        start(track, saved: remaining, force: true)
    }

    private func start(_ track: Track, saved: StoredLyrics?, force: Bool) {
        task?.cancel()
        observation?.cancel()
        self.track = track
        preferSynced = true
        setContent(saved)
        watch(track.videoId)
        let complete = saved.map { $0.synced != nil && $0.plain != nil } ?? false
        if complete, !force {
            state = hasAny ? .loaded : .notFound
            return
        }
        state = hasAny ? .loaded : .loading
        search(track, baseline: saved)
    }

    private func search(_ track: Track, baseline: StoredLyrics?) {
        let durationMs = track.durationMs ?? playerDurationMs()
        task = Task {
            let result = await fetcher.fetch(track, durationMs: durationMs, current: baseline)
            guard !Task.isCancelled, self.track?.videoId == track.videoId else { return }
            finishSearch(track.videoId, baseline: baseline, result)
        }
    }

    private func finishSearch(_ videoId: String, baseline: StoredLyrics?, _ result: LyricsFetchResult) {
        if result.anyFailure, result.synced == nil, result.plain == nil {
            state = hasAny ? .loaded : .offline
            return
        }
        // Итог ложится поверх строки, какой она стала за время поиска: свой, выбранный и пришедший с сервера текст не
        // затирается («искали, не нашли» — пустая сторона, чтобы не искать снова, как у Windows)
        let merged = store.map { $0.saveFetched(videoId, baseline: baseline, found: result.found) }
            ?? LyricsRules.mergeFetched(baseline: baseline, current: content.stored, found: result.found)
        setContent(merged)
        state = hasAny ? .loaded : .notFound
    }

    /// Строка текста этого трека изменилась не здесь — синк принёс версию с другого устройства или надгробие.
    private func watch(_ videoId: String) {
        guard let store else { return }
        observation = store.observe(videoId) { [weak self] value in
            self?.storedChanged(videoId, value)
        }
    }

    private func storedChanged(_ videoId: String, _ value: StoredLyrics?) {
        guard track?.videoId == videoId, value != content.stored else { return }
        setContent(value)
        if hasAny {
            state = .loaded
        } else if state != .loading {
            state = .notFound
        }
    }

    private func setContent(_ stored: StoredLyrics?) {
        guard stored != content.stored else { return }
        content = LyricsContent(stored)
    }

    // MARK: - Правки: всегда в трек `videoId`

    /// Сдвиг ±0,1 и ±0,5 с; `nil` — сбросить. Прибавляется к сдвигу, который лежит в базе, а не к показанному.
    public func shift(by delta: Int64?) {
        guard let track else { return }
        let row = store.map { $0.shift(track.videoId, by: delta) } ?? LyricsRules.shifted(content.stored, by: delta)
        if row != nil { setContent(row) }
    }

    /// Текст, выбранный в «Найти текст» (LRCLIB): свой для синка со своим источником `lrclib`. Набранный или
    /// импортированный текст без `replacingTyped` не заменяется — экран спрашивает пользователя.
    @discardableResult
    public func use(synced: String?, plain: String?, for videoId: String, replacingTyped: Bool = false) -> UseResult {
        if let store {
            switch store.choose(videoId, synced: synced, plain: plain, replacingTyped: replacingTyped) {
            case .typedTextKept: return .needsConfirmation
            case .chosen(let row): adopt(videoId, row)
            }
        } else if track?.videoId == videoId {
            guard let row = LyricsRules.choose(current: content.stored, synced: synced, plain: plain, source: LyricsSources.lrclib,
                                               replacingTyped: replacingTyped) else { return .needsConfirmation }
            adopt(videoId, row)
        }
        return .applied
    }

    /// Свой текст: импорт файла (`file`) или редактор (`user`) — синк отправит его на сервер.
    public func saveOwn(videoId: String, synced: String?, plain: String?, source: String, language: String? = nil) {
        if let store {
            adopt(videoId, store.saveOwn(videoId, synced: synced, plain: plain, source: source, language: language))
        } else if track?.videoId == videoId {
            adopt(videoId, LyricsRules.saveOwn(current: content.stored, synced: synced, plain: plain, source: source, language: language))
        }
    }

    /// Импорт `.lrc`, `.ttml` или простого текста в трек `videoId`.
    @discardableResult
    public func importFile(_ text: String, for videoId: String) -> Bool {
        switch LyricsFormats.detect(text) {
        case .ttml, .lrc:
            guard LyricsFormats.parseSynced(text) != nil else { return false }
            saveOwn(videoId: videoId, synced: text, plain: nil, source: LyricsSources.file)
        case .plain:
            guard text.nilIfBlank != nil else { return false }
            saveOwn(videoId: videoId, synced: nil, plain: text, source: LyricsSources.file)
        }
        return true
    }

    /// Записанное — на экран, если это текст того трека, что показан (у другого трека экрана нет).
    private func adopt(_ videoId: String, _ row: StoredLyrics?) {
        guard track?.videoId == videoId else { return }
        setContent(row)
        state = hasAny ? .loaded : .notFound
    }
}
