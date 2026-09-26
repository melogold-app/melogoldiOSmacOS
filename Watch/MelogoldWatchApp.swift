import SwiftUI
import WatchKit
import MelogoldCore
import MelogoldData
import MelogoldPlayback
import MelogoldServer

/// Melogold для Apple Watch — самостоятельное приложение (docs/PROMPT.md §5.6): свой вход, поиск, поток,
/// загрузки и синк, без iPhone. Код правил, сети и данных — общий, из MelogoldKit; интерфейс — свой, по HIG watchOS.
@main
struct MelogoldWatchApp: App {
    @State private var model: WatchModel

    init() {
        let paths: AppPaths?
        do {
            let standard = try AppPaths.standard()
            try standard.prepare()
            paths = standard
        } catch {
            paths = nil
        }
        if let paths {
            Log.configure(directory: paths.logs)
            ArtworkSession.configure(directory: paths.artwork)
        }
        #if DEBUG
        HTTPConfiguration.setDebugProxy(UserDefaults.standard.string(forKey: "MelogoldDebugProxy"))
        #endif
        Log.info("app", "Melogold для часов \(AppVersion.current) (\(AppVersion.build)) запущен")
        _model = State(initialValue: WatchModel(services: Services(settings: AppSettings(), paths: paths)))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                #if DEBUG
                .task {
                    let defaults = UserDefaults.standard
                    if defaults.bool(forKey: "MelogoldMute") { model.services.player.volume = 0 }
                    if let query = defaults.string(forKey: "MelogoldSearch") {
                        model.pendingQuery = query
                        model.path = [.section(.search)]
                    }
                    // -MelogoldSeedLibrary YES — пример библиотеки для снимков (как в приложении).
                    if defaults.bool(forKey: "MelogoldSeedLibrary"), let library = model.services.library?.library,
                       library.counts().likes == 0, let album = try? await model.services.catalog.album("MPREb_OLmD8O5IYNS") {
                        for track in album.tracks.prefix(5) { library.setLiked(track, true) }
                        for track in album.tracks { library.recordPlay(track, playTimeMs: 120_000) }
                        library.createPlaylist(name: "Дорога", tracks: Array(album.tracks.suffix(4)))
                    }
                    // -MelogoldPlayVideo <id> — видео по id (кадр видео в корне и «Сейчас играет», задание 0008).
                    if let videoId = defaults.string(forKey: "MelogoldPlayVideo") {
                        let isSong = defaults.bool(forKey: "MelogoldPlaySong")
                        model.services.player.playSingle(isSong
                            ? Track(videoId: videoId, title: "Группа крови", artistsText: "Кино", albumTitle: "Группа крови", durationMs: 285_000,
                                    videoType: VideoType.song)
                            : Track(videoId: videoId, title: videoId, videoType: VideoType.video))
                    }
                    // -MelogoldSleep <мин> — таймер сна.
                    let sleepMinutes = defaults.integer(forKey: "MelogoldSleep")
                    if sleepMinutes > 0 { model.services.player.setSleepTimer(minutes: sleepMinutes) }
                    // -MelogoldOpen trends|new|album:<id>|artist:<id>|playlist:<id>|library|allTracks|settings|lyrics|queue|sleep
                    // — экран для снимка.
                    if let target = defaults.string(forKey: "MelogoldOpen") {
                        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
                        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
                        case ("trends", _): model.path = [.section(.trends)]
                        case ("new", _): model.path = [.section(.new)]
                        case ("album", let id?): model.path = [.album(id)]
                        case ("artist", let id?): model.path = [.artist(id)]
                        case ("playlist", let id?): model.path = [.playlist(id)]
                        case ("library", _): model.path = [.section(.library)]
                        case ("allTracks", _): model.path = [.section(.library), .library(.allTracks)]
                        case ("settings", _): model.path = [.section(.settings)]
                        case ("lyrics", _): model.path = [.nowPlaying, .lyrics]
                        case ("queue", _): model.path = [.nowPlaying, .queue]
                        case ("sleep", _): model.path = [.nowPlaying, .sleepTimer]
                        default: break
                        }
                    }
                }
                #endif
        }
        // Загрузки часов — фоновая сессия URLSession: система будит приложение, когда куски докачаны (§5.6).
        .backgroundTask(.urlSession(BackgroundDownloads.identifier)) {
            await BackgroundDownloads.waitForEvents()
        }
    }
}

/// Куда ведёт строка списка часов.
enum WatchRoute: Hashable {
    case section(AppSection)
    case nowPlaying
    case album(String)
    case artist(String)
    case playlist(String)
    case mood(MoodItem)
    case moods
    case newReleases
    case library(WatchLibraryPage)
    case queue
    case lyrics
    case sleepTimer
}

/// Состояние приложения часов.
@MainActor
@Observable
final class WatchModel {
    let services: Services
    /// Свой вход: часы в аккаунте — отдельное устройство (§5.6).
    let account: Account
    /// Синк библиотеки, истории и текстов — сам, без iPhone (§5.6): при открытии и пока приложение открыто или играет.
    let sync: LibrarySync
    @ObservationIgnored private var lifecycle: [any NSObjectProtocol] = []
    var path: [WatchRoute] = []
    /// Запрос, который Поиск выполнит при открытии (отладочный запуск `-MelogoldSearch`).
    var pendingQuery: String?

    var settings: AppSettings { services.settings }

    init(services: Services) {
        self.services = services
        self.account = Account(settings: services.settings)
        self.sync = LibrarySync(account: account, database: services.database)
        sync.start()
        let lyricsSync = sync
        services.lyricsFetcher.community = { videoId in try await lyricsSync.serverLyrics(videoId) }
        let center = NotificationCenter.default
        let sync = sync
        lifecycle = [
            center.addObserver(forName: WKApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sync.appDidBecomeActive() }
            },
            center.addObserver(forName: WKApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sync.flush() }
            },
        ]
    }

    /// Нажатие по треку: играет по правилу очереди и открывает «Сейчас играет» — мини-плеера на часах нет (§5.6).
    func play(single track: Track) {
        services.player.playSingle(track)
        path.append(.nowPlaying)
    }

    /// Трек из списка: очередь — весь список с этого трека.
    func play(_ tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        services.player.play(tracks: tracks, startAt: index)
        path.append(.nowPlaying)
    }

    func download(_ track: Track) {
        services.downloads?.download(track)
    }

    /// «Слушать» и «Перемешать» коллекции.
    func playAll(_ tracks: [Track], shuffled: Bool) {
        let playable = tracks.filter { !$0.unavailable }
        guard !playable.isEmpty else { return }
        play(shuffled ? playable.shuffled() : playable, startAt: 0)
    }
}
