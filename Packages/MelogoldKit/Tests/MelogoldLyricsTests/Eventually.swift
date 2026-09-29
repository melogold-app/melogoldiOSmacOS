import Foundation
import Testing

/// Ждёт условия до двух секунд: значения наблюдения базы и итог поиска приходят на главный актор с задержкой.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("условие не выполнилось за 2 с")
}
