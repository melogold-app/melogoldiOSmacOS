import Foundation
import MelogoldCore
import MelogoldData

/// Библиотека, какой её видел построитель ops, вместе с тем, что с тех пор записал сам синк. Ключ, который человек
/// изменил, пока шёл запрос, с ней не совпадёт: ответ сервера тогда обновляет только снимок, а правка уходит следующим
/// проходом — вариант со снимком для reapplyPending (DESIGN §3.13.4).
struct LibraryImage: Sendable {
    /// Лайки: `videoId` → время лайка.
    var likes: [String: Int64] = [:]
    var bookmarks: [SyncBookmarkKey: Int64] = [:]
    /// Плейлисты по `id` этого устройства.
    var playlists: [Int64: PlaylistImage] = [:]
    /// `sync_id` плейлистов, которые были здесь при построении, → их `id`.
    var syncIds: [String: Int64] = [:]
    /// Плейлисты, чьи треки правили здесь во время запроса: до конца прохода держат порядок этого устройства.
    var edited: Set<Int64> = []
}

struct PlaylistImage: Sendable, Equatable {
    var name: String
    var thumbnailUrl: String?
    /// Треки по порядку. У плейлиста из `edited` порядок уже не важен — только состав, который ждёт синк.
    var videoIds: [String]
}

/// Треки плейлиста, который держит порядок этого устройства: сервер даёт ключи и чужие правки, свои правки остаются
/// и уйдут следующим проходом.
struct HeldItems: Equatable {
    /// Треки здесь по порядку, с ключами сервера.
    var items: [SyncItemRecord]
    /// Добавлены на сервере (другим устройством): вставить здесь.
    var inserted: [String]
    /// Убраны на сервере, здесь их не трогали: удалить здесь.
    var removed: [String]
    /// Плейлист на сервере по ключам; треки, убранные здесь, но ещё живые на сервере, — в конце (для разницы их место
    /// не важно: они уйдут `item.remove`).
    var snapshot: [String]
}

