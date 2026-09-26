#if DEBUG
import Foundation

/// Только отладочная сборка: параметры запуска для проверки на симуляторе без нажатий.
///
///     -MelogoldOpenURL "melogold://server?v=1&url=…"   ссылка идёт в тот же обработчик, что и `onOpenURL`
///     -MelogoldSearch "кино"                            раздел «Поиск» и выдача запроса
///     -MelogoldSearchScope music|youtube                 область выдачи
///     -MelogoldOpenLink "https://youtu.be/…"             ссылка или текст — как вставка в Поиске
///     -MelogoldOpen album:<id>|artist:<id>|playlist:<id>|moods|releases   детальный экран в текущем разделе
///     -MelogoldShowNowPlaying YES                      открыть «Сейчас играет», как только появится трек
enum DebugLaunch {
    @MainActor
    static func apply(to model: AppModel) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "MelogoldMute") { model.services.player.volume = 0 }
        if let text = defaults.string(forKey: "MelogoldOpenURL"), let url = URL(string: text) {
            model.handle(url: url)
        }
        if let text = defaults.string(forKey: "MelogoldOpenLink") {
            model.openLink(text)
        }
        if defaults.bool(forKey: "MelogoldShowNowPlaying") {
            Task {
                for _ in 0..<300 where model.services.player.currentTrack == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                model.showNowPlaying = model.services.player.currentTrack != nil
            }
        }
        if let target = defaults.string(forKey: "MelogoldOpen") {
            let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
            let route: Route? = switch (parts.first, parts.count > 1 ? parts[1] : nil) {
            case ("album", let id?): .album(id)
            case ("artist", let id?): .artist(id)
            case ("playlist", let id?): .playlist(id)
            case ("moods", _): .moods
            case ("releases", _): .newReleases
            default: nil
            }
            if let route { model.open(route) }
        }
        if let query = defaults.string(forKey: "MelogoldSearch") {
            model.section = .search
            model.searchQuery = query
            model.search.submit(query)
            if let scope = defaults.string(forKey: "MelogoldSearchScope").flatMap(SearchModel.Scope.init(rawValue:)) {
                model.search.scope = scope
            }
            if defaults.bool(forKey: "MelogoldPlayFirst") {
                Task {
                    for _ in 0..<200 {
                        if let track = model.search.all.top?.track ?? model.search.all.music.value?.first?.track {
                            model.play(single: track)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
    }
}
#endif
