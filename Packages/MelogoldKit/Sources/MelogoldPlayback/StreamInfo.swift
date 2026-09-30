import Foundation
import MelogoldCore
import MelogoldInnerTube

/// Адрес аудиопотока трека и то, как по нему ходить.
public struct StreamInfo: Hashable, Sendable {
    public var videoId: String
    /// Прямой адрес googlevideo; пусто — трек открыт из кэша без запроса потока.
    public var url: String
    public var itag: Int
    public var mimeType: String
    public var contentLength: Int64?
    public var bitrate: Int?
    /// Параметр `expire` адреса минус 5 минут (REWRITE §4.10.3).
    public var expiresAt: Date
    /// Клиент InnerTube, который дал адрес (для «Сведений о потоке»); у кэша — `cache`.
    public var source: String
    /// User-Agent, с которым googlevideo отдаёт этот адрес; `nil` — любой.
    public var userAgent: String?
    public var loudnessDb: Double?
    /// Настоящая длительность звука, мс (у DASH-m4a AVFoundation считает её вдвое больше).
    public var durationMs: Int64?

    public init(videoId: String, url: String, itag: Int, mimeType: String, contentLength: Int64?, bitrate: Int? = nil,
                expiresAt: Date, source: String, userAgent: String? = nil, loudnessDb: Double? = nil, durationMs: Int64? = nil) {
        self.videoId = videoId
        self.url = url
        self.itag = itag
        self.mimeType = mimeType
        self.contentLength = contentLength
        self.bitrate = bitrate
        self.expiresAt = expiresAt
        self.source = source
        self.userAgent = userAgent
        self.loudnessDb = loudnessDb
        self.durationMs = durationMs
    }

    public var codec: String {
        if mimeType.contains("opus") { return "Opus" }
        if mimeType.contains("mp4a") { return "AAC" }
        return mimeType
    }

    /// `expire` из адреса минус 5 минут; нет параметра — через 5 часов.
    public static func expiry(of url: String, now: Date = Date()) -> Date {
        let expire = URLComponents(string: url)?.queryItems?.first { $0.name == "expire" }?.value.flatMap(Double.init)
        guard let expire else { return now.addingTimeInterval(5 * 3600) }
        return max(now.addingTimeInterval(60), Date(timeIntervalSince1970: expire - 5 * 60))
    }
}

/// Класс ошибки получения потока (REWRITE §4.10.3): по нему решаются повторы и текст карточки (§3.10.9).
public struct StreamError: Error, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case network, timeout, botCheck, geo, unavailable, age, extractor
    }

    public let kind: Kind
    public let message: String
    /// `.geo`: страна, в которой YouTube видит устройство, и в скольких странах трек открыт (задание 0010).
    public var country: String?
    public var availableCountries: Int?

    public init(_ kind: Kind, _ message: String, country: String? = nil, availableCountries: Int? = nil) {
        self.kind = kind
        self.message = message
        self.country = country
        self.availableCountries = availableCountries
    }

    /// Итог диагноза (задание 0010 §2.3), по порядку: страна вне списка стран трека — закрыт в стране (со страной и
    /// числом); фразы о стране — закрыт в стране (без числа); о возрасте — возраст; об удалении — удалено; иначе `nil`
    /// (остаётся прежняя ошибка).
    public static func diagnosed(_ playability: Playability, streamMessage: String?) -> StreamError? {
        if playability.isBlockedHere {
            let others = playability.availableCountries.count
            return StreamError(.geo, "\(playability.country ?? "?") не среди \(others) стран", country: playability.country, availableCountries: others)
        }
        let text = [streamMessage, playability.reason].compactMap { $0 }.joined(separator: " ").lowercased()
        let geo = ["available in your country", "not made this video available in your country", "blocked it in your country"]
        if geo.contains(where: text.contains) {
            return StreamError(.geo, playability.reason ?? streamMessage ?? "", country: playability.country)
        }
        if ["confirm your age", "age-restricted", "inappropriate for some users"].contains(where: text.contains) {
            return StreamError(.age, playability.reason ?? streamMessage ?? "")
        }
        let removed = ["private video", "has been removed", "account associated with this video has been terminated", "no longer available"]
        if removed.contains(where: text.contains) {
            return StreamError(.unavailable, playability.reason ?? streamMessage ?? "")
        }
        return nil
    }

    /// Сколько раз повторить, прежде чем пропустить трек: сеть — 2, таймаут, бот и прочее — 1, гео, возраст,
    /// «недоступно» — 0.
    public var retries: Int {
        switch kind {
        case .network: 2
        case .timeout, .botCheck, .extractor: 1
        case .geo, .unavailable, .age: 0
        }
    }

    /// Пропуск без повторов: причина в самом видео.
    public var isFinal: Bool { kind == .geo || kind == .unavailable || kind == .age }

    public var description: String { "\(kind.rawValue): \(message)" }

    /// Класс ошибки по тексту YouTube (таблица REWRITE §4.10.3).
    public static func classify(_ message: String) -> Kind {
        let text = message.lowercased()
        if text.contains("not a bot") || text.contains("confirm you’re not") || text.contains("confirm you're not") {
            return .botCheck
        }
        // «Sign in to confirm your age» — возраст, а не проверка на бота: проверяется до общего «sign in to confirm».
        if text.contains("your age") || text.contains("age-restricted") || text.contains("age restricted")
            || text.contains("age_check") || text.contains("возраст") {
            return .age
        }
        if text.contains("sign in to confirm") { return .botCheck }
        if text.contains("country") || text.contains("region") || text.contains("стране") || text.contains("регион") { return .geo }
        if text.contains("unavailable") || text.contains("removed") || text.contains("private") || text.contains("недоступно")
            || text.hasPrefix("error") || text.hasPrefix("unplayable") {
            return .unavailable
        }
        if text.contains("login_required") || text.contains("sign in") { return .botCheck }
        return .extractor
    }
}
