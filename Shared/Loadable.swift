import Foundation
import MelogoldCore
import MelogoldInnerTube

/// Состояние загрузки части экрана (REWRITE §4.11.3).
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(YouTubeError.Kind)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var failure: YouTubeError.Kind? {
        if case .failed(let kind) = self { return kind }
        return nil
    }
}

extension YouTubeError.Kind {
    /// Класс ошибки для экрана (REWRITE §3.0): сеть, блокировка, разбор, прочее.
    static func of(_ error: any Error) -> YouTubeError.Kind {
        if let error = error as? YouTubeError { return error.kind }
        if error is URLError { return .offline }
        return .unknown
    }
}

/// Загрузка страницы каталога: состояния REWRITE §3.0 и «Повторить».
@MainActor
@Observable
final class PageLoader<Value> {
    private(set) var state: Loadable<Value> = .idle

    var value: Value? { state.value }

    func load(force: Bool = false, _ fetch: @escaping () async throws -> Value) async {
        if !force, state.value != nil { return }
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await fetch())
        } catch is CancellationError {
            if state.value == nil { state = .idle }
        } catch {
            Log.warning("catalog", "Страница не загрузилась: \(error)")
            if state.value == nil { state = .failed(.of(error)) }
        }
    }
}

extension MusicItem {
    var mood: MoodItem? {
        if case .mood(let mood) = self { return mood }
        return nil
    }

    var album: AlbumItem? {
        if case .album(let album) = self { return album }
        return nil
    }
}
