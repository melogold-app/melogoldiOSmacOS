import Foundation
import MelogoldCore

/// Ошибка запроса к YouTube: `kind` даёт класс состояния экрана (REWRITE §3.0, тексты — GLOSSARY §4.0).
public struct YouTubeError: Error, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// «Нет соединения с YouTube. Проверьте сеть или VPN».
        case offline
        /// «YouTube не ответил: проверка на бота или блокировка…».
        case blocked
        /// «YouTube изменил страницу. Исправление придёт с обновлением».
        case parser
        /// «Что-то пошло не так».
        case unknown
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "\(kind.rawValue): \(message)" }
}

/// Запросы к `/youtubei/v1`. Язык и регион — из системы (`ru-RU` → `hl=ru`, `gl=RU`, грабли §9 п. 7),
/// `visitorData` запоминается из первого ответа: он нужен клиенту потока VISIONOS.
public actor InnerTubeClient {
    private let session: URLSession
    public nonisolated let language: String
    public nonisolated let region: String
    private var visitor: String?

    public init(session: URLSession? = nil, locale: Locale = .current, preferredLanguages: [String] = Locale.preferredLanguages) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 6
            HTTPConfiguration.apply(to: configuration)
            self.session = URLSession(configuration: configuration)
        }
        (language, region) = Self.localeFrom(preferredLanguages: preferredLanguages, locale: locale)
    }

    /// Язык InnerTube по списку поддерживаемых кодов, запасной — `en`; регион — страна локали, запасной — `US`
    /// (REWRITE §4.8.4).
    public static func localeFrom(preferredLanguages: [String], locale: Locale) -> (language: String, region: String) {
        let tag = preferredLanguages.first ?? locale.identifier
        let normalized = tag.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        let base = parts.first?.lowercased() ?? "en"
        var language = "en"
        let full = parts.count > 1 ? "\(base)-\(parts.last!)" : base
        if supportedLanguages.contains(full) {
            language = full
        } else if base == "zh" {
            language = normalized.contains("Hant") ? "zh-TW" : "zh-CN"
        } else if supportedLanguages.contains(base) {
            language = base
        }
        let region = locale.region?.identifier.uppercased() ?? "US"
        return (language, region.count == 2 ? region : "US")
    }

    private static let supportedLanguages: Set<String> = [
        "af", "az", "id", "ms", "ca", "cs", "da", "de", "et", "en-GB", "en", "es", "es-419", "eu", "fil", "fr", "fr-CA", "gl", "hr",
        "zu", "is", "it", "sw", "lt", "hu", "nl", "no", "uz", "pl", "pt-PT", "pt", "ro", "sq", "sk", "sl", "fi", "sv", "vi", "tr",
        "bg", "ky", "kk", "mk", "mn", "ru", "sr", "uk", "el", "hy", "iw", "ur", "ar", "fa", "ne", "mr", "hi", "bn", "pa", "gu",
        "ta", "te", "kn", "ml", "si", "th", "lo", "my", "ka", "am", "km", "zh-CN", "zh-TW", "zh-HK", "ja", "ko",
    ]

    /// Идентификатор посетителя YouTube: приходит в первом ответе, нужен клиенту потока.
    public var visitorData: String? { visitor }

    public func setVisitorData(_ value: String?) {
        visitor = (value?.isEmpty ?? true) ? nil : value
    }

    /// Получить `visitorData`, если его ещё нет: самый лёгкий запрос YouTube Music.
    public func ensureVisitorData() async throws {
        guard visitor == nil else { return }
        _ = try await post(.webRemix, "music/get_search_suggestions", body: ["input": ""])
    }

    func context(_ client: ClientProfile) -> [String: Any] {
        var c: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": language,
            "gl": region,
            "timeZone": "UTC",
            "utcOffsetMinutes": 0,
        ]
        if let platform = client.platform { c["platform"] = platform }
        if let make = client.deviceMake { c["deviceMake"] = make }
        if let model = client.deviceModel { c["deviceModel"] = model }
        if let os = client.osName { c["osName"] = os }
        if let version = client.osVersion { c["osVersion"] = version }
        if let sdk = client.androidSdkVersion { c["androidSdkVersion"] = sdk }
        if let visitor { c["visitorData"] = visitor }
        return ["client": c, "user": ["lockedSafetyMode": false]]
    }

    /// POST `https://<host>/youtubei/v1/<endpoint>`; ответ — сырые байты JSON (разбор — у вызывающего).
    public func post(_ client: ClientProfile, _ endpoint: String, body: [String: any Sendable]) async throws -> Data {
        var payload: [String: Any] = [:]
        for (key, value) in body { payload[key] = value }
        payload["context"] = context(client)
        guard let url = URL(string: "https://\(client.host)/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw YouTubeError(.unknown, "bad endpoint \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(client.id), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        if let referer = client.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue(String(referer.dropLast(referer.hasSuffix("/") ? 1 : 0)), forHTTPHeaderField: "Origin")
        }
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw YouTubeError(.offline, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw YouTubeError(.unknown, "no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let kind: YouTubeError.Kind = switch http.statusCode {
            case 403, 429: .blocked
            case 500...: .offline
            default: .unknown
            }
            throw YouTubeError(kind, "HTTP \(http.statusCode) from \(endpoint)")
        }
        if visitor == nil, let found = Self.visitorData(in: data) {
            visitor = found
        }
        return data
    }

    /// Разобранный ответ; не JSON — `parser`. Разбор — вне актора: дерево JSON не покидает вызывающий код.
    nonisolated func postJSON(_ client: ClientProfile, _ endpoint: String, body: [String: any Sendable]) async throws -> JSON {
        let data = try await post(client, endpoint, body: body)
        do {
            return try JSON.parse(data)
        } catch {
            throw YouTubeError(.parser, "not JSON from \(endpoint)")
        }
    }

    private static func visitorData(in data: Data) -> String? {
        guard let json = try? JSON.parse(data) else { return nil }
        let value = json.str("responseContext", "visitorData")
        return (value?.isEmpty ?? true) ? nil : value
    }
}
