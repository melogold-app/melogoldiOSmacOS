import Foundation
import MelogoldCore

/// Ссылки Spotify, Apple Music, Яндекс Музыки и Deezer → YouTube через song.link (Odesli, задание 0019): друг прислал
/// трек или альбом в другом сервисе — Melogold открывает то же самое. Сервер Melogold к song.link не ходит: запрос
/// идёт с устройства и несёт только саму ссылку.
public enum SongLink {
    static let endpoint = URL(string: "https://api.song.link/v1-alpha.1/links")!

    /// Ссылка другого музыкального сервиса, которую стоит спросить у song.link.
    public static func isForeign(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let hosts = ["open.spotify.com", "spotify.link", "music.apple.com", "itunes.apple.com", "deezer.com", "deezer.page.link", "link.deezer.com"]
        if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        // music.yandex.ru, .com, .by, .kz, .uz …
        return host.hasPrefix("music.yandex.")
    }

    /// Ссылка YouTube Music (или YouTube) на то же самое; `nil` — song.link не нашёл.
    public static func resolve(_ url: URL, session: URLSession = .shared) async throws -> URL? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 400 { return nil }
        guard (200 ..< 300).contains(status) else { throw URLError(.badServerResponse) }
        return youTubeURL(in: data)
    }

    /// Из ответа Odesli: `linksByPlatform.youtubeMusic.url`, иначе `linksByPlatform.youtube.url`.
    static func youTubeURL(in data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = object["linksByPlatform"] as? [String: Any] else { return nil }
        for platform in ["youtubeMusic", "youtube"] {
            if let entry = links[platform] as? [String: Any], let text = entry["url"] as? String, let url = URL(string: text) {
                return url
            }
        }
        return nil
    }
}
