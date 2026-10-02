import Foundation

/// Обложка нужного размера (REWRITE §4.8.2). В базе лежит исходный URL, размер подбирается по месту:
/// у `lh3`/`yt3.googleusercontent` хвост после `=` заменяется на `=w{px}-h{px}-l90-rj`;
/// у `i.ytimg.com/vi/<id>` до 320 px — `mqdefault.jpg` (грабли §9 п. 5), иначе `hq720.jpg`.
public enum Thumbnails {
    public static func sized(_ url: String?, px: Int) -> String? {
        guard var url, !url.isEmpty else { return url }
        if url.hasPrefix("//") { url = "https:" + url }
        if url.contains("googleusercontent.com") || url.contains("ggpht.com") {
            let schemeEnd = url.range(of: "://").map { url.distance(from: url.startIndex, to: $0.upperBound) } ?? 0
            if let eq = url.lastIndex(of: "="), url.distance(from: url.startIndex, to: eq) > schemeEnd {
                return String(url[..<eq]) + "=w\(px)-h\(px)-l90-rj"
            }
            return url + "=w\(px)-h\(px)-l90-rj"
        }
        if let videoId = ytimgVideoId(url) {
            return px <= 320 ? "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg" : "https://i.ytimg.com/vi/\(videoId)/hq720.jpg"
        }
        return url
    }

    /// Обложка видео по его id, когда своей нет.
    public static func forVideo(_ videoId: String, px: Int = 544) -> String {
        px <= 320 ? "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg" : "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }

    /// Что просить, если превью нужного размера нет: `hq720.jpg` есть не у всех видео (старые клипы, например «Shape of
    /// You»), и на 404 YouTube отдаёт серую заглушку с тремя точками — её нельзя показывать как обложку. `hqdefault.jpg`
    /// есть у каждого видео, `mqdefault.jpg` — последняя попытка.
    public static func fallback(_ url: String) -> String? {
        guard let videoId = ytimgVideoId(url) else { return nil }
        let name = url.split(separator: "?").first?.split(separator: "/").last.map(String.init) ?? ""
        switch name {
        case "hq720.jpg", "maxresdefault.jpg", "sddefault.jpg", "hq720.webp", "maxresdefault.webp", "sddefault.webp":
            return "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
        case "hqdefault.jpg", "hqdefault.webp":
            return "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"
        default:
            return nil
        }
    }

    /// Превью видео 16:9: при показе квадратом его нужно обрезать по центру.
    public static func isWide(_ url: String?) -> Bool {
        guard let url else { return false }
        return ytimgVideoId(url) != nil
    }

    private static func ytimgVideoId(_ url: String) -> String? {
        let pattern = /^https?:\/\/i\.ytimg\.com\/vi(?:_webp)?\/([A-Za-z0-9_-]{11})\//
        return url.firstMatch(of: pattern).map { String($0.1) }
    }
}
