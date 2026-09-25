#if DEBUG
import Foundation

/// Только отладочная сборка: параметры запуска для проверки на симуляторе без нажатий.
///
///     -MelogoldOpenURL "melogold://server?v=1&url=…"   ссылка идёт в тот же обработчик, что и `onOpenURL`
enum DebugLaunch {
    @MainActor
    static func apply(to model: AppModel) {
        if let text = UserDefaults.standard.string(forKey: "MelogoldOpenURL"), let url = URL(string: text) {
            model.handle(url: url)
        }
    }
}
#endif
