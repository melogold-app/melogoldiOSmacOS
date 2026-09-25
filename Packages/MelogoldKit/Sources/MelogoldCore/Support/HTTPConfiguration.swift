import Foundation

/// Общие настройки сессий URLSession приложения. Прокси — только для отладки на симуляторе (`-MelogoldDebugProxy`):
/// когда на Mac включён VPN, симулятор не разрешает имена сам, а процесс-прокси на Mac — разрешает.
public enum HTTPConfiguration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var proxy: (host: String, port: Int)?

    /// Задать прокси до создания сессий: `"127.0.0.1:8899"`.
    public static func setDebugProxy(_ value: String?) {
        guard let value, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { return }
        lock.withLock { proxy = (String(value[..<colon]), port) }
    }

    /// Применить общие настройки к конфигурации сессии.
    public static func apply(to configuration: URLSessionConfiguration) {
        guard let proxy = lock.withLock({ proxy }) else { return }
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true, "HTTPProxy": proxy.host, "HTTPPort": proxy.port,
            "HTTPSEnable": true, "HTTPSProxy": proxy.host, "HTTPSPort": proxy.port,
        ]
    }

    /// Сессия по умолчанию с общими настройками (вместо `URLSession.shared`).
    public static func session(timeout: TimeInterval = 20) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        apply(to: configuration)
        return URLSession(configuration: configuration)
    }
}
