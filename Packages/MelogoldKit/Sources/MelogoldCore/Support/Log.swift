import Foundation
import os

/// Журнал приложения (docs/PROMPT.md §3 «Логи»): `Logger` (os.log) и свой файл до 2 МБ.
///
/// - при старте `melogold.log` переименовывается в `melogold.previous.log` — прошлый запуск остаётся для «Диагностики»;
/// - если файл дорос до 2 МБ, он так же уходит в `previous`, и запись идёт в новый;
/// - запись в файл — на своей очереди, вызывающий код не ждёт диска.
///
/// Секретов в журнал не пишем: токены, пароли и коды восстановления сюда не попадают никогда.
public enum Log {
    public static let subsystem = "app.melogold.Melogold"
    public static let fileName = "melogold.log"
    public static let previousFileName = "melogold.previous.log"
    public static let maxFileBytes = 2 * 1024 * 1024

    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    /// Включает запись в файл: папка создаётся, прошлый файл становится `previous`. Вызывать один раз при старте.
    public static func configure(directory: URL) {
        sink.configure(directory: directory)
    }

    /// Папка журнала, если `configure` уже вызван.
    public static var directory: URL? { sink.directory }

    public static func debug(_ category: String, _ message: @autoclosure () -> String) {
        write(.debug, category, message())
    }

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        write(.info, category, message())
    }

    public static func warning(_ category: String, _ message: @autoclosure () -> String) {
        write(.warning, category, message())
    }

    public static func error(_ category: String, _ message: @autoclosure () -> String) {
        write(.error, category, message())
    }

    /// Дождаться записи всего, что уже отправлено в файл (тесты, «Диагностика» перед архивом).
    public static func flush() {
        sink.flush()
    }

    private static func write(_ level: Level, _ category: String, _ message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        sink.append(level: level, category: category, message: message)
    }

    private static let sink = FileLogSink()
}

/// Файл журнала с ротацией. Все обращения к диску — на одной последовательной очереди.
final class FileLogSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.melogold.log", qos: .utility)
    private let lock = NSLock()
    private var _directory: URL?
    private var handle: FileHandle?
    private var bytesWritten = 0

    private static let timestamp: Date.ISO8601FormatStyle = .iso8601
        .year().month().day()
        .dateSeparator(.dash)
        .time(includingFractionalSeconds: true)
        .timeSeparator(.colon)

    var directory: URL? {
        lock.withLock { _directory }
    }

    func configure(directory: URL) {
        lock.withLock { _directory = directory }
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = directory.appendingPathComponent(Log.fileName)
            let previous = directory.appendingPathComponent(Log.previousFileName)
            try? handle?.close()
            handle = nil
            if fm.fileExists(atPath: current.path) {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: current, to: previous)
            }
            openFresh(at: current)
        }
    }

    func append(level: Log.Level, category: String, message: String) {
        let line = "\(Date().formatted(Self.timestamp)) \(level.rawValue) [\(category)] \(message)\n"
        queue.async { [self] in
            guard handle != nil, let data = line.data(using: .utf8) else { return }
            if bytesWritten + data.count > Log.maxFileBytes {
                rotate()
            }
            guard let current = handle else { return }
            do {
                try current.write(contentsOf: data)
                bytesWritten += data.count
            } catch {
                // Диск полон или файл пропал: журнал не должен ронять приложение.
            }
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    private func rotate() {
        guard let directory = lock.withLock({ _directory }) else { return }
        let fm = FileManager.default
        let current = directory.appendingPathComponent(Log.fileName)
        let previous = directory.appendingPathComponent(Log.previousFileName)
        try? handle?.close()
        handle = nil
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: current, to: previous)
        openFresh(at: current)
    }

    private func openFresh(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        bytesWritten = 0
    }
}
