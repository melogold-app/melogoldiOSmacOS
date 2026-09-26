import SwiftUI
import MelogoldCore
import MelogoldPlayback
#if os(iOS)
import Intents
#endif

#if os(macOS)
/// Меню в Dock: ⏮ ⏯ ⏭ (docs/PROMPT.md §4 «Система»).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        do {
            guard let player = AppModel.current?.services.player, player.currentTrack != nil else { return nil }
            let menu = NSMenu()
            if let track = player.currentTrack {
                let title = NSMenuItem(title: track.title, action: nil, keyEquivalent: "")
                title.isEnabled = false
                menu.addItem(title)
                menu.addItem(.separator())
            }
            menu.addItem(item(String(localized: player.isPlaying ? "player.pause" : "player.play"), #selector(togglePlay)))
            menu.addItem(item(String(localized: "player.next"), #selector(next)))
            menu.addItem(item(String(localized: "player.previous"), #selector(previous)))
            return menu
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePlay() { AppModel.current?.services.player.togglePlayPause() }
    @objc private func next() { AppModel.current?.services.player.next() }
    @objc private func previous() { AppModel.current?.services.player.previous() }
}

/// Мини-плеер Mac: обложка, название, ⏮ ⏯ ⏭ — окно поверх остальных.
struct MacMiniPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        HStack(spacing: 12) {
            ArtworkView(url: player.currentTrack?.artworkURL, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? String(localized: "player.nothingPlaying"))
                    .font(.headline)
                    .lineLimit(1)
                PlayerStatusLine(font: .subheadline)
                HStack(spacing: 14) {
                    PreviousButton(size: .body)
                    PlayPauseButton(size: .title3)
                    NextButton(size: .body)
                }
            }
            .frame(width: 200, alignment: .leading)
        }
        .padding(12)
        .fixedSize()
    }
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
