#if DEBUG
import SwiftUI
import MelogoldCore

/// Только отладочная сборка: параметры запуска для проверки на симуляторе без нажатий.
///
///     -MelogoldOpenURL "melogold://server?v=1&url=…"   ссылка идёт в тот же обработчик, что и `onOpenURL`
///     -MelogoldSearch "кино"                            раздел «Поиск» и выдача запроса
///     -MelogoldSearchScope music|youtube                 область выдачи
///     -MelogoldOpenLink "https://youtu.be/…"             ссылка или текст — как вставка в Поиске
///     -MelogoldOpen album:<id>|artist:<id>|playlist:<id>|moods|releases   детальный экран в текущем разделе
///     -MelogoldShowNowPlaying YES                      открыть «Сейчас играет», как только появится трек
///     -MelogoldShowLyrics YES, -MelogoldLyricsEditor YES   вместе с ним — текст и редактор текста
///     -MelogoldShowQueue YES, -MelogoldSleep <мин>       очередь и таймер сна
///     -MelogoldSeedLibrary YES                          пример библиотеки для снимков: лайки, плейлист, история, альбом
///     -MelogoldMiniPlayer YES                            Mac: открыть и окно мини-плеера
enum DebugLaunch {
    /// Пример библиотеки из живого альбома «Группа крови»: лайки, плейлист, прослушивания, сохранённые альбом и
    /// исполнитель. Повторный запуск ничего не дублирует.
    @MainActor
    static func seedLibrary(_ model: AppModel) async {
        guard let library = model.library?.library, library.counts().likes == 0 else { return }
        guard let album = try? await model.services.catalog.album("MPREb_OLmD8O5IYNS") else { return }
        let tracks = album.tracks
        for track in tracks.prefix(5) { library.setLiked(track, true) }
        library.createPlaylist(name: "Дорога", tracks: Array(tracks.suffix(6)))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, track) in tracks.enumerated() {
            for repeatIndex in 0..<(tracks.count - index) {
                library.recordPlay(track, playTimeMs: 200_000, endedAt: now - Int64(index * 3_600_000 + repeatIndex * 86_400_000))
            }
        }
        library.setAlbumSaved(album.album, tracks: tracks, true)
        library.setArtistSaved(ArtistItem(browseId: "UCL9NQ06h7I0CRUcGxPWMtkQ", name: "Кино", thumbnailUrl: nil), true)
    }

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
        if defaults.bool(forKey: "MelogoldSeedLibrary") {
            Task { await seedLibrary(model) }
        }
        if defaults.bool(forKey: "MelogoldShowNowPlaying") || defaults.bool(forKey: "MelogoldShowQueue") {
            Task {
                for _ in 0..<300 where model.services.player.currentTrack == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                model.lyricsVisible = defaults.bool(forKey: "MelogoldShowLyrics")
                model.showNowPlaying = defaults.bool(forKey: "MelogoldShowNowPlaying") && model.services.player.currentTrack != nil
                let minutes = defaults.integer(forKey: "MelogoldSleep")
                if minutes > 0 { model.services.player.setSleepTimer(minutes: minutes) }
                if defaults.bool(forKey: "MelogoldShowQueue") {
                    try? await Task.sleep(for: .seconds(3))
                    model.queueVisible = true
                }
                if defaults.bool(forKey: "MelogoldLyricsEditor") {
                    try? await Task.sleep(for: .seconds(4))
                    model.lyricsEditor = true
                }
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
            case ("favorites", _): .favorites
            case ("history", _): .history
            case ("allTracks", _): .allTracks
            case ("downloads", _): .downloads
            case ("albums", _): .savedAlbums
            case ("artists", _): .savedArtists
            case ("local", let id?): Int64(id).map(Route.localPlaylist)
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

#if os(macOS)
/// `-MelogoldMiniPlayer YES`: окно мини-плеера вместе с главным — для снимка.
struct DebugWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.bool(forKey: "MelogoldMiniPlayer") else { return }
            try? await Task.sleep(for: .seconds(2))
            openWindow(id: "mini")
        }
    }
}
#endif
#endif
