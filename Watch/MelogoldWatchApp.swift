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
                    if defaults.bool(forKey: "MelogoldMute") {
                        model.services.player.volume = 0
                        model.services.player.outputMuted = true
                    }
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
                        case ("nowPlaying", _): model.path = [.nowPlaying]
                        case ("more", _): model.path = [.nowPlaying, .playerMore]
                        case ("playTarget", _):
                            model.pendingPlay = WatchModel.PendingPlay(
                                tracks: [Track(videoId: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artistsText: "Rick Astley")],
                                index: 0, single: true)
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
    /// «Ещё» в «Сейчас играет»: ♡, текст, очередь, таймер сна, устройство.
    case playerMore
    /// «Итоги»: минуты и трек месяца (задание 0018).
    case stats
    /// Пульт другого устройства аккаунта (задание 0020): список устройств и управление выбранным.
    case remote
}

/// Состояние приложения часов.
@MainActor
@Observable
final class WatchModel {
    let services: Services
    /// Свой вход: часы в аккаунте — отдельное устройство (§5.6).
    let account: Account
    /// Синк библиотеки, истории и текстов — сам, без iPhone (§5.6): при открытии и пока приложение открыто или играет.
    /// Свои прослушивания часы отправляют сами; История часов показывает прослушивания всех устройств (задание 0002 §3.6).
    let sync: LibrarySync
    /// Пульт другого устройства (задание 0020): часы — только пульт, своё воспроизведение другим не отдают (звук часов —
    /// наушники рядом). Что играет на цели, приходит событием `playback.updated` того же потока событий.
    let remote: RemoteControl
    @ObservationIgnored private var lifecycle: [any NSObjectProtocol] = []
    var path: [WatchRoute] = []
    /// Запрос, который Поиск выполнит при открытии (отладочный запуск `-MelogoldSearch`).
    var pendingQuery: String?

    var settings: AppSettings { services.settings }

    init(services: Services) {
        self.services = services
        self.account = Account(settings: services.settings)
        self.sync = LibrarySync(account: account, library: services.library?.library)
        let remote = RemoteControl(port: account)
        self.remote = remote
        sync.onPlaybackUpdated = { rev, cleared, state in remote.apply(rev: rev, cleared: cleared, state: state) }
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

    /// Что выбрали послушать, пока человек отвечает «Где слушать?»: на часах (AirPods, наушники) или на другом устройстве
    /// аккаунта (пульт). Пользователь (2026-10-02): «кнопка нажать, чтобы играть, — это ещё не всё, нужно выбрать, на чём
    /// играть»: сверху устройства аккаунта, снизу — эти часы с AirPods.
    var pendingPlay: PendingPlay?

    struct PendingPlay: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let index: Int
        /// Одиночный трек из выдачи: на часах — трек и радио (REWRITE §2.3).
        let single: Bool
    }

    /// Нажатие по треку (из выдачи — трек и радио): сначала «Где слушать?».
    func play(single track: Track) {
        requestPlay(PendingPlay(tracks: [track], index: 0, single: true))
    }

    /// Трек из списка: очередь — весь список с этого трека; сначала «Где слушать?».
    func play(_ tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        requestPlay(PendingPlay(tracks: tracks, index: index, single: false))
    }

    private func requestPlay(_ pending: PendingPlay) {
        // Без аккаунта или на сервере без пульта выбирать не из чего — играет на часах
        guard account.isSignedIn, account.supportsRemote else {
            playHere(pending)
            return
        }
        pendingPlay = pending
        // Список — сразу из прошлого ответа, свежий подтягивается в фоне
        Task { await remote.refresh() }
    }

    /// «На часах»: звук идёт в AirPods или другие наушники; нет подключённых — система сама предложит выбрать.
    /// Открывает «Сейчас играет» — мини-плеера на часах нет (§5.6).
    func playHere(_ pending: PendingPlay) {
        pendingPlay = nil
        remote.disconnect()
        if pending.single, let track = pending.tracks.first {
            services.player.playSingle(track)
        } else {
            services.player.play(tracks: pending.tracks, startAt: pending.index)
        }
        path.append(.nowPlaying)
    }

    /// Другое устройство аккаунта: часы становятся его пультом, очередь уходит туда (`play_queue`), открывается пульт.
    func play(_ pending: PendingPlay, on device: RemoteDevice) {
        pendingPlay = nil
        if services.player.isPlaying { services.player.pause() }
        remote.connect(device)
        let queue = pending.tracks.map { TrackInput($0) }
        Task { await remote.playQueue(queue, index: pending.index) }
        path.append(.remote)
    }

    func download(_ track: Track) {
        services.downloads?.download(track)
    }

    /// Трек, как его показывать: со своим названием, исполнителем и альбомом (задание 0014).
    func displayed(_ track: Track) -> Track {
        services.library?.displayed(track) ?? track
    }

    /// «Слушать» и «Перемешать» коллекции.
    func playAll(_ tracks: [Track], shuffled: Bool) {
        let playable = tracks.filter { !$0.unavailable }
        guard !playable.isEmpty else { return }
        play(shuffled ? playable.shuffled() : playable, startAt: 0)
    }
}
