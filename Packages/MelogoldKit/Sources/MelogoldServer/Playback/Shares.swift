import Foundation
import MelogoldCore

/// Чем кончилась «Поделиться» своим плейлистом (задание 0019, как `PlaylistShare` Android).
public enum PlaylistShare: Equatable, Sendable {
    /// Снимок на сервере аккаунта: `url` открывается в приложении и в браузере у кого угодно.
    case onServer(url: URL, shareId: String)
    /// Сервера или функции нет: первые `shown` из `total` видео списком на YouTube — подпись «Ссылка откроет первые 50
    /// треков на YouTube».
    case onYouTube(url: URL, shown: Int, total: Int)
    /// Ни одного видео YouTube в плейлисте: своих файлов у Apple-клиента нет, но плейлист может быть пустым.
    case noTracks
    /// Снимков столько, сколько хранит сервер (`409 share_limit_reached`): удалить старые ссылки.
    case limitReached(max: Int)
}

extension TrackInput {
    /// Трек, каким его несёт снимок: со своим названием, исполнителем и альбомом поверх YouTube (задание 0014) — собранный
    /// из разрозненных видео альбом приходит одним альбомом.
    public init(_ track: Track) {
        self.init(videoId: track.videoId)
        title = track.title
        artistsText = track.artistsText
        artists = track.artists.isEmpty ? nil : track.artists.map { ArtistRefDto(id: $0.id, name: $0.name) }
        albumId = track.albumId
        albumTitle = track.albumTitle
        durationMs = track.durationMs
        durationText = track.durationMs.map(Durations.format)
        thumbnailUrl = track.thumbnailUrl
        explicit = track.explicit ? true : nil
        videoType = track.videoType
    }
}

extension TrackDto {
    /// Трек снимка для показа и для «Слушать»: без метаданных (заглушка) называется своим `videoId`, пока не сыграет.
    public var track: Track {
        Track(
            videoId: videoId, title: metadataStub || title.trimmingCharacters(in: .whitespaces).isEmpty ? videoId : title,
            artists: artists.map { ArtistRef(id: $0.id, name: $0.name) }, artistsText: artistsText, albumId: albumId, albumTitle: albumTitle,
            durationMs: durationMs ?? durationText.flatMap(Durations.parse), thumbnailUrl: thumbnailUrl, explicit: explicit, videoType: videoType
        )
    }
}

extension ShareDto {
    /// Треки снимка без повторов, в порядке снимка.
    public var playlistTracks: [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.videoId).inserted }.map(\.track)
    }
}

extension Account {
    /// Наибольшее число треков в снимке (API §11 `share.maxTracks`) и длина названия.
    static let shareMaxTracks = 1000
    static let shareNameMax = 200

    /// «Поделиться» своим плейлистом: снимок на сервере аккаунта, если сервер его делает (`features.share`) и вход есть;
    /// иначе — список первых 50 видео на YouTube. Название — до 200 знаков, треков — до 1000.
    public func sharePlaylist(name: String, tracks: [Track]) async -> PlaylistShare {
        let shareable = Array(tracks.filter { ShareURLs.isVideoId($0.videoId) }.prefix(Self.shareMaxTracks))
        guard !shareable.isEmpty else { return .noTracks }
        if isSignedIn {
            if serverInfo == nil { _ = try? await check() }
            if supportsShare {
                do {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = try await createShare(name: String(trimmed.prefix(Self.shareNameMax)), tracks: shareable.map(TrackInput.init))
                    if let url = URL(string: created.url) { return .onServer(url: url, shareId: created.shareId) }
                } catch let error as APIError where error.code == "share_limit_reached" {
                    return .limitReached(max: 200)
                } catch {
                    // Сети нет, сервер занят: список на YouTube всё равно работает
                }
            }
        }
        guard let url = ShareURLs.watchVideos(shareable.map(\.videoId)) else { return .noTracks }
        return .onYouTube(url: url, shown: min(shareable.count, ShareURLs.watchVideosLimit), total: shareable.count)
    }

    /// `createShare` со своими треками.
    public func createShare(name: String, tracks: [Track]) async throws -> ShareCreated {
        try await createShare(name: name, tracks: tracks.map(TrackInput.init))
    }
}
