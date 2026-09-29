import Foundation
import GRDB
import MelogoldCore

// Свои названия треков (задание 0014) и закреплённые тексты (задание 0015). Правка применяется в одном месте —
// `displayed(_:)`, её зовут строки, плеер, «Сейчас играет», часы и «Сохранить файлом». Синк замечает запись в
// `track_overrides` и `lyrics_pins` сам (`SyncStore.observedRegion`).
extension Library {
    public func trackOverride(_ videoId: String) -> TrackOverride? {
        read { db in try Self.readOverride(db, videoId) } ?? nil
    }

    /// Правки нескольких треков сразу — для списков.
    public func trackOverrides(_ videoIds: [String]) -> [String: TrackOverride] {
        guard !videoIds.isEmpty else { return [:] }
        return read { db in
            var result: [String: TrackOverride] = [:]
            for chunk in stride(from: 0, to: videoIds.count, by: 500).map({ Array(videoIds[$0 ..< min($0 + 500, videoIds.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT video_id, title, artists_text, album_title FROM track_overrides WHERE video_id IN (\(marks))",
                                            arguments: StatementArguments(chunk)) {
                    result[row["video_id"]] = TrackOverride(title: row["title"], artistsText: row["artists_text"], albumTitle: row["album_title"])
                }
            }
            return result
        } ?? [:]
    }

    /// Все правки — для «Итогов» и копии библиотеки.
    public func allTrackOverrides() -> [String: TrackOverride] {
        read { db in
            try Row.fetchAll(db, sql: "SELECT video_id, title, artists_text, album_title FROM track_overrides").reduce(into: [:]) { result, row in
                result[row["video_id"] as String] = TrackOverride(title: row["title"], artistsText: row["artists_text"], albumTitle: row["album_title"])
            }
        } ?? [:]
    }

    /// Трек, как его показывать: со своей правкой поверх, если она есть.
    public func displayed(_ track: Track) -> Track {
        trackOverride(track.videoId)?.apply(to: track) ?? track
    }

    /// «Сохранить» в «Сведениях о треке»: замена целиком; все поля пустые («Как на YouTube») — правка снята.
    public func setTrackOverride(_ videoId: String, _ override: TrackOverride, at: Int64 = EpochMs.now()) {
        write { db in
            if override.isEmpty {
                try db.execute(sql: "DELETE FROM track_overrides WHERE video_id = ?", arguments: [videoId])
            } else {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO track_overrides (video_id, title, artists_text, album_title, updated_at) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [videoId, override.title, override.artistsText, override.albumTitle, at])
            }
        }
    }

    /// «Указать альбом…» для выделенного: альбом ставится всем, остальные поля правки остаются.
    public func setAlbum(_ albumTitle: String?, for videoIds: [String], at: Int64 = EpochMs.now()) {
        write { db in
            for videoId in videoIds {
                var override = try Self.readOverride(db, videoId) ?? TrackOverride()
                override.albumTitle = TrackOverride.clean(albumTitle)
                if override.isEmpty {
                    try db.execute(sql: "DELETE FROM track_overrides WHERE video_id = ?", arguments: [videoId])
                } else {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO track_overrides (video_id, title, artists_text, album_title, updated_at) VALUES (?, ?, ?, ?, ?)
                        """, arguments: [videoId, override.title, override.artistsText, override.albumTitle, at])
                }
            }
        }
    }

    public func lyricsPin(_ videoId: String) -> LyricsPin? {
        read { db in
            try Row.fetchOne(db, sql: "SELECT source, ref, start_time_ms FROM lyrics_pins WHERE video_id = ?", arguments: [videoId]).flatMap {
                LyricsPin(source: $0["source"], ref: $0["ref"], startTimeMs: $0["start_time_ms"])
            }
        } ?? nil
    }

    /// Закрепить найденный текст (после 30 с прослушивания без правок, задание 0015) или снять закрепление (`nil`).
    public func setLyricsPin(_ videoId: String, _ pin: LyricsPin?, at: Int64 = EpochMs.now()) {
        write { db in
            if let pin {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO lyrics_pins (video_id, source, ref, start_time_ms, updated_at) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [videoId, pin.source, pin.ref, pin.startTimeMs, at])
            } else {
                try db.execute(sql: "DELETE FROM lyrics_pins WHERE video_id = ?", arguments: [videoId])
            }
        }
    }

    static func readOverride(_ db: Database, _ videoId: String) throws -> TrackOverride? {
        try Row.fetchOne(db, sql: "SELECT title, artists_text, album_title FROM track_overrides WHERE video_id = ?", arguments: [videoId]).map {
            TrackOverride(title: $0["title"], artistsText: $0["artists_text"], albumTitle: $0["album_title"])
        }
    }
}
