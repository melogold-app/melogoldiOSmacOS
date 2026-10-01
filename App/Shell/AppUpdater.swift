#if os(macOS)
import Observation
import Sparkle
import SwiftUI
import MelogoldCore

/// Обновления Mac через Sparkle 2 (задание 0004): фид — appcast последнего выпуска GitHub (`SUFeedURL`), подпись EdDSA —
/// ключом `SUPublicEDKey`. Проверка — сама, раз в час (`SUScheduledCheckInterval`); новая версия **скачивается сама** в
/// фоне (`SUAutomaticallyUpdate`), и в главном окне появляется «Вышла версия … · Перезапустить» (`UpdateReadyBanner`):
/// одно нажатие ставит её и перезапускает приложение. Не нажали — версия встанет, когда приложение закроют.
/// Пользователь (2026-10-02): «чтобы было видно сразу на основном экране, что вышла новая версия, и её не надо было самому
/// сначала качать — сразу перезагрузка».
///
/// Без публичного ключа (он появляется вместе с первым выпуском) Sparkle не запускается: такая сборка не может
/// проверить подпись обновления, и «Проверить обновления…» неактивна.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    /// Можно ли проверить сейчас (Sparkle не занят другой проверкой).
    private(set) var canCheck = false
    /// Скачанная и готовая к установке версия: показывается в окне, пока её не поставили.
    private(set) var readyVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var installNow: (() -> Void)?

    private override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !key.isEmpty, !feed.isEmpty else {
            Log.info("updates", "Sparkle выключен: в сборке нет публичного ключа EdDSA")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        #if DEBUG
        // Отладочная сборка сама не проверяет: иначе она предложила бы «обновиться» до выпуска
        controller.updater.automaticallyChecksForUpdates = false
        #else
        // Прежние версии загружали обновление только с согласия (так было записано в настройках Sparkle) — один раз
        // включаем загрузку в фоне; переключателя для неё в приложении нет
        let migrated = "updates.autoDownload.v1"
        if !UserDefaults.standard.bool(forKey: migrated) {
            controller.updater.automaticallyDownloadsUpdates = true
            UserDefaults.standard.set(true, forKey: migrated)
        }
        #endif
        canCheck = controller.updater.canCheckForUpdates
        // Новое значение берётся из самого уведомления: обращаться к `updater` из замыкания KVO (оно не на главном акторе)
        // нельзя
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    #if DEBUG
    /// Отладка: показать полосу «Вышла версия …» без настоящего обновления.
    func debugShowReady(_ version: String) { readyVersion = version }
    #endif

    /// «Перезапустить»: поставить скачанную версию и открыть приложение заново.
    func installAndRelaunch() {
        installNow?()
    }

    // MARK: - SPUUpdaterDelegate

    /// Версия скачана в фоне и встанет при выходе. Берём установку на себя (`true`): в окне — «Перезапустить»; Sparkle всё
    /// равно поставит её при закрытии приложения.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let handler = immediateInstallHandler
        MainActor.assumeIsolated {
            readyVersion = version
            installNow = handler
            Log.info("updates", "Скачана версия \(version): «Перезапустить» в окне")
        }
        return true
    }
}

/// «Вышла версия … · Перезапустить» в главном окне, над панелью воспроизведения.
struct UpdateReadyBanner: View {
    let version: String

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("updates.ready \(version)")
                .font(.callout.weight(.semibold))
            Button("updates.relaunch") { AppUpdater.shared.installAndRelaunch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// Сколько занимает полоса вместе с зазором до капсулы плеера: на столько списки окна получают нижнее поле.
    static let reservedHeight: CGFloat = 44
}

/// «Проверить обновления…» — в меню приложения и в «Настройки › О приложении».
struct CheckForUpdatesButton: View {
    private let updater = AppUpdater.shared

    var body: some View {
        if let version = updater.readyVersion {
            Button("updates.relaunchTo \(version)") { updater.installAndRelaunch() }
        }
        Button("updates.check") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
#endif
