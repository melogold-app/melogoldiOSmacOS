import Foundation
import MelogoldCore
import MelogoldData

/// Op `POST /sync` и то, о чём она: ключ сущности (`like:`, `pl:`, `bm:`, `play:`, `hop:`, `stat:batch`) нужен,
/// чтобы разобрать результат.
struct PendingOp: Sendable, Hashable {
    let key: String
    var op: SyncOp

    var kind: String { op.kind }

    /// Бюджет работы запроса (API §1.9): `videoIds` + `entries` + `tracks`.
    var work: Int { (op.videoIds?.count ?? 0) + (op.entries?.count ?? 0) + (op.tracks?.count ?? 0) }

    /// То, о чём op, — одинаково в следующих проходах, пока здесь ничего не изменилось: без `opId`, `at` и `base`,
    /// которые меняются от прохода к проходу, и без необязательных метаданных треков.
    var content: PendingOp {
        var op = op
        op.opId = ""
        op.at = ""
        op.base = nil
        op.tracks = nil
        return PendingOp(key: key, op: op)
    }
}

/// Ops прохода и библиотека, по которой их построили (`SyncApply.rows` сверяет с ней ответ сервера).
struct SyncBuild: Sendable {
    var ops: [PendingOp]
    var image: LibraryImage
}

/// Ключи `sync_state` (как у Windows `LibrarySync.cs`).
enum SyncStateKey {
    static let binding = "binding"
    static let cursor = "cursor"
    static let needsMerge = "needsMerge"
    static let lastSyncAt = "lastSyncAt"
    static let lyricsRev = "lyricsRev"
    static let historyMerge = "historyMerge"
    static let historyRetryAt = "historyRetryAt"
    /// Свои прослушивания уходят ещё раз после восстановления сервера (тихое слияние, DESIGN §3.14): только в историю,
    /// время — `play.baseline atLeast`, иначе оно задвоится.
    static let historyReplay = "historyReplay"
}

/// Что изменилось здесь с прошлой синхронизации — ops (вариант со снимком, REWRITE §4.12a; Windows `BuildOps`).
/// Работает внутри транзакции записи: новые плейлисты получают `sync_id` здесь же, чтобы повтор после обрыва не создал
/// их на сервере второй раз. Каждая op несёт `base` — курсор снимка (грабли §9 п. 6).
struct SyncOpBuilder {
    /// Сколько последних прослушиваний отправить при первой синхронизации, если сервер не сказал (`limits.history`).
    static let defaultMergeUploadMax = 20_000
    /// Самое долгое прослушивание, которое примет сервер (`play.add`).
    static let maxPlayTimeMs: Int64 = 86_400_000
    static let baselineChunk = 500
    static let nameMax = 200
    /// Время, которое принимает сервер (API §1.5): [2000-01-01, 2100-01-01). Время вне него (сбитые часы устройства,
    /// чужие данные) не отправляется: `at` такой op — сейчас, а неверное `at` отвергло бы весь запрос.
    static let timeRange: Range<Int64> = 946_684_800_000 ..< 4_102_444_800_000

    let now: Int64
    var mergeUploadMax = defaultMergeUploadMax
    var makeId: @Sendable () -> String = { UUID().uuidString.lowercased() }

    init(now: Int64 = EpochMs.now(), mergeUploadMax: Int? = nil) {
        self.now = now
        if let mergeUploadMax, mergeUploadMax > 0 { self.mergeUploadMax = mergeUploadMax }
    }