/// Ответ `POST /sync` → библиотека и снимок (API §4.8). Всё внутри одной транзакции записи.
enum SyncApply {
    /// Результаты ops: плейлист, который сервер перенёс в плейлист восстановления (`redirected`), переходит туда и здесь;
    /// прослушивания и действия с историей, которые сервер принял или отверг, больше не отправляются (задание 0002
    /// §3.2). Возвращает паузу в секундах, если сервер отложил прослушивания (`deferred`, лимит в час).
    static func results(_ tx: SyncTx, batch: [PendingOp], results: [OpResult], now: Int64) throws -> Int? {
        let byId = Dictionary(results.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
        var retry: Int?
        var baselineDone: Bool?
        for pending in batch {
            guard let result = byId[pending.op.opId] else { continue }
            let deferred = result.status == "deferred"
            switch pending.kind {
            case "play.add":
                // applied (и replayed), superseded, rejected — больше не слать; deferred — после паузы
                if deferred {
                    retry = retry ?? max(1, result.retryAfterSeconds ?? 3600)
                } else {
                    try tx.markPlaySent(pending.op.opId)
                }
                continue
            case "history.forget", "history.clear":
                if !deferred { try tx.deleteHistoryOp(pending.op.opId) }
                continue
            case "play.baseline":
                baselineDone = (baselineDone ?? true) && !deferred
                continue
            default:
                break
            }
            guard result.status == "redirected", pending.key.hasPrefix("pl:"), let newId = result.playlistId else { continue }
            let old = String(pending.key.dropFirst(3))
            if let local = try tx.playlist(syncId: old) {
                try tx.setPlaylistSyncId(local.id, newId)
                // В копии только то, что несла op: остальные треки уйдут туда как новые
                try tx.clearSortKeys(local.id)
            }
            try tx.deleteSyncedPlaylist(old)
        }
        if let baselineDone {
            try tx.setState(SyncStateKey.historyMerge, baselineDone ? "0" : "1")
            if baselineDone { try tx.setState(SyncStateKey.historyReplay, nil) }
        }
        if let retry { try tx.setState(SyncStateKey.historyRetryAt, String(now + Int64(retry) * 1000)) }
        return retry
    }

    /// Строки ответа в порядке API §4.8: треки → плейлисты (по `createdAt`) → их треки → лайки → закладки →
    /// общее время → прослушивания → забытое. Библиотека и снимок становятся тем, что на сервере, — кроме ключей,
    /// которые здесь правили, пока шёл запрос (не совпали с `image`), и ключей с ops, которые ещё не ушли (`pending`):
    /// у них сервер попадает только в снимок, а здешнее остаётся и уходит дальше.
    static func rows(_ tx: SyncTx, _ response: SyncResponse, image: inout LibraryImage, pending: [PendingOp], now: Int64) throws {
        let pendingKeys = Set(pending.map(\.key))
        let pendingNames = Set(pending.filter { ["playlist.create", "playlist.import", "playlist.update"].contains($0.kind) }.map(\.key))
        for track in response.tracks { try tx.ensureTrack(track.videoId, metadata: record(track)) }

        var touched = Set<Int64>()
        let synced = try tx.syncedPlaylists()
        let playlists = response.playlists.enumerated().sorted { lhs, rhs in
            let a = IsoTime.epochMs(lhs.element.createdAt) ?? 0, b = IsoTime.epochMs(rhs.element.createdAt) ?? 0
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
        for row in playlists {
            let local = try tx.playlist(syncId: row.id)
            let previous = synced[row.id]?.videoIds ?? []
            if row.deleted {
                if let local {
                    try tx.deletePlaylist(local.id)
                    image.playlists[local.id] = nil
                }
                try tx.deleteSyncedPlaylist(row.id)
            } else if let local {
                // Имя, которое правили здесь во время запроса или которое ещё не ушло, остаётся здешним
                let renamedHere = image.playlists[local.id].map { $0.name != local.name || $0.thumbnailUrl != local.thumbnailUrl } ?? false
                if !renamedHere && !pendingNames.contains("pl:\(row.id)") {
                    if local.name != row.name || local.thumbnailUrl != row.thumbnailUrl {
                        try tx.updatePlaylist(local.id, name: row.name, thumbnailUrl: row.thumbnailUrl)
                    }
                    image.playlists[local.id]?.name = row.name
                    image.playlists[local.id]?.thumbnailUrl = row.thumbnailUrl
                }
                try tx.upsertSyncedPlaylist(SyncedPlaylist(syncId: row.id, name: row.name, thumbnailUrl: row.thumbnailUrl, videoIds: previous))
            } else if let id = image.syncIds[row.id], try !tx.playlistExists(id) {
                // Удалён здесь, пока шёл запрос: не возвращать. Снимок его помнит — следующий проход отправит playlist.delete
                try tx.upsertSyncedPlaylist(SyncedPlaylist(syncId: row.id, name: row.name, thumbnailUrl: row.thumbnailUrl, videoIds: previous))
            } else {
                let id = try tx.insertPlaylist(name: row.name, browseId: row.browseId, thumbnailUrl: row.thumbnailUrl, syncId: row.id,
                                               createdAt: IsoTime.epochMs(row.createdAt) ?? now)
                try tx.upsertSyncedPlaylist(SyncedPlaylist(syncId: row.id, name: row.name, thumbnailUrl: row.thumbnailUrl, videoIds: []))
                touched.insert(id)
            }
        }

        var order: [String] = []
        var items: [String: [PlaylistItemRow]] = [:]
        for item in response.items {
            if items[item.playlistId] == nil { order.append(item.playlistId) }
            items[item.playlistId, default: []].append(item)
        }
        for syncId in order {
            guard let playlist = try tx.playlist(syncId: syncId) else { continue }
            let rows = items[syncId] ?? []
            if try holds(tx, playlist.id, syncId: syncId, image: &image, pending: pendingKeys) {
                try hold(tx, playlist, rows: rows, previous: synced[syncId]?.videoIds ?? [], image: &image, now: now)
                touched.remove(playlist.id)
                continue
            }
            for item in rows {
                if item.present {
                    try tx.ensureTrack(item.videoId, metadata: nil)
                    try tx.upsertItem(playlist.id, videoId: item.videoId, sortKey: item.sortKey, addedAt: IsoTime.epochMs(item.addedAt) ?? now)
                } else {
                    try tx.deleteItem(playlist.id, videoId: item.videoId)
                }
            }
            touched.insert(playlist.id)
        }
        for id in touched.sorted() {
            try tx.reorder(id)
            if let playlist = try tx.playlist(id: id) {
                image.playlists[id] = PlaylistImage(name: playlist.name, thumbnailUrl: playlist.thumbnailUrl, videoIds: try tx.playlistVideoIds(id))
            }
        }

        for row in response.likes {
            try tx.ensureTrack(row.videoId, metadata: nil)
            let likedAt = row.liked ? IsoTime.epochMs(row.likedAt) ?? now : nil
            if try tx.likedAt(row.videoId) != image.likes[row.videoId] || pendingKeys.contains("like:\(row.videoId)") {
                try tx.setSyncedLike(row.videoId, liked: row.liked)
            } else {
                try tx.setLike(row.videoId, likedAt: likedAt)
                image.likes[row.videoId] = likedAt
            }
        }

        for row in response.bookmarks where row.type == "album" || row.type == "artist" {
            let key = SyncBookmarkKey(type: row.type, browseId: row.browseId)
            let bookmarkedAt = row.bookmarked ? IsoTime.epochMs(row.bookmarkedAt) ?? now : nil
            if try tx.bookmarkedAt(key) != image.bookmarks[key] || pendingKeys.contains("bm:\(row.type):\(row.browseId)") {
                try tx.setSyncedBookmark(key, bookmarked: row.bookmarked)
            } else {
                try tx.setBookmark(key, bookmarkedAt: bookmarkedAt, title: row.title, subtitle: row.subtitle, thumbnailUrl: row.thumbnailUrl, year: row.year)
                image.bookmarks[key] = bookmarkedAt
            }
        }

        try history(tx, response)
    }

    /// Держит ли плейлист порядок этого устройства: треки правили здесь во время запроса (до конца прохода) или его
    /// ops ещё не ушли (иначе здешний порядок откатился бы к промежуточному порядку сервера).
    private static func holds(_ tx: SyncTx, _ id: Int64, syncId: String, image: inout LibraryImage, pending: Set<String>) throws -> Bool {
        if image.edited.contains(id) { return true }
        if let known = image.playlists[id], try tx.playlistVideoIds(id) != known.videoIds {
            image.edited.insert(id)
            return true
        }
        return pending.contains("pl:\(syncId)")
    }

    /// Треки плейлиста, который держит порядок: здешние места остаются, ключи и чужие правки — с сервера, снимок —
    /// порядок сервера. Разница уходит следующим проходом.
    private static func hold(_ tx: SyncTx, _ playlist: SyncPlaylistRecord, rows: [PlaylistItemRow], previous: [String],
                             image: inout LibraryImage, now: Int64) throws {
        let expected = image.playlists[playlist.id]?.videoIds ?? []
        let held = heldItems(local: try tx.playlistItems(playlist.id), expected: Set(expected), rows: rows, previous: previous)
        let byVideoId = Dictionary(rows.map { ($0.videoId, $0) }, uniquingKeysWith: { _, last in last })
        for videoId in held.removed { try tx.deleteItem(playlist.id, videoId: videoId) }
        for videoId in held.inserted {
            guard let row = byVideoId[videoId] else { continue }
            try tx.ensureTrack(videoId, metadata: nil)
            try tx.upsertItem(playlist.id, videoId: videoId, sortKey: row.sortKey, addedAt: IsoTime.epochMs(row.addedAt) ?? now)
        }
        try tx.placeItems(playlist.id, held.items)
        if let syncId = playlist.syncId {
            let known = try tx.syncedPlaylist(syncId)
            try tx.upsertSyncedPlaylist(SyncedPlaylist(
                syncId: syncId, name: known?.name ?? playlist.name, thumbnailUrl: known.map(\.thumbnailUrl) ?? playlist.thumbnailUrl,
                videoIds: held.snapshot
            ))
        }
        if image.edited.contains(playlist.id) {
            let removed = Set(held.removed)
            image.playlists[playlist.id]?.videoIds = expected.filter { !removed.contains($0) } + held.inserted
        } else {
            image.playlists[playlist.id]?.videoIds = held.items.map(\.videoId)
        }
    }

    /// Чистая часть `hold`. `expected` — состав, который синк ждёт здесь (трек из него, которого здесь нет, убрали во
    /// время запроса); `previous` — снимок до ответа.
    static func heldItems(local: [SyncItemRecord], expected: Set<String>, rows: [PlaylistItemRow], previous: [String]) -> HeldItems {
        let here = Set(local.map(\.videoId))
        // Был здесь или на сервере, а здесь его нет — его убрали здесь, строка сервера его не возвращает
        let removedHere = expected.union(previous)
        var keys: [String: String] = [:]
        for item in local {
            if let key = item.sortKey { keys[item.videoId] = key }
        }
        var fresh: [String: String] = [:]
        var elsewhere: [String: String] = [:]
        var gone = Set<String>()
        var removed = Set<String>()
        for row in rows {
            let videoId = row.videoId
            guard row.present else {
                gone.insert(videoId)
                keys[videoId] = nil
                fresh[videoId] = nil
                elsewhere[videoId] = nil
                // Добавленный здесь во время запроса остаётся (без ключа)
                if here.contains(videoId) && expected.contains(videoId) { removed.insert(videoId) }
                continue
            }
            if here.contains(videoId) {
                keys[videoId] = row.sortKey
            } else if removedHere.contains(videoId) {
                elsewhere[videoId] = row.sortKey
            } else {
                fresh[videoId] = row.sortKey
            }
        }
        let staying = local.filter { !removed.contains($0.videoId) }
        let keyed = staying.compactMap { item in keys[item.videoId].map { (videoId: item.videoId, key: $0) } }
        let server = (keyed + fresh.map { (videoId: $0.key, key: $0.value) } + elsewhere.map { (videoId: $0.key, key: $0.value) })
            .sorted { lhs, rhs in
                let order = SortKeys.compare(lhs.key, rhs.key)
                return order != 0 ? order < 0 : SortKeys.precedes(lhs.videoId, rhs.videoId)
            }
            .map(\.videoId)

        // Новые с сервера встают за ближайшим предшественником по ключам, который есть здесь
        var head: [String] = []
        var after: [String: [String]] = [:]
        var anchor: String?
        for videoId in server {
            if fresh[videoId] != nil {
                if let anchor { after[anchor, default: []].append(videoId) } else { head.append(videoId) }
            } else if here.contains(videoId) {
                anchor = videoId
            }
        }
        var items = head.map { SyncItemRecord(videoId: $0, sortKey: fresh[$0]) }
        for item in staying {
            items.append(SyncItemRecord(videoId: item.videoId, sortKey: keys[item.videoId]))
            items += (after[item.videoId] ?? []).map { SyncItemRecord(videoId: $0, sortKey: fresh[$0]) }
        }
        let onServer = Set(server)
        return HeldItems(
            items: items,
            inserted: server.filter { fresh[$0] != nil },
            removed: local.map(\.videoId).filter { removed.contains($0) },
            snapshot: server + previous.filter { !onServer.contains($0) && !gone.contains($0) && !here.contains($0) }
        )
    }

    /// История с сервера (задание 0002 §3.3): общее время трека (уже по всем устройствам), прослушивания любого
    /// устройства (своё вернувшееся не задваивается), забытые события. Пока накопленное время не ушло
    /// `play.baseline atLeast` (слияние истории), здешнее время не уменьшается: оно — источник baseline.
    static func history(_ tx: SyncTx, _ response: SyncResponse) throws {
        let merging = try tx.state(SyncStateKey.historyMerge) == "1"
        for row in response.playStats {
            try tx.ensureTrack(row.videoId, metadata: nil)
            try tx.setPlayTotal(row.videoId, totalMs: row.totalPlayTimeMs, atLeast: merging)
        }
        for row in response.plays {
            guard let playedAt = IsoTime.epochMs(row.playedAt) else { continue }
            try tx.ensureTrack(row.videoId, metadata: nil)
            try tx.insertPlay(eventId: row.eventId, videoId: row.videoId, playedAt: playedAt, playTimeMs: row.playTimeMs, deviceId: row.deviceId)
        }
        for row in response.playForgets {
            guard let before = IsoTime.epochMs(row.eventsBefore) else { continue }
            try tx.forgetPlays(row.videoId, eventsBefore: before)
        }
    }

    /// Метаданные трека с сервера; у заглушки их нет.
    static func record(_ dto: TrackDto) -> SyncTrackRecord? {
        guard !dto.metadataStub, !dto.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return SyncTrackRecord(
            videoId: dto.videoId, title: dto.title, artistsText: dto.artistsText,
            artists: dto.artists.map { ArtistRef(id: $0.id, name: $0.name) }, albumId: dto.albumId, albumTitle: dto.albumTitle,
            durationMs: dto.durationMs, durationText: dto.durationText, thumbnailUrl: dto.thumbnailUrl, explicit: dto.explicit,
            videoType: dto.videoType
        )
    }
}
