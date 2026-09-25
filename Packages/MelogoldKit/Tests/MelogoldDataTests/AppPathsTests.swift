import Foundation
import Testing
@testable import MelogoldData
import MelogoldCore

@Suite("Папки и настройки")
struct AppPathsTests {
    @Test func cacheAndDownloadsAreExcludedFromBackup() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try paths.prepare()
        #expect(AppPaths.isExcludedFromBackup(paths.audioCache))
        #expect(AppPaths.isExcludedFromBackup(paths.downloads))
        #expect(!AppPaths.isExcludedFromBackup(paths.logs))
        #expect(paths.database.lastPathComponent == "melogold.sqlite")
    }

    @MainActor
    @Test func settingsUseAndroidKeysAndKeepDefaultsUnwritten() throws {
        let suite = "melogold-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.lastTab == .trends)
        #expect(settings.theme == .system)
        #expect(settings.cacheLimit == AppSettings.defaultCacheLimit)
        #expect(settings.serverURL == ServerDefaults.baseURL)

        settings.lastTab = .library
        settings.theme = .dark
        settings.normalization = false
        #expect(defaults.string(forKey: "shell.lastTab") == "library")
        #expect(defaults.string(forKey: "theme.mode") == "dark")
        #expect(defaults.object(forKey: "playback.normalization") as? Bool == false)

        settings.theme = .system
        #expect(defaults.object(forKey: "theme.mode") == nil)
        #expect(defaults.object(forKey: "cache.streamLimit") == nil)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.lastTab == .library)
        #expect(reloaded.normalization == false)
    }
}
