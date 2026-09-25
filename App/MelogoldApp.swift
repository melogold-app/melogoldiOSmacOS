import SwiftUI
import MelogoldCore
import MelogoldData

@main
struct MelogoldApp: App {
    @State private var model: AppModel

    init() {
        let paths: AppPaths?
        do {
            let standard = try AppPaths.standard()
            try standard.prepare()
            paths = standard
        } catch {
            paths = nil
        }
        if let paths {
            Log.configure(directory: paths.logs)
            CrashDiagnostics.shared.start(directory: paths.logs)
        }
        Log.info("app", "Melogold \(AppVersion.current) (\(AppVersion.build)) запущен")
        _model = State(initialValue: AppModel(settings: AppSettings(), paths: paths))
    }

    var body: some Scene {
        #if os(macOS)
        // Одно главное окно (docs/PROMPT.md §5.4): закрытие окна не останавливает музыку, Dock открывает его снова.
        Window(Text(verbatim: "Melogold"), id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    applyMacAppearance()
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested()
                    #endif
                }
                .onChange(of: model.settings.theme) { applyMacAppearance() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands { MelogoldCommands(model: model) }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        #endif
    }

    #if os(macOS)
    /// На Mac тема применяется к приложению целиком: `preferredColorScheme` не трогает меню и системные окна.
    private func applyMacAppearance() {
        switch model.settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    #endif
}
