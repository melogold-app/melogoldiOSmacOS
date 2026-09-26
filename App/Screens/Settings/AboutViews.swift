import SwiftUI
import UniformTypeIdentifiers
import MelogoldCore
import MelogoldData
import MelogoldPlayback
#if os(macOS)
import AppKit
#endif

/// «О приложении» (docs/PROMPT.md §5.9): версия, «Проверить обновления…» (Mac), «Диагностика», «Лицензии», исходный код.
struct AboutSettingsSection: View {
    var body: some View {
        Section("settings.about") {
            LabeledContent {
                Text(verbatim: "\(AppVersion.current) (\(AppVersion.build))")
                    .textSelection(.enabled)
            } label: {
                Text("settings.version")
            }
            #if os(macOS)
            CheckForUpdatesButton()
            #endif
            NavigationLink(value: Route.diagnostics) { Text("settings.diagnostics") }
            NavigationLink(value: Route.licenses) { Text("settings.licenses") }
            Link(destination: URL(string: "https://github.com/melogold-app/melogoldiOSmacOS")!) {
                Text("settings.sourceCode")
            }
        }
    }
}

// MARK: - Диагностика

/// «Диагностика» (docs/PROMPT.md §3 «Логи», REWRITE §3.5.10): версии, «Проверить извлечение», «Экспорт отчёта»;
/// на Mac — «Показать в Finder».
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var clients: [String] = []
    @State private var testing = false
    @State private var testResult: TestResult?

    /// Трек для проверки: песня YouTube Music, которая есть давно («Группа крови»). Звук не играет — только адрес.
    static let testVideoId = "xtxjm7ciwmc"

    enum TestResult {
        case success(client: String, itag: Int, milliseconds: Int)
        case failure(StreamError.Kind, String)
    }

    var body: some View {
        Form {
            Section("diagnostics.versions") {
                LabeledContent("diagnostics.app") {
                    Text(verbatim: "\(AppVersion.current) (\(AppVersion.build))")
                }
                LabeledContent("diagnostics.system") { Text(verbatim: DeviceInfo.system) }
                LabeledContent("diagnostics.device") { Text(verbatim: DeviceInfo.model) }
                LabeledContent("diagnostics.clients") { Text(verbatim: clients.joined(separator: ", ")) }
            }
            .textSelection(.enabled)

            Section {
                HStack {
                    Button("diagnostics.test") { runTest() }
                        .disabled(testing)
                    if testing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
                if let testResult {
                    switch testResult {
                    case .success(let client, let itag, let milliseconds):
                        Label {
                            Text("diagnostics.test.ok \(client) \(itag) \(milliseconds)")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    case .failure(let kind, let message):
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.text)
                                Text(verbatim: message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section {
                ShareLink(item: DiagnosticReportFile(model: model), preview: SharePreview(Text("diagnostics.export"))) {
                    Text("diagnostics.export")
                }
                #if os(macOS)
                Button("diagnostics.showInFinder") {
                    guard let logs = model.services.paths?.logs else { return }
                    Log.flush()
                    let file = logs.appendingPathComponent(Log.fileName)
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : logs])
                }
                #endif
                if let crash = CrashDiagnostics.shared.lastCrashFile,
                   let date = (try? crash.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    LabeledContent("diagnostics.lastCrash") {
                        Text(date, format: .dateTime.day().month().hour().minute())
                    }
                }
            } footer: {
                Text("diagnostics.exportFooter")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("settings.diagnostics"))
        .inlineTitle()
        .task { clients = await model.services.resolver.clientNames }
    }

    /// Свежий адрес потока тестового трека: сначала забыть прежний, затем спросить клиентов по порядку.
    private func runTest() {
        testing = true
        testResult = nil
        let resolver = model.services.resolver
        Task {
            let started = Date()
            await resolver.invalidate(Self.testVideoId)
            do {
                let info = try await resolver.resolve(Self.testVideoId)
                testResult = .success(client: info.source, itag: info.itag,
                                      milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            } catch let error as StreamError {
                testResult = .failure(error.kind, error.message)
            } catch {
                testResult = .failure(.network, error.localizedDescription)
            }
            testing = false
        }
    }
}

private extension StreamError.Kind {
    var text: LocalizedStringResource {
        switch self {
        case .network: "player.error.network"
        case .timeout: "player.error.timeout"
        case .botCheck: "player.error.botCheck"
        case .geo: "player.error.geo"
        case .unavailable: "player.error.unavailable"
        case .age: "player.error.age"
        case .extractor: "player.error.extractor"
        }
    }
}

/// Версии для «Диагностики» и отчёта.
enum DeviceInfo {
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #elseif os(visionOS)
        let name = "visionOS"
        #else
        let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `Mac14,7`, `iPhone18,1`; в симуляторе — модель, которую он изображает.
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        #endif
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// zip отчёта для «Поделиться»: собирается, только когда его действительно отправляют.
struct DiagnosticReportFile: Transferable {
    let summary: String
    let logs: URL?
    let database: AppDatabase?

    @MainActor
    init(model: AppModel) {
        summary = """
        Melogold \(AppVersion.current) (\(AppVersion.build))
        \(DeviceInfo.system) · \(DeviceInfo.model)
        \(Locale.current.identifier)
        """
        logs = model.services.paths?.logs
        database = model.services.database
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { report in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("report", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let zip = try DiagnosticReport.build(summary: report.summary, logs: report.logs, database: report.database, into: directory)
            return SentTransferredFile(zip)
        }
    }
}

// MARK: - Лицензии

/// «Лицензии»: сам Melogold (GPL-3.0) и библиотеки, которые едут внутри. Нажатие открывает текст лицензии.
struct LicensesView: View {
    struct Item: Identifiable {
        let name: String
        let license: String
        let file: String
        var id: String { file }
    }

    static var items: [Item] {
        var list = [
            Item(name: "Melogold", license: "GNU GPL 3.0", file: "Melogold"),
            Item(name: "GRDB.swift", license: "MIT", file: "GRDB"),
        ]
        #if os(macOS)
        list.append(Item(name: "Sparkle", license: "MIT", file: "Sparkle"))
        #endif
        return list
    }

    var body: some View {
        List(Self.items) { item in
            NavigationLink {
                LicenseTextView(item: item)
            } label: {
                LabeledContent {
                    Text(verbatim: item.license)
                } label: {
                    Text(verbatim: item.name)
                }
            }
        }
        .navigationTitle(Text("settings.licenses"))
        .inlineTitle()
    }
}

private struct LicenseTextView: View {
    let item: LicensesView.Item

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: item.name))
        .inlineTitle()
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: item.file, withExtension: "txt", subdirectory: "Licenses")
                ?? Bundle.main.url(forResource: item.file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return item.license }
        return text
    }
}
