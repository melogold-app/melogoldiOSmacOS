import SwiftUI
import MelogoldCore
import MelogoldData

@main
struct MelogoldApp: App {
    @State private var model: AppModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    #endif

    init() {
        let paths: AppPaths?
        do {
            let standard = try Self.debugPaths() ?? AppPaths.standard()
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
        #if DEBUG
        HTTPConfiguration.setDebugProxy(UserDefaults.standard.string(forKey: "MelogoldDebugProxy"))
        #endif
        if let paths {
            // Обложки — в Caches: их не жалко, система может их стереть (docs/PROMPT.md §3 «Данные»).
            ArtworkSession.configure(directory: paths.artwork)
        }
        let services = Services(settings: AppSettings(), paths: paths)
        let model = AppModel(services: services)
        _model = State(initialValue: model)
        // Dock, CarPlay и Siri находят модель окна здесь.
        AppModel.current = model
        #if os(macOS)
        // Sparkle: проверка обновлений сама, не чаще раза в 6 часов (задание 0004)
        _ = AppUpdater.shared
        #endif
    }

    /// `-MelogoldDataDir <папка>` (только отладочная сборка) — своя база, кэш и журнал: снимки на Mac не трогают
    /// настоящую библиотеку.
    private static func debugPaths() -> AppPaths? {
        #if DEBUG
        guard let directory = UserDefaults.standard.string(forKey: "MelogoldDataDir") else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        return AppPaths(root: root.appendingPathComponent("Support", isDirectory: true),
                        caches: root.appendingPathComponent("Caches", isDirectory: true))
        #else
        return nil
        #endif
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
                #if DEBUG
                .modifier(DebugWindowOpener())
                #endif
        }
        .defaultSize(width: 1100, height: 720)
        .commands { MelogoldCommands(model: model) }

        // Мини-плеер — маленькое окно поверх остальных (docs/PROMPT.md §5.4), из меню «Окно».
        Window(Text("window.miniPlayer"), id: "mini") {
            MacMiniPlayer()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        #if os(visionOS)
        // «Сейчас играет» с текстом — отдельное окно, его можно поставить рядом (docs/PROMPT.md §5.5).
        WindowGroup(id: "nowPlaying") {
            NowPlayingView()
                .environment(model)
                .onAppear { model.lyricsVisible = true }
        }
        .defaultSize(width: 1100, height: 700)
        #endif
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
