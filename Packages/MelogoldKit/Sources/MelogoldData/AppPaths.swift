import Foundation
import MelogoldCore

/// Папки приложения (docs/PROMPT.md §3 «Данные»).
///
/// - база, журнал, кэш музыки и загрузки — в `Application Support/Melogold/`: из `Caches` система стирает файлы,
///   когда места мало, а музыка должна оставаться (на Android кэш перенесли из системного cache по той же причине);
/// - папкам кэша и загрузок — `isExcludedFromBackup`: гигабайты музыки не уходят в резервную копию iCloud;
/// - обложки — в `Caches`: их не жалко, система может их стереть.
public struct AppPaths: Sendable {
    public let root: URL
    public let caches: URL

    public var database: URL { root.appendingPathComponent("melogold.sqlite") }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var audioCache: URL { root.appendingPathComponent("AudioCache", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var artwork: URL { caches.appendingPathComponent("Artwork", isDirectory: true) }

    public init(root: URL, caches: URL) {
        self.root = root
        self.caches = caches
    }

    /// Стандартные папки: `Application Support/Melogold` и `Caches/Melogold`.
    public static func standard(fileManager: FileManager = .default) throws -> AppPaths {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AppPaths(
            root: support.appendingPathComponent("Melogold", isDirectory: true),
            caches: caches.appendingPathComponent("Melogold", isDirectory: true)
        )
    }

    /// Создаёт папки и помечает кэш музыки и загрузки как не входящие в резервную копию.
    public func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, logs, audioCache, downloads, artwork] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for directory in [audioCache, downloads] {
            try Self.excludeFromBackup(directory)
        }
    }

    /// Стоит ли у папки `isExcludedFromBackup` — проверка для «Диагностики» и тестов.
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }
}
