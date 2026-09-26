import AVFoundation
import Foundation
import Observation
import MelogoldCore
import MelogoldData
import MelogoldInnerTube

/// Плеер Melogold (docs/PROMPT.md §4) — свой движок на `AVSampleBufferAudioRenderer`: DASH-m4a YouTube разбирается
/// по фрагментам, звук начинается после первого фрагмента, длительность честная. Очередь — по своим правилам.
///
/// - треки лежат на одной шкале синхронизатора отрезками: следующий подаётся сразу за текущим — переход без паузы;
/// - адреса двух следующих треков резолвятся заранее (быстрый старт, REWRITE §4.10.2);
/// - ошибка потока: повторы по классу ошибки, затем пропуск; после трёх пропусков подряд воспроизведение встаёт;
/// - одинаково на iPhone, iPad, Mac, Vision и часах (на часах без кэша потока).
@MainActor
@Observable
public final class PlayerEngine {
    public private(set) var items: [QueueItem] = []
    public private(set) var index: Int?
    public private(set) var phase: PlaybackPhase = .idle
    public private(set) var failure: PlaybackFailure?
    /// Прошедшее время текущего трека, секунды.
    public private(set) var position: Double = 0
    /// Настоящая длительность текущего трека, секунды (0 — ещё неизвестна).
    public private(set) var duration: Double = 0
    /// Когда начали получать поток — для подписей «Получаем поток…» (3 с) и «Долго… · Пропустить» (15 с).
    public private(set) var loadingSince: Date?
    /// Трек текущего элемента целиком в кэше (метка «Есть без сети»).
    public private(set) var playingFromCache = false
    /// Последний пропуск трека — для плашки.
    public var notice: PlayerNotice?
    /// Время от нажатия до звука у последнего старта, секунды (приёмка среза 2).
    public private(set) var lastStartLatency: TimeInterval?
    public var repeatMode: RepeatMode = .off
    public var autoplayEnabled = true
    /// Скорость 0,5–2×, тон не меняется (`AppSettings.speed`).
    public var speed: Float = 1 {
        didSet {
            if phase == .playing { pipeline.setRate(speed) }
            syncNowPlaying()
        }
    }
    /// Нормализация громкости по `loudnessDb`: громкие треки тише (`playback.normalization`).
    public var normalization = true {
        didSet { applyVolume() }
    }
    /// Громкость плеера (ползунок на Mac); системная громкость — отдельно.
    public var volume: Float = 1 {
        didSet { applyVolume() }
    }

