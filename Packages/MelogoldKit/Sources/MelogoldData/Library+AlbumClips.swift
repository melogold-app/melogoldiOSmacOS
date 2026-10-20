import Foundation
import GRDB
import MelogoldCore

// Клипы из альбомов, сохранённые до задания 0029, — на песни (задание 0033 §3; Linux 0030 `Library::saved_album_clips`,
// `replace_clip_with_song`; Windows 0033 `Library.SavedAlbumClips`, `ReplaceClipWithSong`). До 0029 список альбома давал
// клипы вместо песен, и то, что человек лайкнул или положил в плейлист из альбома, осталось клипом.
extension Library {
    /// Что перешло с клипа на песню (`replaceClipWithSong`).
    public struct ClipReplaced: Hashable, Sendable {
        public var liked = false
        public var playlists = 0
        public var movedOverride = false
        public var movedPin = false
    }

    /// Клипы из альбомов (`video_type` клип, `album_id` — `MPREb_…`), которые человек сохранил: в Избранном или в своём
    /// плейлисте. Треки — как их дал YouTube, без своих названий: нужен альбом трека.
    public func savedAlbumClips() throws -> [Track] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.trackColumns) FROM tracks WHERE video_type = ? AND album_id LIKE 'MPREb%'
                AND (liked_at IS NOT NULL OR video_id IN (SELECT video_id FROM playlist_items))
                ORDER BY video_id
                """, arguments: [VideoType.video]).map(Self.track)
        }
    }

    /// Сохранённый клип → его песня, одной транзакцией: ♡ с прежней датой (порядок Избранного не меняется), места в
    /// плейлистах, своё название (задание 0014) и закреплённый текст (задание 0015) — если у песни своих нет. Синк
    /// увидит это разницей со снимком сервера, как ручные правки: снятый ♡ у клипа и поставленный у песни, замена трека в
    /// плейлисте, правка и закрепление у песни и их снятие у клипа.
    ///
    /// Загрузки и история остаются за клипом: файл загрузки — звук клипа, а история — то, что действительно звучало.
    @discardableResult
    public func replaceClipWithSong(_ clipId: String, with song: Track) throws -> ClipReplaced {
        guard clipId != song.videoId else { return ClipReplaced() }
        return try database.writer.write { db in
            try Self.upsert(db, song)
            var replaced = ClipReplaced()

            if let likedAt = try Int64.fetchOne(db, sql: "SELECT liked_at FROM tracks WHERE video_id = ?", arguments: [clipId]) {
                try db.execute(sql: "UPDATE tracks SET liked_at = COALESCE(liked_at, ?) WHERE video_id = ?", arguments: [likedAt, song.videoId])
                try db.execute(sql: "UPDATE tracks SET liked_at = NULL WHERE video_id = ?", arguments: [clipId])
                replaced.liked = true
            }

            let playlists = try Int64.fetchAll(db, sql: "SELECT playlist_id FROM playlist_items WHERE video_id = ?", arguments: [clipId])
            for playlistId in playlists {
                let hasSong = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlist_items WHERE playlist_id = ? AND video_id = ?)",
                                                arguments: [playlistId, song.videoId]) ?? false
                if hasSong {
                    // Песня там уже есть: трек встречается в плейлисте не больше одного раза.
                    try db.execute(sql: "DELETE FROM playlist_items WHERE playlist_id = ? AND video_id = ?", arguments: [playlistId, clipId])
                    try Self.renumber(db, playlistId)
                } else {
                    // Ключ порядка сервера — клипа, а не песни: без сброса песня выглядела бы уже побывавшей на сервере, и
                    // замена до него не дошла бы.
                    try db.execute(sql: "UPDATE playlist_items SET video_id = ?, sort_key = NULL WHERE playlist_id = ? AND video_id = ?",
                                   arguments: [song.videoId, playlistId, clipId])
                }
            }
            replaced.playlists = playlists.count

            func move(_ table: String) throws -> Bool {
                try db.execute(sql: """
                    UPDATE \(table) SET video_id = ? WHERE video_id = ? AND NOT EXISTS (SELECT 1 FROM \(table) WHERE video_id = ?)
                    """, arguments: [song.videoId, clipId, song.videoId])
                return db.changesCount > 0
            }
            replaced.movedOverride = try move("track_overrides")
            replaced.movedPin = try move("lyrics_pins")
            return replaced
        }
    }
}