    func build(_ tx: SyncTx) throws -> SyncBuild {
        let cursor = try tx.state(SyncStateKey.cursor)
        let base = cursor?.isEmpty == false ? cursor : nil
        var ops: [PendingOp] = []
        var image = LibraryImage()

        func make(_ kind: String, _ key: String, at: Int64, opId: String? = nil, _ fill: (inout SyncOp) throws -> Void) rethrows {
            let at = Self.timeRange.contains(at) ? at : now
            var op = SyncOp(opId: opId ?? makeId(), kind: kind, at: IsoTime.string(epochMs: at), base: base)
            try fill(&op)
            ops.append(PendingOp(key: key, op: op))
        }

        // Избранное
        let liked = try tx.likes()
        let likedIds = Set(liked.map(\.track.videoId))
        image.likes = Dictionary(liked.map { ($0.track.videoId, $0.likedAt) }, uniquingKeysWith: { first, _ in first })
        let syncedLikes = try tx.syncedLikes()
        for like in liked where !syncedLikes.contains(like.track.videoId) {
            make("like.set", "like:\(like.track.videoId)", at: like.likedAt) {
                $0.videoId = like.track.videoId
                $0.liked = true
                $0.likedAt = Self.time(like.likedAt)
                $0.tracks = Self.tracks([like.track])
            }
        }
        for videoId in syncedLikes.sorted(by: SortKeys.precedes) where !likedIds.contains(videoId) {
            make("like.set", "like:\(videoId)", at: now) {
                $0.videoId = videoId
                $0.liked = false
            }
        }

        // Плейлисты
        let synced = try tx.syncedPlaylists()
        let playlists = try tx.playlists()
        for playlist in playlists {
            let songs = try tx.playlistVideoIds(playlist.id)
            image.playlists[playlist.id] = PlaylistImage(name: playlist.name, thumbnailUrl: playlist.thumbnailUrl, videoIds: songs)
            guard let syncId = playlist.syncId else {
                let newId = makeId()
                try tx.setPlaylistSyncId(playlist.id, newId)
                image.syncIds[newId] = playlist.id
                try make("playlist.create", "pl:\(newId)", at: now) { try Self.fillPlaylist(&$0, tx, newId, playlist, songs) }
                continue
            }
            image.syncIds[syncId] = playlist.id
            guard let previous = synced[syncId] else {
                // Занят по плану слияния или создан и ещё не подтверждён: import сливает
                try make("playlist.import", "pl:\(syncId)", at: now) { try Self.fillPlaylist(&$0, tx, syncId, playlist, songs) }
                continue
            }
            if previous.name != playlist.name || previous.thumbnailUrl != playlist.thumbnailUrl {
                make("playlist.update", "pl:\(syncId)", at: now) {
                    $0.playlistId = syncId
                    $0.name = Self.playlistName(playlist.name)
                    $0.thumbnailUrl = playlist.thumbnailUrl
                }
            }
            if previous.videoIds != songs {
                for change in PlaylistDiff.changes(before: previous.videoIds, after: songs) {
                    switch change {
                    case .remove(let videoId):
                        make("playlist.item.remove", "pl:\(syncId)", at: now) {
                            $0.playlistId = syncId
                            $0.videoId = videoId
                        }
                    case .add(let videoIds, let after, let before):
                        let metadata = try videoIds.compactMap { try tx.track($0) }
                        make("playlist.items.add", "pl:\(syncId)", at: now) {
                            $0.playlistId = syncId
                            $0.videoIds = videoIds
                            $0.after = after
                            $0.before = before
                            $0.tracks = Self.tracks(metadata)
                        }
                    case .move(let videoId, let after, let before):
                        make("playlist.item.move", "pl:\(syncId)", at: now) {
                            $0.playlistId = syncId
                            $0.videoId = videoId
                            $0.after = after
                            $0.before = before
                        }
                    }
                }
            }
        }
        let present = Set(playlists.compactMap(\.syncId))
        for syncId in synced.keys.sorted(by: SortKeys.precedes) where !present.contains(syncId) {
            make("playlist.delete", "pl:\(syncId)", at: now) { $0.playlistId = syncId }
        }

        // Сохранённые альбомы, исполнители и каналы
        let bookmarks = try tx.bookmarks()
        let bookmarkKeys = Set(bookmarks.map(\.key))
        image.bookmarks = Dictionary(bookmarks.map { ($0.key, $0.bookmarkedAt) }, uniquingKeysWith: { first, _ in first })
        let syncedBookmarks = try tx.syncedBookmarks()
        for bookmark in bookmarks where !syncedBookmarks.contains(bookmark.key) {
            make("bookmark.set", "bm:\(bookmark.key.type):\(bookmark.key.browseId)", at: now) {
                $0.type = bookmark.key.type
                $0.browseId = bookmark.key.browseId
                $0.bookmarked = true
                $0.bookmarkedAt = Self.time(bookmark.bookmarkedAt)
                $0.title = bookmark.title
                $0.subtitle = bookmark.subtitle
                $0.thumbnailUrl = bookmark.thumbnailUrl
                $0.year = bookmark.year
            }
        }
        let removedBookmarks = syncedBookmarks.subtracting(bookmarkKeys).sorted { ($0.type, $0.browseId) < ($1.type, $1.browseId) }
        for key in removedBookmarks {
            make("bookmark.set", "bm:\(key.type):\(key.browseId)", at: now) {
                $0.type = key.type
                $0.browseId = key.browseId
                $0.bookmarked = false
            }
        }

        // История (задание 0002 §3.2)
        let merge = try tx.state(SyncStateKey.historyMerge) == "1"
        let replay = try merge && tx.state(SyncStateKey.historyReplay) == "1"
        let retryAt = try tx.state(SyncStateKey.historyRetryAt).flatMap { Int64($0) } ?? 0
        var plays = try tx.unsentPlays()
        // Время прослушивания вне диапазона API сервер не примет никогда (`at` = `playedAt`): не отправлять
        for play in plays where !Self.timeRange.contains(play.playedAt) { try tx.markPlaySent(play.eventId) }
        plays.removeAll { !Self.timeRange.contains($0.playedAt) }
        if retryAt <= now {
            if merge && plays.count > mergeUploadMax {
                // Старше последних mergeUploadMax — не отправляются: сервер их всё равно не примет
                for old in plays.prefix(plays.count - mergeUploadMax) { try tx.markPlaySent(old.eventId) }
                plays = Array(plays.suffix(mergeUploadMax))
            }
            for play in plays {
                let track = try tx.track(play.videoId)
                make("play.add", "play:\(play.eventId)", at: play.playedAt, opId: play.eventId) {
                    $0.videoId = play.videoId
                    $0.playedAt = IsoTime.string(epochMs: play.playedAt)
                    $0.playTimeMs = min(max(play.playTimeMs, 1), Self.maxPlayTimeMs)
                    $0.history = true
                    $0.playtime = !replay
                    $0.tracks = track.flatMap { Self.tracks([$0]) }
                }
            }
        }
        for record in try tx.historyOps() {
            guard Self.timeRange.contains(record.eventsBefore) else {
                // Сбитые часы: сервер такое действие не примет, а событий до 2000 года у него нет
                try tx.deleteHistoryOp(record.opId)
                continue
            }
            make(record.kind, "hop:\(record.opId)", at: record.eventsBefore, opId: record.opId) {
                if record.kind == "history.forget" {
                    $0.videoId = record.videoId
                    $0.resetTotal = false
                }
                $0.eventsBefore = IsoTime.string(epochMs: record.eventsBefore)
            }
        }
        if merge && plays.isEmpty {
            // Накопленное время — только когда все прослушивания уже на сервере: отложенные лимитом play.add иначе
            // прибавились бы к нему ещё раз
            let totals = try tx.playTotals()
            if totals.isEmpty {
                try tx.setState(SyncStateKey.historyMerge, "0")
                try tx.setState(SyncStateKey.historyReplay, nil)
            }
            var start = 0
            while start < totals.count {
                let chunk = totals[start ..< min(start + Self.baselineChunk, totals.count)]
                make("play.baseline", "stat:batch", at: now) {
                    $0.mode = "atLeast"
                    $0.entries = chunk.map { BaselineEntry(videoId: $0.videoId, totalMs: $0.totalMs) }
                }
                start += Self.baselineChunk
            }
        }
        return SyncBuild(ops: ops, image: image)
    }

