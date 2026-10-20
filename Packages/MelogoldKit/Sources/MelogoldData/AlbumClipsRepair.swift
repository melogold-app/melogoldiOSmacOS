import Foundation
import MelogoldCore

/// Починка библиотеки (задание 0033 §3; Linux 0030 `album_clips_repair.rs`, Windows 0033 `AlbumClipsRepair`): клипы из
/// альбомов, сохранённые до задания 0029, — на песни.
///
/// До 0029 список альбома давал клипы (`MUSIC_VIDEO_TYPE_OMV`) вместо песен, и то, что человек лайкнул или положил в
/// плейлист из альбома, осталось клипом: LEMONHEAD у Tyler, The Creator играл клип на 1:25 вместо песни на 2:11. Один раз
/// после запуска для каждого альбома с такими клипами берутся пары «клип → песня» тем же путём, что у страницы альбома
/// (плейлист альбома, затем поиск «Песни»), и ♡ и места в плейлистах переходят на песни (`Library.replaceClipWithSong`).
/// Синк разнесёт это по остальным устройствам как обычные правки.
public enum AlbumClipsRepair {
    /// Отметка в `app_state`: починка прошла целиком.
    public static let doneKey = "repair.album_clips"
    /// Не мешать запуску: окно, очередь и первая синхронизация — раньше.
    public static let startDelay: Duration = .seconds(20)

    /// Пары «клип → песня» альбома (`YouTubeMusic.albumTwins`). Ошибка — альбом не загрузился или поиск песни не прошёл:
    /// починка повторится при следующем запуске.
    public typealias Twins = @Sendable (_ albumId: String) async throws -> [(clipId: String, song: Track)]

    /// Что сделано: альбомов с клипами, заменено пар и нужен ли повтор при следующем запуске.
    public struct Outcome: Hashable, Sendable {
        public var albums: Int
        public var replaced: Int
        public var retry: Bool
    }

    /// Один раз: отметка `doneKey` уже есть — сразу `nil`; иначе через `delay` — починка. Отметка ставится, только если
    /// повторять нечего: ни один альбом не сорвался из-за сети или поиска (пустой плейлист альбома — не ошибка, иначе
    /// починка шла бы на каждом запуске). `stopsAll` — ошибка, после которой YouTube в этот запуск больше не спрашивают
    /// (проверка на бота): остальные альбомы ждут следующего запуска.
    @discardableResult
    public static func run(library: Library, delay: Duration = startDelay, twins: Twins,
                           stopsAll: @Sendable (any Error) -> Bool = { _ in false }) async -> Outcome? {
        guard library.state(doneKey) == nil else { return nil }
        do {
            try await Task.sleep(for: delay)
        } catch {
            return nil
        }
        let clips: [Track]
        do {
            clips = try library.savedAlbumClips()
        } catch {
            Log.warning("library", "Починка клипов из альбомов: библиотека не прочиталась — \(error)")
            return nil
        }
        // Альбом → id его клипов в библиотеке
        var albums: [String: Set<String>] = [:]
        for clip in clips {
            if let album = clip.albumId { albums[album, default: []].insert(clip.videoId) }
        }

        var outcome = Outcome(albums: albums.count, replaced: 0, retry: false)
        for (album, ids) in albums.sorted(by: { $0.key < $1.key }) {
            let pairs: [(clipId: String, song: Track)]
            do {
                pairs = try await twins(album)
            } catch {
                // Без сети — в следующий запуск: отметка о готовности не ставится
                Log.warning("library", "Починка клипов: альбом \(album) не загрузился — \(error)")
                outcome.retry = true
                if stopsAll(error) || Task.isCancelled { break }
                continue
            }
            for (clipId, song) in pairs where ids.contains(clipId) {
                do {
                    let what = try library.replaceClipWithSong(clipId, with: song)
                    outcome.replaced += 1
                    Log.info("library", "Клип в библиотеке заменён песней: альбом \(album), клип \(clipId), песня \(song.videoId), "
                        + "♡ \(what.liked), плейлистов \(what.playlists), название \(what.movedOverride), текст \(what.movedPin)")
                } catch {
                    Log.warning("library", "Починка клипов: \(clipId) не заменён — \(error)")
                    outcome.retry = true
                }
            }
        }

        Log.info("library", "Починка клипов из альбомов: альбомов \(outcome.albums), заменено \(outcome.replaced), повторить \(outcome.retry)")
        if !outcome.retry { library.setState(doneKey, "1") }
        return outcome
    }
}
