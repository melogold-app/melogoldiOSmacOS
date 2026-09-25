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
