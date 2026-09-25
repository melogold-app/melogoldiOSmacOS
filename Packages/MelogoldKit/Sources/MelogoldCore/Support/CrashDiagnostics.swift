import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Последнее падение из MetricKit (`MXCrashDiagnostic`): система отдаёт его при следующем запуске, мы кладём его
/// в отдельный файл рядом с журналом (docs/PROMPT.md §3 «Логи»). На watchOS MetricKit нет — там только журнал.
public final class CrashDiagnostics: NSObject, @unchecked Sendable {
    public static let fileName = "last-crash.json"
    public static let shared = CrashDiagnostics()

    private var directory: URL?

    /// Подписаться на отчёты. `directory` — папка журнала.
    public func start(directory: URL) {
        self.directory = directory
        #if canImport(MetricKit) && !os(watchOS)
        MXMetricManager.shared.add(self)
        #endif
    }

    /// Файл последнего падения, если он есть.
    public var lastCrashFile: URL? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(Self.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    fileprivate func store(_ json: Data) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(Self.fileName)
        do {
            try json.write(to: url, options: .atomic)
            Log.warning("crash", "MetricKit: получен отчёт о падении, записан в \(Self.fileName)")
        } catch {
            Log.error("crash", "Не удалось записать отчёт о падении: \(error.localizedDescription)")
        }
    }
}

#if canImport(MetricKit) && !os(watchOS)
extension CrashDiagnostics: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty {
            store(payload.jsonRepresentation())
        }
    }
}
#endif
