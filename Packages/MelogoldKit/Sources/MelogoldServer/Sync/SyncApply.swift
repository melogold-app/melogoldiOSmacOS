import Foundation
import MelogoldCore
import MelogoldData

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
        if let baselineDone { try tx.setState(SyncStateKey.historyMerge, baselineDone ? "0" : "1") }
        if let retry { try tx.setState(SyncStateKey.historyRetryAt, String(now + Int64(retry) * 1000)) }
        return retry
    }

    /// Строки ответа в порядке API §4.8: треки → плейлисты (по `createdAt`) → их треки → лайки → закладки →
    /// общее время → прослушивания → забытое. Библиотека и снимок становятся тем, что на сервере.
    static func rows(_ tx: SyncTx, _ response: SyncResponse, now: Int64) throws {
        for track in response.tracks { try tx.ensureTrack(track.videoId, metadata: record(track)) }

        var touched = Set<Int64>()
        let synced = try tx.syncedPlaylists()
        let playlists = response.playlists.enumerated().sorted { lhs, rhs in
            let a = IsoTime.epochMs(lhs.element.createdAt) ?? 0, b = IsoTime.epochMs(rhs.element.createdAt) ?? 0
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
        for row in playlists {
            let local = try tx.playlist(syncId: row.id)
            if row.deleted {
                if let local { try tx.deletePlaylist(local.id) }
                try tx.deleteSyncedPlaylist(row.id)
            } else if let local {
                if local.name != row.name || local.thumbnailUrl != row.thumbnailUrl {
                    try tx.updatePlaylist(local.id, name: row.name, thumbnailUrl: row.thumbnailUrl)
                }
                let previous = synced[row.id]?.videoIds ?? []
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
            for item in items[syncId] ?? [] {
                if item.present {
                    try tx.ensureTrack(item.videoId, metadata: nil)
                    try tx.upsertItem(playlist.id, videoId: item.videoId, sortKey: item.sortKey, addedAt: IsoTime.epochMs(item.addedAt) ?? now)
                } else {
                    try tx.deleteItem(playlist.id, videoId: item.videoId)
                }
            }
            touched.insert(playlist.id)
        }
        for id in touched.sorted() { try tx.reorder(id) }

        for row in response.likes {
            try tx.ensureTrack(row.videoId, metadata: nil)
            try tx.setLike(row.videoId, likedAt: row.liked ? IsoTime.epochMs(row.likedAt) ?? now : nil)
        }

        for row in response.bookmarks where row.type == "album" || row.type == "artist" {
            try tx.setBookmark(
                SyncBookmarkKey(type: row.type, browseId: row.browseId),
                bookmarkedAt: row.bookmarked ? IsoTime.epochMs(row.bookmarkedAt) ?? now : nil,
                title: row.title, subtitle: row.subtitle, thumbnailUrl: row.thumbnailUrl, year: row.year
            )
        }

        try history(tx, response)
    }

    /// История с сервера (задание 0002 §3.3): общее время трека (уже по всем устройствам), прослушивания любого
    /// устройства (своё вернувшееся не задваивается), забытые события.
    static func history(_ tx: SyncTx, _ response: SyncResponse) throws {
        for row in response.playStats {
            try tx.ensureTrack(row.videoId, metadata: nil)
            try tx.setPlayTotal(row.videoId, totalMs: row.totalPlayTimeMs)
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
