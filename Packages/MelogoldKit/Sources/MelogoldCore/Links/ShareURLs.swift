import Foundation

/// Ссылки «Поделиться» (задание 0019, как `ShareLinks` Android): песни и альбомы — на YouTube Music, видео и каналы — на
/// YouTube, чтобы открыть их мог кто угодно. Свой плейлист без сервера — список первых 50 видео `watch_videos`.
public enum ShareURLs {
    /// Столько видео открывает ссылка `watch_videos`.
    public static let watchVideosLimit = 50

    public static func track(_ track: Track) -> URL {
        let host = track.isVideo && track.videoType != VideoType.video ? "www.youtube.com" : "music.youtube.com"
        return URL(string: "https://\(host)/watch?v=\(track.videoId)")!
    }

    public static func album(_ browseId: String) -> URL {
        URL(string: "https://music.youtube.com/browse/\(browseId)")!
    }

    /// Плейлист YouTube; `VL` от browse id отбрасывается.
    public static func playlist(_ playlistId: String) -> URL {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        return URL(string: "https://music.youtube.com/playlist?list=\(id)")!
    }

    public static func artist(_ browseId: String, isChannel: Bool) -> URL {
        URL(string: isChannel ? "https://www.youtube.com/channel/\(browseId)" : "https://music.youtube.com/channel/\(browseId)")!
    }

    /// Первые 50 видео своего плейлиста списком на YouTube; нет ни одного видео YouTube — `nil`.
    public static func watchVideos(_ videoIds: [String]) -> URL? {
        let ids = videoIds.filter(isVideoId).prefix(watchVideosLimit)
        guard !ids.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/watch_videos?video_ids=" + ids.joined(separator: ","))
    }

    /// «Название — Исполнитель» и ссылка под ним; без исполнителя — название.
    public static func message(title: String, subtitle: String?, url: URL) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = sub.isEmpty ? name : "\(name) — \(sub)"
        return head.isEmpty ? url.absoluteString : "\(head)\n\(url.absoluteString)"
    }

    /// Ссылка снимка, которая открывается в приложении (API §7.2): `melogold://share?v=1&url=…&id=…`.
    public static func melogoldShare(server: String, shareId: String) -> URL? {
        var components = URLComponents()
        components.scheme = MelogoldLink.scheme
        components.host = "share"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "url", value: server),
            URLQueryItem(name: "id", value: shareId),
        ]
        return components.url
    }

    /// `videoId` YouTube: 11 знаков `[A-Za-z0-9_-]`.
    public static func isVideoId(_ text: String) -> Bool {
        text.wholeMatch(of: /^[A-Za-z0-9_-]{11}$/) != nil
    }
}
