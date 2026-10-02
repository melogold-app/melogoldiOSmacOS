import SwiftUI
import MelogoldCore
import MelogoldPlayback
#if os(iOS)
import Intents
#endif

#if os(macOS)
/// Меню в Dock: ярлыки (Поиск, Избранное, «Перемешать Избранное», Скачанное — как ярлыки значка на Android) и, пока что-то
/// загружено, ⏮ ⏯ ⏭ (docs/PROMPT.md §4 «Система»). Ярлык открывает окно, если его закрыли: музыка от закрытия окна не
/// останавливается, а Dock открывает его снова.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Закрытие окна не завершает приложение: музыка играет дальше, а Dock открывает окно снова. У приложения с одним
    /// `Window` система без этого завершает его вместе с последним окном.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Щелчок по значку в Dock, когда окна нет: открыть главное окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.current?.openMainWindow?() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(shortcut("shortcut.search", "magnifyingglass", .search))
        menu.addItem(shortcut("shortcut.favorites", "heart", .favorites))
        menu.addItem(shortcut("shortcut.shuffleFavorites", "shuffle", .shuffleFavorites))
        menu.addItem(shortcut("shortcut.downloads", "arrow.down.circle", .downloads))
        guard let model = AppModel.current, let track = model.playingTrack else { return menu }
        menu.addItem(.separator())
        let title = NSMenuItem(title: track.title, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(item(String(localized: "player.previous"), #selector(previous)))
        menu.addItem(item(String(localized: model.playingIsPlaying ? "player.pause" : "player.play"), #selector(togglePlay)))
        menu.addItem(item(String(localized: "player.next"), #selector(next)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func shortcut(_ title: String.LocalizationValue, _ symbol: String, _ action: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: #selector(runShortcut(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = ShortcutBox(action)
        return item
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ShortcutBox)?.action else { return }
        NSApp.activate()
        AppModel.current?.openMainWindow?()
        AppModel.current?.perform(action)
    }

    @objc private func togglePlay() { AppModel.current?.togglePlayback() }
    @objc private func next() { AppModel.current?.playbackNext() }
    @objc private func previous() { AppModel.current?.playbackPrevious() }
}

/// `representedObject` меню — объект, а не значение перечисления.
private final class ShortcutBox: NSObject {
    let action: ShortcutAction
    init(_ action: ShortcutAction) { self.action = action }
}
#endif

#if os(iOS)
/// Siri: «Включи … в Melogold» — `INPlayMediaIntent` в самом приложении (docs/PROMPT.md §4 «Система»). Разбор как у
/// Android `VoiceQueryResolver`: лучшая песня, если песен нет — первое видео, дальше трек и радио; пустой запрос
/// продолжает очередь. Для работы нужно право Siri в профиле (задание 0005).
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaHandler() : nil
    }
}

final class PlayMediaHandler: NSObject, INPlayMediaIntentHandling {
    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let query = intent.mediaSearch?.mediaName ?? intent.mediaSearch?.artistName
        let played = await MainActor.run { () -> Task<Bool, Never>? in
            guard let model = AppModel.current else { return nil }
            return Task { await VoiceQuery.play(query, model: model) }
        }
        let ok = await played?.value ?? false
        return INPlayMediaIntentResponse(code: ok ? .success : .failure, userActivity: nil)
    }
}
#endif

/// Голосовой запрос (REWRITE §3.14.3, Android `VoiceQueryResolver`): лучшая песня, если песен нет — первое видео;
/// дальше трек и радио. Пустой запрос продолжает очередь.
@MainActor
enum VoiceQuery {
    static func play(_ query: String?, model: AppModel) async -> Bool {
        let player = model.services.player
        guard let text = query?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            guard player.currentTrack != nil else { return false }
            player.play()
            return true
        }
        let catalog = model.services.catalog
        if let songs = try? await catalog.search(text, filter: .songs), let first = songs.items.compactMap(\.track).first {
            model.play(single: first)
            return true
        }
        if let videos = try? await catalog.searchWeb(text, filter: .videos), let first = videos.items.compactMap(\.track).first {
            model.play(single: first)
            return true
        }
        return false
    }
}
