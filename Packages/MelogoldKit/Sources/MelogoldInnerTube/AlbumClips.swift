import Foundation
import MelogoldCore

// Альбом — с песнями, а не с клипами (задания 0029 и 0032; Linux `music.rs`: `prefer_album_audio`, `songs_for_clips`,
// `song_for_clip`, `album_twins`; Windows `YouTubeMusic.PreferAlbumAudio`, `SongForClip`, `AlbumTwinsAsync`).
//
// YouTube Music отдаёт в списке альбома (`browse` `MPREb_…`, WEB_REMIX) клип (`MUSIC_VIDEO_TYPE_OMV`) везде, где у песни
// есть официальное видео или визуализатор, а длительность в строке — песни. 18.10.2026 так у Tyler, The Creator в «CALL ME
// IF YOU GET LOST» все 16 строк оказались клипами: LEMONHEAD показывал 2:11, а играл клип на 1:25 с другим сведением, и
// синхронный текст песни расходился со звуком. Плейлист альбома (`OLAK5uy_…`) несёт сами песни (`MUSIC_VIDEO_TYPE_ATV`) —
// оттуда же берёт треки альбома Android-клиент. Если плейлист пуст (переиздание «The Estate Sale», 20.10.2026), песню
// для клипа ищет поиск «Песни».
extension YouTubeMusic {
    /// Сколько поисков песен для клипов альбома идёт сразу.
    static let songSearchesAtOnce = 8
    /// Длительность песни из поиска может разойтись со строкой альбома на округление.
    static let songDurationSlackMs: Int64 = 2_000

    /// Клипы списка альбома и песни, которыми они заменены: `(id клипа, песня)`. Для починки библиотеки — треков,
    /// сохранённых клипами до задания 0029 (задание 0033 §3). Строки без пары и песни альбома не входят.
    ///
    /// Поиск песни для клипа не прошёл — ошибка, а не «пар нет»: иначе починка решила бы, что менять нечего, и больше к
    /// альбому не вернулась бы. Пустой или не загрузившийся плейлист альбома — не ошибка, если дальше прошёл поиск.
    public func albumTwins(_ browseId: String) async throws -> [(clipId: String, song: Track)] {
        let (details, rows, failed) = try await albumWithRows(browseId)
        if let failed { throw failed }
        return zip(rows, details.tracks).filter { row, song in row != song.videoId }.map { (clipId: $0, song: $1) }
    }

    /// Альбом с песнями вместо клипов, id строк, какими их дал YouTube (в том же порядке), и ошибка запроса, из-за
    /// которой клип остался без пары.
    func albumWithRows(_ browseId: String) async throws -> (details: AlbumDetails, rows: [String], failed: (any Error)?) {
        var details = try Self.parseAlbum(try await client.postJSON(.webRemix, "browse", body: ["browseId": browseId]), browseId: browseId)
        let rows = details.tracks.map(\.videoId)
        let failed = try await Self.replaceClips(
            in: &details,
            playlist: { playlistId, max in try await playlistTracks(playlistId, max: max) },
            search: { query in try await search(query, filter: .songs) }
        )
        return (details, rows, failed)
    }

