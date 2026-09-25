import Foundation

/// Клиент InnerTube: имя, версия, заголовки. У каждого свой User-Agent, глобального нет (docs/PROMPT.md §3 «Сеть»).
public struct ClientProfile: Hashable, Codable, Sendable {
    public var name: String
    public var id: Int
    public var version: String
    public var host: String
    public var userAgent: String
    public var referer: String?
    public var platform: String?
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    public var androidSdkVersion: Int?
    /// User-Agent для запросов к googlevideo, если он должен совпасть с клиентом (ANDROID_VR); `nil` — любой.
    public var mediaUserAgent: String?

    public init(
        name: String, id: Int, version: String, host: String, userAgent: String, referer: String? = nil,
        platform: String? = nil, deviceMake: String? = nil, deviceModel: String? = nil, osName: String? = nil,
        osVersion: String? = nil, androidSdkVersion: Int? = nil, mediaUserAgent: String? = nil
    ) {
        self.name = name
        self.id = id
        self.version = version
        self.host = host
        self.userAgent = userAgent
        self.referer = referer
        self.platform = platform
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.osName = osName
        self.osVersion = osVersion
        self.androidSdkVersion = androidSdkVersion
        self.mediaUserAgent = mediaUserAgent
    }

    /// YouTube Music в браузере: поиск, страницы, очередь.
    public static let webRemix = ClientProfile(
        name: "WEB_REMIX", id: 67, version: "1.20260922.01.00", host: "music.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        referer: "https://music.youtube.com/", platform: "DESKTOP"
    )

    /// Обычный YouTube: видео, каналы, трансляции вне каталога YTM.
    public static let web = ClientProfile(
        name: "WEB", id: 1, version: "2.20260924.00.00", host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        referer: "https://www.youtube.com/", platform: "DESKTOP"
    )

    /// Поток (сентябрь 2026): прямые ссылки без PO-токена. Нужен `visitorData`, иначе «Sign in to confirm you’re not
    /// a bot» (docs/PROMPT.md §4). Параметры — как у Windows и yt-dlp 2026.08.19.
    public static let visionOS = ClientProfile(
        name: "VISIONOS", id: 101, version: "1.02", host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        referer: "https://www.youtube.com/", deviceMake: "Apple", deviceModel: "RealityDevice17,1",
        osName: "visionOS", osVersion: "26.5.23O471"
    )

    /// Запасной клиент потока; googlevideo он читает с тем же User-Agent.
    public static let androidVR = ClientProfile(
        name: "ANDROID_VR", id: 28, version: "1.65.10", host: "www.youtube.com",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        deviceMake: "Oculus", deviceModel: "Quest 3", osName: "Android", osVersion: "12L", androidSdkVersion: 32,
        mediaUserAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    )

    /// Только синхронный текст YouTube Music (`timedLyricsModel`).
    public static let androidMusic = ClientProfile(
        name: "ANDROID_MUSIC", id: 21, version: "7.27.52", host: "music.youtube.com",
        userAgent: "com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 11) gzip",
        platform: "MOBILE", osName: "Android", osVersion: "11", androidSdkVersion: 30
    )
}