    public var current: QueueItem? { index.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    public var currentTrack: Track? { current?.track }
    public var isPlaying: Bool { wantsToPlay && (phase == .playing || phase == .loading) }
    public var hasNext: Bool { index.map { $0 + 1 < items.count } ?? false }
    /// Меняется при замене очереди: фоновая дозагрузка списка (плейлист длиннее первой страницы) дописывает треки,
    /// только пока очередь та же (REWRITE §3.8.2).
    public private(set) var queueId = UUID()

    let catalog: YouTubeMusic
    let resolver: StreamResolver
    let cache: AudioCache?
    let session: URLSession
    let pipeline = RenderPipeline()
    let audioSession = AudioSessionController()
    private let nowPlaying = NowPlayingCenter()

    /// Трек на шкале синхронизатора.
    private final class Segment {
        let item: QueueItem
        let reader: TrackReader
        let start: CMTime
        var end: CMTime?
        var duration: Double = 0
        var loudnessDb: Double?
        var fromCache = false
        /// Начать не с начала (ссылка с `t=`): секунды от начала трека.
        var startOffset: Double = 0
        var producer: Task<Void, Never>?

        init(item: QueueItem, reader: TrackReader, start: CMTime) {
            self.item = item
            self.reader = reader
            self.start = start
        }
    }

    private var segments: [Segment] = []
    private var generation = 0
    private var wantsToPlay = false
    private var consecutiveSkips = 0
    private var attempts: [UUID: Int] = [:]
    private var tapTime: Date?
    private var ticker: Task<Void, Never>?
    private var radio: RadioState?
    private var radioTask: Task<Void, Never>?
    /// Читать вперёд не больше стольких секунд — память и трафик.
    private static let readAhead: Double = 40
    /// Сколько звука нужно в запасе, чтобы начать или продолжить после паузы на загрузку.
    private static let startBuffer: Double = 0.6

    struct RadioState {
        var seedVideoId: String
        var playlistId: String?
        var continuation: String?
        var loading = false
    }

    public init(catalog: YouTubeMusic, resolver: StreamResolver, cache: AudioCache?) {
        self.catalog = catalog
        self.resolver = resolver
        self.cache = cache
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        HTTPConfiguration.apply(to: configuration)
        session = URLSession(configuration: configuration)
        audioSession.onInterruptionEnded = { [weak self] shouldResume in
            if shouldResume { self?.play() }
        }
        audioSession.onRouteLost = { [weak self] in self?.pause() }
        nowPlaying.install(self)
    }

    // MARK: - Очередь

    /// Нажатие по треку в списке: очередь — весь список, начиная с выбранного (REWRITE §2.3).
    public func play(tracks: [Track], startAt: Int) {
        guard tracks.indices.contains(startAt) else { return }
        radioTask?.cancel()
        radio = nil
        items = tracks.map { QueueItem(track: $0) }
        index = startAt
        queueId = UUID()
        startCurrent(tapped: true)
    }

    /// Нажатие по одиночному треку: трек и радио по нему (автовоспроизведение похожих). `seconds` — стартовая
    /// позиция (ссылка с `t=`).
    public func playSingle(_ track: Track, from seconds: Double = 0) {
        radioTask?.cancel()
        items = [QueueItem(track: track)]
        index = 0
        queueId = UUID()
        radio = RadioState(seedVideoId: track.videoId, playlistId: "RDAMVM" + track.videoId)
        startCurrent(tapped: true, from: seconds)
        loadRadio()
    }

    /// Радио плейлиста или микса (`RD…`): очередь «Далее» этого списка с первого трека.
    public func playRadio(playlistId: String, seed: Track) {
        radioTask?.cancel()
        items = [QueueItem(track: seed)]
        index = 0
        queueId = UUID()
        radio = RadioState(seedVideoId: seed.videoId, playlistId: playlistId)
        startCurrent(tapped: true)
        loadRadio()
    }

    /// «Играть следующим»: сразу после текущего (REWRITE §2.3). Пустая очередь — играть.
    public func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index, !items.isEmpty else {
            play(tracks: tracks, startAt: 0)
            return
        }
        items.insert(contentsOf: tracks.map { QueueItem(track: $0) }, at: index + 1)
        upcomingChanged()
    }

