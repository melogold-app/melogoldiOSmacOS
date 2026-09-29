import Foundation
import MelogoldCore
import MelogoldInnerTube
import MelogoldLyrics
import Synchronization

/// Цепочка поиска для тестов модели: ответы заданы заранее, а пока `hold()`, поиск «в полёте» — ждёт `release()`.
final class FakeFetcher: LyricsFetching, Sendable {
    struct Call: Sendable {
        let videoId: String
        let current: StoredLyrics?
    }

    private struct State {
        var calls: [Call] = []
        var results: [String: LyricsFetchResult] = [:]
        var held = false
        var finished = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }

    /// Сколько поисков уже вернули ответ (модель разберёт его чуть позже, на главном акторе).
    var finished: Int { state.withLock { $0.finished } }

    /// Что вернёт поиск по треку. Без ответа — «искали, не нашли».
    func answer(_ videoId: String, _ result: LyricsFetchResult) {
        state.withLock { $0.results[videoId] = result }
    }

    /// Поиски, начатые после этого, стоят, пока их не отпустят.
    func hold() {
        state.withLock { $0.held = true }
    }

    func release() {
        let waiters = state.withLock { state in
            state.held = false
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func fetch(_ track: Track, durationMs: Int64, current: StoredLyrics?) async -> LyricsFetchResult {
        state.withLock { $0.calls.append(Call(videoId: track.videoId, current: current)) }
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state in
                if state.held {
                    state.waiters.append(continuation)
                    return false
                }
                return true
            }
            if proceed { continuation.resume() }
        }
        return state.withLock { state in
            state.finished += 1
            if let result = state.results[track.videoId] { return result }
            // Не нашли: стороны, которые уже были, возвращаются как есть
            return LyricsFetchResult(plain: current?.plain, synced: current?.synced, plainSource: current?.plainSource, syncedSource: current?.syncedSource)
        }
    }
}
