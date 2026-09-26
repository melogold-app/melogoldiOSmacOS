#if os(macOS)
import Observation
import Sparkle
import SwiftUI
import MelogoldCore

/// Обновления Mac через Sparkle 2 (задание 0004): стандартный контроллер со своим окном (у него есть русский перевод),
/// фид — appcast последнего выпуска GitHub (`SUFeedURL`), подпись EdDSA — ключом `SUPublicEDKey`. Проверка идёт сама,
/// не чаще раза в 6 часов; установка — только с согласия пользователя.
///
/// Без публичного ключа (он появляется вместе с первым выпуском) Sparkle не запускается: такая сборка не может
/// проверить подпись обновления, и «Проверить обновления…» неактивна.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Можно ли проверить сейчас (Sparkle не занят другой проверкой).
    private(set) var canCheck = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !key.isEmpty, !feed.isEmpty else {
            controller = nil
            Log.info("updates", "Sparkle выключен: в сборке нет публичного ключа EdDSA")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        #if DEBUG
        // Отладочная сборка сама не проверяет: иначе она предложила бы «обновиться» до выпуска
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// «Проверить обновления…» — в меню приложения и в «Настройки › О приложении».
struct CheckForUpdatesButton: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Button("updates.check") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
#endif
