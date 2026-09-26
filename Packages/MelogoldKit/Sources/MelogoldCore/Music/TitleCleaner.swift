import Foundation

/// Как называется трек, когда шум названия YouTube убран.
public struct CleanTitle: Hashable, Sendable {
    public var artist: String?
    public var title: String
}

/// Исполнитель и название трека YouTube для поиска текста и «Других версий» (векторы `spec/title-cleaner.vectors.json`,
/// порт `TitleCleaner.cs` Windows). По порядку: эмодзи, `【…】`, всё после " | ", скобки из одного шума
/// («(Official Video)», «[HD]»), номер трека, «Исполнитель - Название», «feat.», кавычки и пробелы. `videoType`:
/// `song`, `video`, `ugc`, `live` или `nil`; песни и клипы делят «Исполнитель - Название», только если слева канал.
public enum TitleCleaner {
    private static let channelTails = ["vevo", "official"]

    private static var noise: Regex<AnyRegexOutput> { Regex(#/^(?:official( (music|lyric))? (video|audio|visualizer|clip)|official|((music|lyric) )?video|audio|lyrics?|visualizer|hd|hq|4k|8k|1080p|720p|mv|m/v|официальное видео|официальный клип|клип|премьера( клипа)?(,.*)?|текст( песни)?)$/#).ignoresCase() }

    public static func clean(title: String, channel: String?, videoType: String?) -> CleanTitle {
        let upload = videoType == nil || videoType == "ugc" || videoType == "live"

        var text = withoutEmoji(title).replacing(/【[^】]*】/, with: " ")
        text = text.replacing(/\s+\|.*$/, with: "")
        text = text.replacing(/\s*[(\[]([^()\[\]]*)[)\]]/) { match in
            let inner = String(match.output.1).trimmingCharacters(in: .whitespaces)
            return inner.wholeMatch(of: noise) != nil ? "" : String(match.output.0)
        }
        text = collapse(text)
        if upload { text = text.replacing(/^\d{1,3}\.\s+/, with: "") }

        var channelArtist = channel.map { $0.trimmingCharacters(in: .whitespaces).replacing(/\s*[-–—]\s*(?i:topic|тема)$/, with: "") }
        if channelArtist?.trimmingCharacters(in: .whitespaces).isEmpty == true { channelArtist = nil }
        var artist = channelArtist
        if let separator = text.firstMatch(of: /\s[-–—]\s/) {
            let left = String(text[..<separator.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let isChannel = channelArtist.map { comparable(left) == comparable($0) } ?? false
            if isChannel || upload {
                artist = withoutFeat(left)
                text = String(text[separator.range.upperBound...])
            }
        }

        text = collapse(withoutFeat(text))
        if let quoted = text.wholeMatch(of: /[«"“„](.*)[»"”“]/) { text = collapse(String(quoted.output.1)) }
        let cleanArtist = artist.map(collapse)
        return CleanTitle(artist: cleanArtist?.isEmpty == false ? cleanArtist : nil, title: text)
    }

    private static func withoutFeat(_ value: String) -> String {
        value.replacing(/\s*[(\[](?i:feat\.?|ft\.?|featuring)\s[^)\]]*[)\]]/, with: "")
            .replacing(/\s+(?i:feat\.?|ft\.?|featuring)\s.*$/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func collapse(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Имя для сравнения канала и левой части: без feat, строчными, только буквы и цифры.
    private static func comparable(_ value: String) -> String {
        var name = String(withoutFeat(value).lowercased().filter { $0.isLetter || $0.isNumber })
        for tail in channelTails where name.count > tail.count && name.hasSuffix(tail) {
            name.removeLast(tail.count)
        }
        return name
    }

    /// Эмодзи уходят: Extended_Pictographic, флаги, селектор варианта, соединители, keycap, тона кожи.
    private static func withoutEmoji(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isEmojiPart(scalar.value) { result.append(" ") } else { result.append(scalar) }
        }
        return String(result)
    }

    private static func isEmojiPart(_ c: UInt32) -> Bool {
        c == 0xFE0F || c == 0x200D || c == 0x20E3
            || (0x1F000...0x1FAFF).contains(c) || (0x1FC00...0x1FFFD).contains(c) || (0x2600...0x27BF).contains(c)
            || c == 0x00A9 || c == 0x00AE || c == 0x203C || c == 0x2049 || c == 0x2122 || c == 0x2139
            || (0x2194...0x2199).contains(c) || (0x21A9...0x21AA).contains(c) || (0x231A...0x231B).contains(c) || c == 0x2328
            || c == 0x23CF || (0x23E9...0x23F3).contains(c) || (0x23F8...0x23FA).contains(c) || c == 0x24C2
            || (0x25AA...0x25AB).contains(c) || c == 0x25B6 || c == 0x25C0 || (0x25FB...0x25FE).contains(c)
            || (0x2934...0x2935).contains(c) || (0x2B05...0x2B07).contains(c) || (0x2B1B...0x2B1C).contains(c) || c == 0x2B50
            || c == 0x2B55 || c == 0x3030 || c == 0x303D || c == 0x3297 || c == 0x3299
    }
}