    /// Клипы альбома — на песни: сначала из плейлиста альбома, оставшиеся — из поиска «Песни». `playlist` и `search` —
    /// запросы к YouTube (в тестах — фикстуры). Возвращает ошибку запроса, из-за которой клип остался клипом.
    ///
    /// Проверка на бота (`blocked`) останавливает всё сразу, как у потока: после неё YouTube в этот раз больше не
    /// спрашивают — ни поиском после плейлиста, ни следующими поисками.
    static func replaceClips(
        in details: inout AlbumDetails,
        playlist: @Sendable (_ playlistId: String, _ max: Int) async throws -> [Track],
        search: @escaping @Sendable (_ query: String) async throws -> ItemsPage
    ) async throws -> (any Error)? {
        let browseId = details.album.browseId
        var failed: (any Error)?
        // Второй запрос — только когда в списке есть клипы: у большинства альбомов их нет.
        if details.tracks.contains(where: isClip), let playlistId = details.album.playlistId {
            do {
                let audio = try await playlist(playlistId, details.tracks.count + 50)
                let swapped = preferAlbumAudio(&details.tracks, audio: audio)
                Log.info("catalog", "Альбом \(browseId): клипов заменено песнями из плейлиста альбома — \(swapped)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Пустой плейлист — тоже ошибка («плейлист пуст»): песни ищет поиск ниже. Без них альбом всё равно
                // открывается — с клипами, как раньше.
                Log.warning("catalog", "Альбом \(browseId): плейлист альбома не загрузился (\(error)), песни ищет поиск")
                failed = error
                if isBotCheck(error) { return failed }
            }
        }
        // Плейлист пуст, не загрузился или сам из клипов: песню для каждого оставшегося клипа ищет поиск. Ошибку плейлиста
        // сменяет итог поиска — иначе альбом с пустым плейлистом чинился бы на каждом запуске.
        if details.tracks.contains(where: isClip) {
            let result = try await songsForClips(&details.tracks, search: search)
            Log.info("catalog", "Альбом \(browseId): клипов заменено песнями из поиска — \(result.swapped)")
            failed = result.failed
        }
        return failed
    }

    /// Песни для клипов, которым не нашлось пары в плейлисте альбома: поиск «Песни» по исполнителям и названию строки,
    /// пара — по `songForClip`. Запросы идут по `songSearchesAtOnce` сразу, чтобы альбом не открывался секундами; итог
    /// разбирается в порядке строк, и один videoId дважды не берётся. Клип без пары остаётся клипом — лучше сыграть клип,
    /// чем чужую песню. Возвращает, сколько заменено, и ошибку запроса, из-за которой клип остался клипом.
    static func songsForClips(
        _ tracks: inout [Track], search: @escaping @Sendable (String) async throws -> ItemsPage
    ) async throws -> (swapped: Int, failed: (any Error)?) {
        let clips = tracks.indices.filter { isClip(tracks[$0]) }
        let queries = clips.map { "\(tracks[$0].artistsText ?? "") \(tracks[$0].title)".trimmingCharacters(in: .whitespaces) }
        let results = await searchAll(queries, search: search)
        try Task.checkCancellation()

        var taken = Set(tracks.map(\.videoId))
        var swapped = 0
        var failed: (any Error)?
        for (index, result) in zip(clips, results) {
            switch result {
            case .success(let page):
                let found = page.items.compactMap(\.track).filter { !taken.contains($0.videoId) }
                guard let song = songForClip(tracks[index], found: found) else { continue }
                taken.insert(song.videoId)
                takeSong(&tracks[index], song)
                swapped += 1
            case .failure(let error):
                Log.warning("catalog", "\(tracks[index].videoId): поиск песни для клипа не прошёл — \(error)")
                failed = error
            }
        }
        return (swapped, failed)
    }

    /// Поиски по `songSearchesAtOnce` сразу; итог — в порядке запросов. После проверки на бота новые поиски не
    /// начинаются: те, что не начались, получают её же ошибку.
    private static func searchAll(
        _ queries: [String], search: @escaping @Sendable (String) async throws -> ItemsPage
    ) async -> [Result<ItemsPage, any Error>] {
        var results = [Result<ItemsPage, any Error>?](repeating: nil, count: queries.count)
        var stop: (any Error)?
        await withTaskGroup(of: (Int, Result<ItemsPage, any Error>).self) { group in
            var next = 0
            func launch() {
                let index = next
                let query = queries[index]
                next += 1
                group.addTask {
                    do {
                        return (index, .success(try await search(query)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            while next < min(queries.count, songSearchesAtOnce) { launch() }
            for await (index, result) in group {
                results[index] = result
                if stop == nil, case .failure(let error) = result, isBotCheck(error) { stop = error }
                if stop == nil, next < queries.count { launch() }
            }
        }
        return results.map { $0 ?? .failure(stop ?? CancellationError()) }
    }

    /// Клипы в списке альбома — на песни из плейлиста альбома. Возвращает, сколько заменено.
    ///
    /// Сопоставление — по месту в списке и названию; если место не сошлось (в плейлисте лишний или недостающий трек),
    /// то по первому свободному треку с тем же названием. Песни альбома и строки без пары не трогаются.
    @discardableResult
    static func preferAlbumAudio(_ tracks: inout [Track], audio: [Track]) -> Int {
        var used = [Bool](repeating: false, count: audio.count)
        var swapped = 0
        for index in tracks.indices where isClip(tracks[index]) {
            let wanted = titleKey(tracks[index].title)
            func fits(_ candidate: Int) -> Bool {
                !used[candidate] && isSong(audio[candidate]) && titleKey(audio[candidate].title) == wanted
            }
            guard let found = audio.indices.contains(index) && fits(index) ? index : audio.indices.first(where: fits) else { continue }
            used[found] = true
            takeSong(&tracks[index], audio[found])
            swapped += 1
        }
        return swapped
    }

    /// Песня для клипа из выдачи поиска «Песни», когда плейлист альбома её не дал: у переиздания Tyler, The Creator «CALL
    /// ME IF YOU GET LOST: The Estate Sale» (2023) плейлист альбома пуст, а очередь по нему — те же клипы (20.10.2026), и
    /// песни есть только у альбома 2021 года.
    ///
    /// Пара — то же название (без учёта регистра и пробелов), хоть один общий исполнитель и длительность строки альбома
    /// ±2 с: в строке стоит длительность песни, а у клипа она своя (LEMONHEAD — 2:11 у песни и 1:26 у клипа, CORSO — 2:27
    /// и 5:32). Без длительности строки пары нет.
    static func songForClip(_ clip: Track, found: [Track]) -> Track? {
        guard let duration = clip.durationMs else { return nil }
        let wanted = titleKey(clip.title)
        return found.first { song in
            guard isSong(song), titleKey(song.title) == wanted, let length = song.durationMs else { return false }
            return abs(length - duration) <= songDurationSlackMs && sharesArtist(clip, song)
        }
    }

    static func isClip(_ track: Track) -> Bool { track.videoType == VideoType.video }

    static func isSong(_ track: Track) -> Bool { track.videoType == VideoType.song }

    /// Ключ сравнения названий и имён: без учёта регистра и лишних пробелов.
    static func titleKey(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Хоть один общий исполнитель: по browseId или по имени (имена исполнителей и подпись целиком).
    static func sharesArtist(_ a: Track, _ b: Track) -> Bool {
        func ids(_ track: Track) -> Set<String> { Set(track.artists.compactMap(\.id)) }
        func names(_ track: Track) -> Set<String> { Set(track.artists.map { titleKey($0.name) } + [track.artistsText].compactMap { $0.map(titleKey) }) }
        return !ids(a).isDisjoint(with: ids(b)) || !names(a).isDisjoint(with: names(b))
    }

    /// Строка альбома играет песню: альбом, название и длительность строки остаются.
    static func takeSong(_ track: inout Track, _ song: Track) {
        track.videoId = song.videoId
        track.videoType = VideoType.song
        if track.durationMs == nil { track.durationMs = song.durationMs }
    }

    /// Проверка на бота или блокировка (HTTP 403/429): после неё YouTube в этот раз больше не спрашивают.
    public static func isBotCheck(_ error: any Error) -> Bool {
        (error as? YouTubeError)?.kind == .blocked
    }
}
