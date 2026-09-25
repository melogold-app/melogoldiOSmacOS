import Foundation

/// Сессия для обложек: свой дисковый кэш в `Caches` (docs/PROMPT.md §3 «Данные») и общие настройки сети.
public enum ArtworkSession {
    nonisolated(unsafe) private static var configuredCache: URLCache?
    private static let lock = NSLock()

    /// Задать кэш обложек до первого запроса (папка `Caches/Melogold/Artwork`).
    public static func configure(directory: URL) {
        lock.withLock {
            configuredCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20, directory: directory)
        }
    }

    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = lock.withLock { configuredCache } ?? URLCache.shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        HTTPConfiguration.apply(to: configuration)
        return URLSession(configuration: configuration)
    }()

    /// Сколько занимают обложки на диске.
    public static var diskUsage: Int { (shared.configuration.urlCache ?? URLCache.shared).currentDiskUsage }

    public static func clear() {
        (shared.configuration.urlCache ?? URLCache.shared).removeAllCachedResponses()
    }
}