    private static func fillPlaylist(_ op: inout SyncOp, _ tx: SyncTx, _ syncId: String, _ playlist: SyncPlaylistRecord, _ songs: [String]) throws {
        op.playlistId = syncId
        op.name = playlistName(playlist.name)
        op.browseId = playlist.browseId
        op.thumbnailUrl = playlist.thumbnailUrl
        op.videoIds = songs
        op.tracks = tracks(try songs.compactMap { try tx.track($0) })
    }

    /// Время для поля op; вне диапазона API — без него (сервер возьмёт время op).
    static func time(_ epochMs: Int64) -> String? {
        timeRange.contains(epochMs) ? IsoTime.string(epochMs: epochMs) : nil
    }

    /// Имя плейлиста для сервера: не длиннее 200 единиц UTF-16, пустое — «—».
    static func playlistName(_ name: String) -> String {
        var result = ""
        var length = 0
        for character in name {
            length += character.utf16.count
            if length > nameMax { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : result
    }

    /// Метаданные треков, о которых говорит op (API §4.8 `tracks`): другие устройства смогут их показать.
    static func tracks(_ records: [SyncTrackRecord]) -> [TrackInput]? {
        let inputs = records.map { track -> TrackInput in
            var input = TrackInput(videoId: track.videoId)
            // Заглушка (название = videoId) — без названия: сервер оставит своё
            input.title = track.metadataStub || track.title == track.videoId ? nil : track.title
            input.artistsText = track.artistsText
            input.artists = track.artists.isEmpty ? nil : track.artists.map { ArtistRefDto(id: $0.id, name: $0.name) }
            input.albumId = track.albumId
            input.albumTitle = track.albumTitle
            input.durationMs = track.durationMs
            input.durationText = track.durationText
            input.thumbnailUrl = track.thumbnailUrl
            input.explicit = track.explicit ? true : nil
            input.videoType = track.videoType
            return input
        }
        return inputs.isEmpty ? nil : inputs
    }
}