    /// «В конец очереди»: перед блоком автовоспроизведения. Пустая очередь — играть.
    public func enqueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index, !items.isEmpty else {
            play(tracks: tracks, startAt: 0)
            return
        }
        let firstAutoplay = items.indices.dropFirst(index + 1).first { items[$0].fromAutoplay } ?? items.count
        items.insert(contentsOf: tracks.map { QueueItem(track: $0) }, at: firstAutoplay)
        upcomingChanged()
    }

    /// Дозагруженные треки списка — в конец, если очередь с тех пор не заменили. `false` — заменили, дальше не грузить.
    @discardableResult
    public func append(_ tracks: [Track], toQueue id: UUID) -> Bool {
        guard id == queueId else { return false }
        let known = Set(items.map(\.track.videoId))
        let fresh = tracks.filter { !known.contains($0.videoId) }
        guard !fresh.isEmpty else { return true }
        let wasLast = index.map { $0 + 1 >= items.count } ?? false
        items.append(contentsOf: fresh.map { QueueItem(track: $0) })
        if wasLast { upcomingChanged() }
        return true
    }

    /// Перейти к элементу очереди.
    public func jump(to itemId: UUID) {
        guard let target = items.firstIndex(where: { $0.id == itemId }) else { return }
        index = target
        startCurrent(tapped: true)
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard current != nil else { return }
        if phase == .failed {
            retryCurrent()
            return
        }
        wantsToPlay = true
        Task {
            guard await audioSession.activate() else {
                wantsToPlay = false
                fail(PlaybackFailure(kind: .noAudioRoute, videoId: currentTrack?.videoId))
                return
            }
            if bufferedAhead >= Self.startBuffer || currentSegment?.end != nil {
                pipeline.setRate(speed)
                phase = .playing
            } else {
                phase = .loading
                loadingSince = Date()
            }
            startTicker()
            syncNowPlaying()
        }
    }

    public func pause() {
        wantsToPlay = false
        pipeline.setRate(0)
        if phase != .failed, phase != .idle { phase = .paused }
        syncNowPlaying()
    }

    /// Остановить и очистить очередь.
    public func stop() {
        wantsToPlay = false
        cancelProducers()
        generation = pipeline.reset(to: .zero)
        segments = []
        items = []
        index = nil
        phase = .idle
        failure = nil
        position = 0
        duration = 0
        radioTask?.cancel()
        radio = nil
        ticker?.cancel()
        ticker = nil
        syncNowPlaying()
    }

    public func next() {
        guard let index else { return }
        if index + 1 < items.count {
            self.index = index + 1
            startCurrent(tapped: true)
        } else if repeatMode == .all, !items.isEmpty {
            self.index = 0
            startCurrent(tapped: true)
        }
    }

    /// «Предыдущий»: с позиции больше 3 с — в начало трека (REWRITE §4.10.4).
    public func previous() {
        guard let index else { return }
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            self.index = index - 1
            startCurrent(tapped: true)
        }
    }

    /// Перемотка внутри текущего трека: с фрагмента, где лежит это время.
    public func seek(to seconds: Double) {
        guard let segment = currentSegment else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 0.3) : seconds)
        cancelProducers()
        segments = [segment]
        segment.end = nil
        let time = CMTimeAdd(segment.start, CMTime(seconds: target, preferredTimescale: 44_100))
        generation = pipeline.reset(to: time)
        position = target
        if wantsToPlay {
            phase = .loading
            loadingSince = Date()
        }
        Task {
            let fragment = await segment.reader.fragment(at: target)
            produce(segment, from: fragment, trimBefore: time)
        }
        syncNowPlaying()
    }

    /// Карточка ошибки › «Повторить».
    public func retryCurrent() {
        guard let current else { return }
        failure = nil
        consecutiveSkips = 0
        attempts[current.id] = 0
        Task { await resolver.invalidate(current.track.videoId) }
        startCurrent(tapped: true)
    }

    // MARK: - Старт трека

    private var currentSegment: Segment? {
        segments.first { $0.item.id == current?.id }
    }

    private var bufferedAhead: Double {
        (pipeline.enqueuedEnd - pipeline.currentTime).seconds
    }

    /// Начать текущий элемент заново: шкала с нуля, первый фрагмент, звук как только он есть.
    private func startCurrent(tapped: Bool, from offset: Double = 0) {
        guard let current else { return }
        if tapped { tapTime = Date() }
        wantsToPlay = true
        failure = nil
        phase = .loading
        loadingSince = Date()
        position = max(0, offset)
        duration = Double(current.track.durationMs ?? 0) / 1000
        playingFromCache = cache?.isComplete(current.track.videoId) ?? false
        cancelProducers()
        let startTime = CMTime(seconds: max(0, offset), preferredTimescale: 44_100)
        generation = pipeline.reset(to: startTime)
        let segment = makeSegment(for: current, start: .zero)
        segment.startOffset = max(0, offset)
        segments = [segment]
        protectCache()
        applyVolume()
        syncNowPlaying()
        startTicker()
        Task {
            guard await audioSession.activate() else {
                wantsToPlay = false
                fail(PlaybackFailure(kind: .noAudioRoute, videoId: current.track.videoId))
                return
            }
            guard self.current?.id == current.id else { return }
            produce(segment, from: 0, trimBefore: offset > 0 ? startTime : nil)
            prefetch()
        }
    }

    private func makeSegment(for item: QueueItem, start: CMTime) -> Segment {
        let source = StreamSource(videoId: item.track.videoId, resolver: resolver, cache: cache, session: session)
        return Segment(item: item, reader: TrackReader(source: source), start: start)
    }

    /// Подавать фрагменты трека рендереру, не дальше `readAhead` секунд вперёд. В конце — следующий трек сразу
    /// за этим на той же шкале (переход без паузы).
    private func produce(_ segment: Segment, from firstFragment: Int, trimBefore: CMTime?) {
        segment.producer?.cancel()
        let generation = generation
        segment.producer = Task { [weak self] in
            guard let self else { return }
            do {
                let timing = try await segment.reader.open()
                let content = try await segment.reader.source.contentInfo()
                segment.duration = timing.duration > 0 ? timing.duration : Double(content.durationMs ?? 0) / 1000
                segment.loudnessDb = content.loudnessDb
                segment.fromCache = content.fromCache
                if segment.item.id == self.current?.id {
                    if segment.duration > 0 { self.duration = segment.duration }
                    self.playingFromCache = content.fromCache
                    self.applyVolume()
                    self.syncNowPlaying()
                }
                var trim = trimBefore
                var first = firstFragment
                if segment.startOffset > 0 {
                    first = await segment.reader.fragment(at: segment.startOffset)
                    segment.startOffset = 0
                }
                for number in first..<timing.fragmentCount {
                    try Task.checkCancellation()
                    // Не читать слишком далеко вперёд.
                    while (self.pipeline.enqueuedEnd - self.pipeline.currentTime).seconds > Self.readAhead {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let batch = try await segment.reader.batch(number, start: segment.start, trimBefore: trim)
                    trim = nil
                    // Отрезок сняли со шкалы (очередь изменилась), пока читался фрагмент.
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    self.pipeline.append(batch, generation: generation)
                    if number == timing.fragmentCount - 1 { segment.end = batch.end }
                }
                guard generation == self.generation else { return }
                if segment.end == nil { segment.end = self.pipeline.enqueuedEnd }
                self.segmentFinished(segment)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                let streamError = error as? StreamError ?? StreamError(.extractor, "\(error)")
                self.handleFailure(of: segment.item, error: streamError)
            }
        }
    }

    /// Трек подан целиком: подать следующий сразу за ним (не при повторе трека).
    private func segmentFinished(_ segment: Segment) {
        guard repeatMode != .one, let end = segment.end,
              let position = items.firstIndex(where: { $0.id == segment.item.id }), position + 1 < items.count,
              !segments.contains(where: { $0.item.id == items[position + 1].id }) else { return }
        let next = makeSegment(for: items[position + 1], start: end)
        segments.append(next)
        produce(next, from: 0, trimBefore: nil)
    }

    /// Очередь после текущего трека изменилась. Если на шкале уже стоит прежний следующий трек — снять его
    /// (рендерер отбрасывает отсчёты после конца текущего) и подать настоящий следующий.
    private func upcomingChanged() {
        defer {
            protectCache()
            prefetch()
        }
        guard let segment = currentSegment,
              let position = items.firstIndex(where: { $0.id == segment.item.id }) else { return }
        let stale = segments.filter { $0 !== segment }
        let expectedNext = position + 1 < items.count ? items[position + 1].id : nil
        if stale.isEmpty {
            if segment.end != nil { segmentFinished(segment) }
            return
        }
        if stale.count == 1, stale[0].item.id == expectedNext { return }
        for old in stale { old.producer?.cancel() }
        segments = [segment]
        guard let end = segment.end else { return }
        let generation = generation
        Task {
            let truncated = await pipeline.truncate(from: end)
            guard generation == self.generation, self.currentSegment === segment else { return }
            if truncated {
                segmentFinished(segment)
            } else {
                // Граница уже слишком близко: следующий трек начнётся обычным стартом после конца текущего.
                Log.info("player", "Очередь изменилась у самой границы трека")
            }
        }
    }

    /// Адреса двух следующих треков — заранее, в фоне.
    private func prefetch() {
        guard let index else { return }
        let upcoming = items.dropFirst(index + 1).prefix(2).map(\.track.videoId)
        for videoId in upcoming where !(cache?.isComplete(videoId) ?? false) {
            Task.detached(priority: .utility) { [resolver] in _ = try? await resolver.resolve(videoId) }
        }
    }

    private func protectCache() {
        guard let index else { return }
        cache?.setProtected(Set(items.dropFirst(index).prefix(2).map(\.track.videoId)))
    }

    private func cancelProducers() {
        for segment in segments { segment.producer?.cancel() }
    }

    // MARK: - Часы

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Раз в 100 мс: позиция, смена трека на шкале, ожидание данных, конец очереди.
    private func tick() {
        guard current != nil, phase != .idle, phase != .failed else { return }
        let now = pipeline.currentTime

        // Шкала перешла на следующий отрезок — сменился текущий трек.
        if let playing = segments.last(where: { CMTimeCompare(now, $0.start) >= 0 }), playing.item.id != current?.id,
           let newIndex = items.firstIndex(where: { $0.id == playing.item.id }) {
            index = newIndex
            trackChanged(to: playing)
        }
        guard let segment = currentSegment else { return }
        position = min(max(0, (now - segment.start).seconds), max(duration, 0))

        if wantsToPlay {
            let ahead = bufferedAhead
            let lastFed = segments.last?.end != nil && segments.last === segment
            if phase == .loading, ahead >= Self.startBuffer || (segment.end != nil && ahead > 0.05) {
                pipeline.setRate(speed)
                phase = .playing
                loadingSince = nil
                consecutiveSkips = 0
                if let tapTime {
                    let latency = Date().timeIntervalSince(tapTime)
                    lastStartLatency = latency
                    Log.info("player", "Старт «\(currentTrack?.title ?? "")»: \(Int(latency * 1000)) мс\(playingFromCache ? " (из кэша)" : "")")
                    self.tapTime = nil
                }
                syncNowPlaying()
            } else if phase == .playing, ahead < 0.1, !lastFed {
                // Данные не успевают — ждать, не играя тишину.
                pipeline.setRate(0)
                phase = .loading
                loadingSince = Date()
                syncNowPlaying()
            }
        }

        // Конец трека без следующего на шкале.
        if phase == .playing, let end = segment.end, CMTimeCompare(now, end) >= 0, segments.last === segment {
            finishedLast(segment)
        }
    }

    private func trackChanged(to segment: Segment) {
        duration = segment.duration > 0 ? segment.duration : Double(segment.item.track.durationMs ?? 0) / 1000
        position = 0
        playingFromCache = segment.fromCache
        segments.removeAll { CMTimeCompare($0.start, segment.start) < 0 }
        consecutiveSkips = 0
        protectCache()
        applyVolume()
        syncNowPlaying()
        prefetch()
        maybeExtendRadio()
        // Следующий трек подаётся, как только этот подан целиком.
        if segment.end != nil { segmentFinished(segment) }
    }

    /// Последний отрезок доиграл.
    private func finishedLast(_ segment: Segment) {
        if repeatMode == .one {
            seek(to: 0)
            return
        }
        guard let index else { return }
        if index + 1 < items.count {
            // Следующий не успел встать на шкалу (ошибка или очередь выросла) — начать его обычным стартом.
            self.index = index + 1
            startCurrent(tapped: false)
        } else if repeatMode == .all, !items.isEmpty {
            self.index = 0
            startCurrent(tapped: false)
        } else {
            // Конец очереди: остановка на последнем треке в позиции 0 (REWRITE §4.10.4).
            wantsToPlay = false
            seek(to: 0)
            phase = .paused
            syncNowPlaying()
        }
    }

    // MARK: - Ошибки и пропуски

    private func handleFailure(of element: QueueItem, error: StreamError) {
        Log.warning("player", "«\(element.track.title)» (\(element.track.videoId)): \(error)")
        guard element.id == current?.id else {
            // Следующий трек не подготовился — попробуем, когда до него дойдёт очередь.
            segments.removeAll { $0.item.id == element.id }
            return
        }
        let tries = attempts[element.id, default: 0]
        if !error.isFinal, tries < error.retries {
            attempts[element.id] = tries + 1
            startCurrent(tapped: false)
            return
        }
        skip(element, reason: PlaybackFailure(error, videoId: element.track.videoId))
    }

    /// Пропуск трека с причиной; после трёх подряд воспроизведение встаёт с карточкой (REWRITE §3.10.9).
    private func skip(_ element: QueueItem, reason: PlaybackFailure) {
        consecutiveSkips += 1
        notice = PlayerNotice(skippedTitle: element.track.title, reason: reason.kind)
        guard consecutiveSkips < 3, let index, index + 1 < items.count else {
            wantsToPlay = false
            fail(consecutiveSkips >= 3 ? PlaybackFailure(kind: .manySkips, videoId: element.track.videoId) : reason)
            return
        }
        self.index = index + 1
        startCurrent(tapped: false)
    }

    private func fail(_ reason: PlaybackFailure) {
        pipeline.setRate(0)
        failure = reason
        phase = .failed
        loadingSince = nil
        syncNowPlaying()
    }

    // MARK: - Громкость и система

    /// Громкие треки тише (`loudnessDb` > 0). Тихие не усиливаются: громкость рендерера — не больше 1.
    private func applyVolume() {
        var gain: Float = 1
        if normalization, let loudness = currentSegment?.loudnessDb, loudness > 0 {
            gain = Float(pow(10, -loudness / 20))
        }
        pipeline.volume = max(0, min(1, volume * gain))
    }

    /// Карточка системного «Сейчас играет»: при смене трека, паузе, перемотке и скорости.
    private func syncNowPlaying() {
        nowPlaying.update(track: currentTrack, duration: duration, position: position,
                          playing: phase == .playing, rate: speed)
    }

    // MARK: - Радио

    private func loadRadio() {
        guard autoplayEnabled, var state = radio, !state.loading else { return }
        state.loading = true
        radio = state
        radioTask = Task { [catalog] in
            do {
                let page: NextPage
                if let token = state.continuation {
                    page = try await catalog.nextContinuation(token, playlistId: state.playlistId)
                } else {
                    page = try await catalog.next(videoId: state.seedVideoId, playlistId: state.playlistId)
                }
                guard !Task.isCancelled else { return }
                let known = Set(items.map(\.track.videoId))
                let fresh = page.tracks.filter { !known.contains($0.videoId) && !$0.unavailable }.prefix(25)
                items.append(contentsOf: fresh.map { QueueItem(track: $0, fromAutoplay: true) })
                radio?.continuation = page.continuation
                radio?.playlistId = page.playlistId ?? state.playlistId
                radio?.loading = false
                if let segment = currentSegment, segment.end != nil { segmentFinished(segment) }
                prefetch()
            } catch {
                radio?.loading = false
                Log.info("player", "Радио не догрузилось: \(error)")
            }
        }
    }

    /// Впереди осталось три трека автовоспроизведения или меньше — догрузить (REWRITE §4.10.5).
    private func maybeExtendRadio() {
        guard let index, radio != nil else { return }
        if items.count - index - 1 <= 3 { loadRadio() }
    }
}
