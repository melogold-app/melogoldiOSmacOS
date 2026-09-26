import SwiftUI
import UniformTypeIdentifiers
import MelogoldCore
import MelogoldData

/// Ход и итог импорта копии (задание 0006 §3).
enum LibraryImportState: Identifiable {
    case running
    case done(ImportSummary)
    case failed(ImportFailure)

    /// Один лист на весь импорт: ход сменяется итогом в том же листе.
    var id: String { "import" }

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

/// Готовая копия для системного окна сохранения.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.melogoldBackup] }
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

extension UTType {
    /// Копия приходит как `.db` без надёжного типа (задание 0006 §3): сохраняется с расширением `.db`.
    nonisolated static let melogoldBackup = UTType(filenameExtension: "db", conformingTo: .data) ?? .data
}

extension AppModel {
    /// «Импорт из ViTune или ViMusic» и «Импорт копии»: окно выбора файла.
    func chooseBackupToImport() {
        importPicker = true
    }

    /// Импорт выбранной копии: файл читается под security scope и сразу копируется во временную папку
    /// (`LibraryImport`), сам импорт — не на главном потоке, интерфейс не подвисает.
    /// `debugDelay` — только для снимка хода импорта в отладочной сборке.
    func importBackup(from url: URL, debugDelay: Duration = .zero) {
        guard let database = services.database, importState?.isRunning != true else { return }
        importState = .running
        let version = AppVersion.current
        Task.detached(priority: .userInitiated) { [weak self] in
            if debugDelay > .zero { try? await Task.sleep(for: debugDelay) }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result: LibraryImportState
            do {
                let summary = try LibraryImport.run(url, into: database, appVersion: version)
                Log.info("import", "Импорт копии: \(summary)")
                result = .done(summary)
            } catch let failure as ImportFailure {
                Log.warning("import", "Импорт копии не удался: \(failure)")
                result = .failed(failure)
            } catch {
                Log.warning("import", "Импорт копии не удался: \(error)")
                result = .failed(.unreadable)
            }
            await MainActor.run { self?.importState = result }
        }
    }

    /// «Сохранить копию»: снимок библиотеки во временную папку, затем системное окно сохранения.
    func saveBackup() {
        guard let source = services.paths?.database else { return }
        let platform = Self.backupPlatform
        let version = AppVersion.current
        Task.detached(priority: .userInitiated) { [weak self] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(LibraryBackup.suggestedName())
            do {
                try LibraryBackup.export(databaseAt: source, to: target, platform: platform, appVersion: version)
                await MainActor.run { self?.backupDocument = BackupDocument(url: target) }
            } catch {
                Log.warning("import", "Копия не сохранена: \(error)")
                await MainActor.run { self?.toast = Toast(text: String(localized: "backup.failed")) }
            }
        }
    }

    /// `platform` метки копии (API §1.6).
    static var backupPlatform: String {
        #if os(macOS)
        "macos"
        #elseif os(visionOS)
        "visionos"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }
}

/// Окно выбора копии, лист хода и итога импорта, окно сохранения копии — на корне окна.
struct LibraryTransferModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            // Каждое окно файлов — на своём пустом виде: два `fileImporter`/`fileExporter` на одном виде SwiftUI не
            // показывает (второй молчит), а на корне уже есть «Сохранить файлом».
            .background {
                // Копии приходят как .db без надёжного типа — выбор любого файла
                Color.clear.fileImporter(isPresented: $model.importPicker, allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { model.importBackup(from: url) }
                }
            }
            .background {
                Color.clear.fileExporter(
                    isPresented: Binding(get: { model.backupDocument != nil }, set: { if !$0 { model.backupDocument = nil } }),
                    document: model.backupDocument, contentType: .melogoldBackup,
                    defaultFilename: model.backupDocument?.url.lastPathComponent
                ) { result in
                    if case .success = result { model.toast = Toast(text: String(localized: "backup.saved")) }
                    if let url = model.backupDocument?.url { try? FileManager.default.removeItem(at: url) }
                    model.backupDocument = nil
                }
            }
            .sheet(item: $model.importState) { state in
                ImportProgressView(state: state)
                    .interactiveDismissDisabled(state.isRunning)
            }
    }
}

/// «Импортируем библиотеку…» → «Библиотека импортирована» с числами и примечаниями, «Открыть историю» и «Готово»;
/// или «Не удалось импортировать» с причиной.
struct ImportProgressView: View {
    @Environment(AppModel.self) private var model
    let state: LibraryImportState

    var body: some View {
        Group {
            switch state {
            case .running:
                VStack(spacing: 20) {
                    ProgressView()
                        .controlSize(.large)
                    Text("import.running")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let summary):
                result(icon: "checkmark.circle.fill", tint: .green, title: "import.doneTitle") {
                    Text("import.summary \(summary.tracks) \(summary.plays) \(summary.favorites) \(summary.lyrics) \(summary.playlists) \(summary.saved)")
                    ForEach(notes(summary), id: \.key) { note in
                        Text(note).foregroundStyle(.secondary)
                    }
                }
            case .failed(let failure):
                result(icon: "exclamationmark.triangle.fill", tint: .orange, title: "import.failedTitle") {
                    Text(reason(failure))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .presentationDetents(state.isRunning ? [.medium] : [.medium, .large])
    }

    /// Итог: значок, заголовок и текст прокручиваются, кнопки — внизу.
    private func result(icon: String, tint: Color, title: LocalizedStringResource,
                        @ViewBuilder text: () -> some View) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 52))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                VStack(spacing: 10) {
                    text()
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if case .done = state {
                    Button {
                        model.importState = nil
                        model.open(.history, in: .library)
                    } label: {
                        Text("import.openHistory").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    model.importState = nil
                } label: {
                    Text("common.done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func notes(_ summary: ImportSummary) -> [LocalizedStringResource] {
        var notes: [LocalizedStringResource] = []
        if summary.playsKnown > 0 { notes.append("import.playsKnown \(summary.playsKnown)") }
        if summary.localSkipped > 0 { notes.append("import.localSkipped \(summary.localSkipped)") }
        if summary.datesSkipped > 0 { notes.append("import.datesSkipped \(summary.datesSkipped)") }
        if model.account.isSignedIn, summary.plays > 0 { notes.append("import.syncNote") }
        return notes
    }

    private func reason(_ failure: ImportFailure) -> LocalizedStringResource {
        switch failure {
        case .notABackup: "import.notBackup"
        case .tooOld: "import.tooOld"
        case .unsupported: "import.unsupported"
        case .unreadable: "import.unreadable"
        }
    }
}
