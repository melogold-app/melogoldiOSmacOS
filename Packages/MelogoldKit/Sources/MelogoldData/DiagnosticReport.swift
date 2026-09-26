import Foundation
import GRDB
import MelogoldCore

/// «Экспорт отчёта» в «Диагностике» (docs/PROMPT.md §3 «Логи», REWRITE §3.5.10): zip с журналом этого и прошлого
/// запуска, последним падением и `report.txt` — версии, настройки без секретов, счётчики таблиц.
///
/// Секретов в отчёте нет: токены живут в Keychain, из `UserDefaults` берутся только ключи настроек Melogold.
public enum DiagnosticReport {
    /// Ключи настроек, которые попадают в отчёт (реестр Android, `SettingsKey`).
    static let settingPrefixes = ["theme.", "shell.", "search.", "playback.", "lyrics.", "history.", "filter.", "downloads.",
                                  "cache.", "server.", "sort."]
    /// Слова, по которым ключ не попадает в отчёт никогда, даже с разрешённым префиксом.
    static let secretWords = ["token", "password", "secret", "recovery", "code", "key"]

    /// Таблицы, число строк которых идёт в отчёт.
    static let tables = ["tracks", "albums", "artists", "playlists", "playlist_items", "play_events", "search_history",
                         "lyrics", "content_blocks", "downloads"]

    /// Собрать отчёт в `directory` и вернуть адрес zip-файла `Melogold-report-ггггММдд-ЧЧмм.zip`.
    public static func build(summary: String, logs: URL?, database: AppDatabase?, defaults: UserDefaults = .standard,
                             into directory: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let stamp = Self.stamp(now)
        let folder = directory.appendingPathComponent("Melogold-report-\(stamp)", isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        Log.flush()
        if let logs {
            for name in [Log.fileName, Log.previousFileName, CrashDiagnostics.fileName] {
                let source = logs.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: folder.appendingPathComponent(name))
                }
            }
        }
        let text = report(summary: summary, database: database, defaults: defaults)
        try Data(text.utf8).write(to: folder.appendingPathComponent("report.txt"))

        let zip = directory.appendingPathComponent("Melogold-report-\(stamp).zip")
        try? fm.removeItem(at: zip)
        try Self.zip(folder, to: zip)
        return zip
    }

    /// Текст `report.txt`.
    public static func report(summary: String, database: AppDatabase?, defaults: UserDefaults) -> String {
        var lines = [summary, "", "[settings]"]
        for (key, value) in settings(defaults) {
            lines.append("\(key) = \(value)")
        }
        lines.append("")
        lines.append("[tables]")
        if let database {
            for (table, count) in tableCounts(database) {
                lines.append("\(table) = \(count)")
            }
        } else {
            lines.append("база не открыта")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Настройки Melogold из `UserDefaults`, без секретов, по алфавиту.
    public static func settings(_ defaults: UserDefaults) -> [(String, String)] {
        defaults.dictionaryRepresentation()
            .filter { key, _ in
                let lower = key.lowercased()
                return settingPrefixes.contains { key.hasPrefix($0) } && !secretWords.contains { lower.contains($0) }
            }
            .map { ($0.key, "\($0.value)") }
            .sorted { $0.0 < $1.0 }
    }

    /// Число строк в таблицах библиотеки; таблицы, которой нет, в списке нет.
    public static func tableCounts(_ database: AppDatabase) -> [(String, Int)] {
        (try? database.writer.read { db in
            try tables.compactMap { table -> (String, Int)? in
                guard try db.tableExists(table) else { return nil }
                return (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
            }
        }) ?? []
    }

    /// zip папки средствами системы: координатор файлов отдаёт папку «для выгрузки» уже упакованной.
    static func zip(_ folder: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }
}
