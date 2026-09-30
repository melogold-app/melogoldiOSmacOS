#if DEBUG
import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldLyrics

/// Только отладочная сборка: параметры запуска для проверки на симуляторе без нажатий.
///
///     -MelogoldOpenURL "melogold://server?v=1&url=…"   ссылка идёт в тот же обработчик, что и `onOpenURL`
///     -MelogoldSearch "кино"                            раздел «Поиск» и выдача запроса
///     -MelogoldSearchScope music|youtube                 область выдачи
///     -MelogoldOpenLink "https://youtu.be/…"             ссылка или текст — как вставка в Поиске
///     -MelogoldOpen album:<id>|artist:<id>|playlist:<id>|moods|releases|diagnostics|licenses|streamInfo|…
///                                                       экран в текущем разделе; аккаунт без входа: server|signIn|register|
///                                                       recover|signInByCode|enterCode|recoveryCode (образец кода)
///     -MelogoldShowNowPlaying YES                      открыть «Сейчас играет», как только появится трек
///     -MelogoldShowLyrics YES, -MelogoldLyricsEditor YES   вместе с ним — текст и редактор текста
///     -MelogoldShowQueue YES, -MelogoldSleep <мин>       очередь и таймер сна
///     -MelogoldSeedLyrics YES|editor                    свой синхронный текст играющему треку: короткая и длинная строка,
///                                                       подпевка, вторая сторона дуэта, перевод, проигрыш 26–34 с; `editor` —
///                                                       обычный текст без времени, первая строка — длинная японская (редактор)
///     -MelogoldSeek <с> [-MelogoldSeekPause YES]        перемотать после старта (и встать на паузу) — снимки без гонки со временем
///     -MelogoldSeedLibrary YES                          пример библиотеки для снимков: лайки, плейлист, история, альбом
///     -MelogoldMiniPlayer YES                            Mac: открыть и окно мини-плеера
///     -MelogoldScript <файл>                             Mac: сценарий (клавиши, меню, щелчки, снимки) — см. `DebugScript`
///     -MelogoldSeedPlays YES                            два своих прослушивания без сети — История и её фильтр
///     -MelogoldSeedStats YES                            14 месяцев прослушиваний без сети — «Итоги» и «Итоги года»
///     -MelogoldOpen stats, -MelogoldOpenWrapped <год>   «Итоги» и «Итоги года» на весь экран
///     -MelogoldOpenRemote YES                           лист «Устройство» (пульт, задание 0020)
///     -MelogoldOpenDetails <videoId>, -MelogoldPreselect <n>   «Сведения о треке»; первые n строк выделены
///     -MelogoldExport <videoId> -MelogoldExportDir <папка>   «Сохранить файлом» без окна: .m4a с тегами ложится в папку
///                                                       (трек — по сети, как при нажатии; звук не играет)
///     -MelogoldSeedDownloads YES                        без сети: любимые треки в разных состояниях загрузки (42 %, скачан,
///                                                       сбой, пауза), трек в кэше и трансляция — кольцо, меню, «Хранилище»
enum DebugLaunch {
    /// Прослушивания за 14 месяцев без сети и без плеера: восемь треков с обложками, вечерний пик, разные исполнители и
    /// альбомы. Повторный запуск ничего не дублирует.
    @MainActor
    static func seedStats(_ model: AppModel) {
        guard let library = model.library?.library, library.playCount() == 0 else { return }
        let catalog: [(id: String, title: String, artist: String, album: String?, albumId: String?)] = [
            ("fJ9rUzIMcZQ", "Bohemian Rhapsody", "Queen", "A Night at the Opera", "MPREb_queen1"),
            ("hTWKbfoikeg", "Smells Like Teen Spirit", "Nirvana", "Nevermind", "MPREb_nirv1"),
            ("dQw4w9WgXcQ", "Never Gonna Give You Up", "Rick Astley", "Whenever You Need Somebody", "MPREb_rick1"),
            ("kJQP7kiw5Fk", "Despacito", "Luis Fonsi", nil, nil),
            ("9bZkp7q19f0", "Gangnam Style", "PSY", nil, nil),
            ("JGwWNGJdvx8", "Shape of You", "Ed Sheeran", "÷", "MPREb_ed1"),
            ("RgKAFK5djSk", "See You Again", "Wiz Khalifa", "Furious 7", "MPREb_wiz1"),
            ("YQHsXMglC9A", "Hello", "Adele", "25", "MPREb_adele1"),
        ]
        let tracks = catalog.map { item in
            Track(videoId: item.id, title: item.title, artists: [ArtistRef(id: "UC_" + item.id, name: item.artist)], artistsText: item.artist,
                  albumId: item.albumId, albumTitle: item.album, durationMs: 240_000,
                  thumbnailUrl: "https://i.ytimg.com/vi/\(item.id)/hqdefault.jpg", videoType: item.album == nil ? VideoType.video : VideoType.song)
        }
        var seed: UInt64 = 20_260_930
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Три прослушивания в день в среднем; любимые треки — те, что в начале списка; пик — вечером
        for back in 0 ..< 425 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            for _ in 0 ..< (next() % 5) {
                // Два последних трека появились недавно: «Открытия» и карточка новых треков в итогах года
                let pool = back < 60 ? tracks.count : tracks.count - 2
                let pick = min(next() % pool, next() % pool)
                let hour = [8, 9, 13, 18, 20, 21, 21, 22, 23][next() % 9]
                guard let at = calendar.date(bySettingHour: hour, minute: next() % 60, second: 0, of: day), at < Date() else { continue }
                let ms = Int64(120_000 + next() % 120_000)
                library.recordPlay(tracks[pick], playTimeMs: ms, endedAt: Int64(at.timeIntervalSince1970 * 1000))
            }
        }
    }

    /// Загрузки в разных состояниях без сети и без звука (задание 0009): «Скачивается 42 %», «Скачано», сбой, пауза, трек
    /// в кэше (12 МБ) и трансляция, которую скачать нельзя. Треки любимые — видны в «Избранном». Строки пишутся через
    /// две секунды после старта: раньше загрузчик при запуске поставил бы «скачивается» обратно в очередь.
    @MainActor
    static func seedDownloads(_ model: AppModel) async {
        guard let library = model.library?.library, let store = model.services.downloads?.store, store.entries().isEmpty else { return }
        try? await Task.sleep(for: .seconds(2))
        func track(_ id: String, _ title: String, _ artist: String, album: String? = nil, type: String = VideoType.song) -> Track {
            Track(videoId: id, title: title, artists: [ArtistRef(id: "UC_" + id, name: artist)], artistsText: artist,
                  albumTitle: album, durationMs: 240_000, thumbnailUrl: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", videoType: type)
        }
        let downloading = track("fJ9rUzIMcZQ", "Bohemian Rhapsody", "Queen", album: "A Night at the Opera")
        let done = track("hTWKbfoikeg", "Smells Like Teen Spirit", "Nirvana", album: "Nevermind")
        let failed = track("dQw4w9WgXcQ", "Never Gonna Give You Up", "Rick Astley", album: "Whenever You Need Somebody")
        let paused = track("kJQP7kiw5Fk", "Despacito", "Luis Fonsi", album: "Vida")
        let cached = track("9bZkp7q19f0", "Gangnam Style", "PSY", type: VideoType.video)
        let plain = track("JGwWNGJdvx8", "Shape of You", "Ed Sheeran", album: "÷")
        let live = track("jfKfPfyJRdk", "lofi hip hop radio - beats to relax/study to", "Lofi Girl", type: VideoType.live)
        for item in [downloading, done, failed, paused, cached, plain, live] { library.setLiked(item, true) }
        for (item, length) in [(downloading, 1000), (done, 100)] as [(Track, Int)] {
            store.requestTrack(item)
            store.prepare(item.videoId, itag: 140, mimeType: "audio/mp4", contentLength: Int64(length), durationMs: 240_000, loudnessDb: nil)
        }
        store.write(downloading.videoId, offset: 0, data: Data(count: 420))
        store.setState(downloading.videoId, .downloading)
        store.write(done.videoId, offset: 0, data: Data(count: 100))
        store.requestTrack(failed)
        store.setState(failed.videoId, .failed, failure: "network")
        store.requestTrack(paused)
        store.setState(paused.videoId, .paused)
        if let cache = model.services.cache {
            let size = 12 << 20
            cache.prepare(videoId: cached.videoId, itag: 140, mimeType: "audio/mp4", contentLength: Int64(size), durationMs: 240_000, loudnessDb: nil)
            cache.write(cached.videoId, offset: 0, data: Data(count: size), total: Int64(size))
            model.refreshCached()
        }
    }

    /// `-MelogoldExport <videoId> -MelogoldExportDir <папка>`: тот же путь, что у «Сохранить файлом», но результат —
    /// в папку, а не в «Музыку». Сведения о треке — образец для проверки тегов и обложки; итог — в журнал.
    @MainActor
    static func exportTrack(_ model: AppModel, videoId: String, directory: URL) async {
        let track = Track(videoId: videoId, title: "Never Gonna Give You Up", artists: [ArtistRef(id: "UCuAXFkgsw1L7xaCfnd5JJOw", name: "Rick Astley")],
                          artistsText: "Rick Astley", albumTitle: "Whenever You Need Somebody", durationMs: 213_000,
                          thumbnailUrl: "https://i.ytimg.com/vi/\(videoId)/hq720.jpg", videoType: VideoType.song)
        do {
            let file = try await FileExport.export(track, services: model.services)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            Log.info("export", "debug: \(target.path)")
        } catch {
            Log.warning("export", "debug: \(error)")
        }
    }

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

    /// Свой синхронный текст играющему треку для снимков «Сейчас играет»: короткая строка (узкая подложка), длинная с
    /// переносом, строка с подпевкой, строка второй стороны дуэта с переводом и проигрыш 26–34 с (подложки нет).
    @MainActor
    static func seedLyrics(_ model: AppModel, track: Track, plainForEditor: Bool = false) {
        if plainForEditor {
            // Для редактора «Синхронизация»: ни одной отметки времени, «Далее» — длинные строки целиком
            let long = "夜空を見上げて 君の名前を呼んだ 遠い街の灯りが 滲んで見える 風に乗せた言葉は どこまで届くのだろう それでも歩き続けるよ 明日の光を信じて"
            let veryLong = Array(repeating: long, count: 5).joined(separator: " ")
            model.services.lyrics.load(track)
            model.services.lyrics.saveOwn(videoId: track.videoId, synced: "", plain: [long, veryLong, "Обычная строка (подпевка)", "Ещё одна строка"].joined(separator: "\n"),
                                          source: LyricsSources.user)
            return
        }
        func line(_ start: Int64, _ end: Int64, _ text: String, side: VocalSide = .start, backing: String? = nil, translation: String? = nil) -> SyncedLine {
            SyncedLine(startMs: start, endMs: end, text: text, agent: side == .end ? "v2" : "v1", side: side,
                       background: backing.map { BackingVocals(startMs: start, endMs: end, words: [SyncedWord(startMs: start, endMs: end, text: $0)]) },
                       translation: translation)
        }
        let lines = [
            line(6_000, 9_000, "Привет"),
            line(9_000, 14_000, "Это очень длинная строка текста песни, которая обязательно не поместится в одну строку и перенесётся на две или даже на три строки"),
            line(14_000, 18_000, "Мягкое кресло, клетчатый плед", backing: "(эхо)"),
            line(18_000, 22_000, "Ответ второго голоса", side: .end),
            line(22_000, 26_000, "Строка с переводом", side: .end, translation: "A line with a translation"),
            line(34_000, 38_000, "После проигрыша"),
            line(38_000, 42_000, "Ещё одна строка"),
            line(42_000, 46_000, "И ещё одна"),
            line(46_000, 50_000, "Последняя строка для прокрутки"),
        ]
        let synced = SyncedLyrics(lines: lines, timing: .line,
                                  agents: [LyricsAgent(id: "v1", side: .start), LyricsAgent(id: "v2", side: .end)])
        model.services.lyrics.load(track)
        model.services.lyrics.saveOwn(videoId: track.videoId, synced: TtmlFormat.write(synced),
                                      plain: lines.map(\.text).joined(separator: "\n"), source: LyricsSources.user)
    }

    /// Два прослушивания этого устройства без сети и без плеера (звук не нужен) — для Истории и фильтра по устройствам
    /// в UI-тестах. Если свои прослушивания уже есть, ничего не пишет.
    @MainActor
    static func seedPlays(_ model: AppModel) {
        guard let library = model.library?.library, library.playCount(device: .thisDevice(currentDeviceId: nil)) == 0 else { return }
        let now = EpochMs.now()
        let tracks = [("fJ9rUzIMcZQ", "Bohemian Rhapsody", "Queen"), ("hTWKbfoikeg", "Smells Like Teen Spirit", "Nirvana")]
        for (index, (videoId, title, artist)) in tracks.enumerated() {
            let track = Track(videoId: videoId, title: title, artistsText: artist, durationMs: 300_000,
                              thumbnailUrl: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg", videoType: VideoType.video)
            library.recordPlay(track, playTimeMs: 240_000, endedAt: now - Int64(index + 1) * 20 * 60_000)
        }
    }

    @MainActor
    static func apply(to model: AppModel) {
        let defaults = UserDefaults.standard
        #if os(macOS)
        // -MelogoldScript <файл> — сценарий проверки окна, меню и клавиш (`DebugScript`)
        DebugScript.runIfRequested(model: model)
        #endif
        if defaults.bool(forKey: "MelogoldMute") {
            model.services.player.volume = 0
            // Жёстко: громкость пульта (задание 0020) и ползунок не включат звук
            model.services.player.outputMuted = true
        }
        if let text = defaults.string(forKey: "MelogoldOpenURL"), let url = URL(string: text) {
            model.handle(url: url)
        }
        if let text = defaults.string(forKey: "MelogoldOpenLink") {
            model.openLink(text)
        }
        // -MelogoldImport <путь к копии> [-MelogoldImportDelay <с>] — импорт без окна выбора файла (снимки хода и итога).
        if let path = defaults.string(forKey: "MelogoldImport") {
            model.importBackup(from: URL(fileURLWithPath: path), debugDelay: .seconds(defaults.integer(forKey: "MelogoldImportDelay")))
        }
        // -MelogoldSaveBackup YES — «Сохранить копию» сразу (снимок окна сохранения)
        if defaults.bool(forKey: "MelogoldSaveBackup") { model.saveBackup() }
        if defaults.bool(forKey: "MelogoldSeedLibrary") {
            Task { await seedLibrary(model) }
        }
        if defaults.bool(forKey: "MelogoldSeedPlays") { seedPlays(model) }
        if defaults.bool(forKey: "MelogoldSeedDownloads") { Task { await seedDownloads(model) } }
        if let videoId = defaults.string(forKey: "MelogoldExport"), let directory = defaults.string(forKey: "MelogoldExportDir") {
            Task { await exportTrack(model, videoId: videoId, directory: URL(fileURLWithPath: directory, isDirectory: true)) }
        }
        if defaults.bool(forKey: "MelogoldSeedStats") { seedStats(model) }
        // -MelogoldOpenDetails <videoId> — лист «Сведения о треке» (снимок; трек уже в библиотеке)
        if let videoId = defaults.string(forKey: "MelogoldOpenDetails"), let track = model.library?.library.track(videoId) {
            model.trackDetails = track
        }
        if defaults.object(forKey: "MelogoldOpenWrapped") != nil { model.wrappedYear = defaults.integer(forKey: "MelogoldOpenWrapped") }
        if defaults.bool(forKey: "MelogoldOpenRemote") { model.remoteSheet = true }
        if defaults.bool(forKey: "MelogoldShowNowPlaying") || defaults.bool(forKey: "MelogoldShowQueue") || defaults.string(forKey: "MelogoldSeedLyrics") != nil {
            Task {
                for _ in 0..<300 where model.services.player.currentTrack == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let seed = defaults.string(forKey: "MelogoldSeedLyrics"), let track = model.services.player.currentTrack {
                    seedLyrics(model, track: track, plainForEditor: seed == "editor")
                }
                model.lyricsVisible = defaults.bool(forKey: "MelogoldShowLyrics")
                model.showNowPlaying = defaults.bool(forKey: "MelogoldShowNowPlaying") && model.services.player.currentTrack != nil
                let minutes = defaults.integer(forKey: "MelogoldSleep")
                if minutes > 0 { model.services.player.setSleepTimer(minutes: minutes) }
                if defaults.bool(forKey: "MelogoldShowQueue") {
                    try? await Task.sleep(for: .seconds(3))
                    model.queueVisible = true
                }
                if defaults.string(forKey: "MelogoldLyricsEditor") != nil {
                    try? await Task.sleep(for: .seconds(4))
                    model.openLyricsEditor()
                }
                if let seconds = defaults.string(forKey: "MelogoldSeek").flatMap(Double.init) {
                    let player = model.services.player
                    // Ждём звук, затем перематываем, пока позиция не встанет (первая перемотка на старте бывает потеряна)
                    for _ in 0..<300 where player.phase != .playing || player.duration <= 0 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    for _ in 0..<20 {
                        if abs(player.position - seconds) < 2 { break }
                        player.seek(to: seconds)
                        try? await Task.sleep(for: .seconds(1))
                    }
                    if defaults.bool(forKey: "MelogoldSeekPause") { player.pause() }
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
            case ("stats", _): .stats
            case ("allTracks", _): .allTracks
            case ("downloads", _): .downloads
            case ("albums", _): .savedAlbums
            case ("artists", _): .savedArtists
            case ("local", let id?): Int64(id).map(Route.localPlaylist)
            case ("diagnostics", _): .diagnostics
            case ("licenses", _): .licenses
            case ("streamInfo", _): .streamInfo
            case ("server", _): .server(prefill: nil, serverId: nil)
            case ("signIn", _): .account(.signIn(login: nil))
            case ("register", _): .account(.register)
            case ("recover", _): .account(.recover(login: nil))
            case ("signInByCode", _): .account(.signInByCode(enterCode: false))
            case ("enterCode", _): .account(.signInByCode(enterCode: true))
            case ("recoveryCode", _): .account(.recoveryCode(code: "K7QX-M2PD-9WVR-4HTC-B6NE-J3YA", createdAt: "2026-09-30T10:00:00Z"))
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
///
/// `-MelogoldMiniBackdrop YES` — и цветной фон под ним: стекло мини-плеера пропускает то, что за окном, а снимок одного окна
/// (`screencapture -l`) рисует стекло на пустом месте ровно серым. Фон — своё окно над обычными окнами (560 × 260 pt, левый
/// верхний угол в (200, 300) экрана), мини-плеер встаёт по его центру; область снимается `screencapture -R 200,300,560,260`,
/// чужих окон в кадре нет (проверять: `CGWindowList` — оба окна на экране, фон полностью закрывает область).
struct DebugWindowOpener: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.bool(forKey: "MelogoldMiniPlayer") else { return }
            try? await Task.sleep(for: .seconds(2))
            MiniPlayerPanel.shared.show(model: model)
            guard UserDefaults.standard.bool(forKey: "MelogoldMiniBackdrop"), let screen = NSScreen.main else { return }
            let frame = NSRect(x: 200, y: screen.frame.height - 300 - 260, width: 560, height: 260)
            // Панель без активации, как сам мини-плеер: окна приложения, запущенного в фоне, система на экран не выводит
            let backdrop = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            backdrop.level = .floating
            backdrop.hidesOnDeactivate = false
            backdrop.isReleasedWhenClosed = false
            backdrop.contentView = NSHostingView(rootView: DebugBackdrop())
            backdrop.orderFrontRegardless()
            MiniPlayerPanel.shared.debugPlace(at: NSPoint(x: frame.midX - 190, y: frame.midY - 56))
            DebugBackdrop.window = backdrop
        }
    }
}

/// Пёстрый фон вместо обоев: градиент и несколько крупных форм, чтобы стекло было видно.
private struct DebugBackdrop: View {
    @MainActor static var window: NSWindow?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple, .pink, .orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.cyan.opacity(0.7)).frame(width: 150).offset(x: -190, y: -70)
            RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.85)).frame(width: 170, height: 70).offset(x: 170, y: 80)
            Circle().fill(.black.opacity(0.6)).frame(width: 90).offset(x: 190, y: -60)
            Text(verbatim: "Liquid Glass backdrop").font(.system(size: 28, weight: .heavy)).foregroundStyle(.white).offset(y: -95)
        }
    }
}
#endif
#endif
