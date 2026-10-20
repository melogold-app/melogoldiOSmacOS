import Foundation
import Testing
import MelogoldCore
@testable import MelogoldData

/// Настройки устройства в `UserDefaults`.
@MainActor
@Suite("Настройки устройства")
struct AppSettingsTests {
    /// «Живой фон» (задания 0030 и 0031): включён по умолчанию, выбор переживает перезапуск, значение по умолчанию не
    /// пишется.
    @Test func liveBackgroundIsOnByDefaultAndPersists() throws {
        let suite = "melogold.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.liveBackground)
        settings.liveBackground = false
        #expect(!AppSettings(defaults: defaults).liveBackground)
        settings.liveBackground = true
        #expect(defaults.object(forKey: SettingsKey.liveBackground) == nil)
        #expect(AppSettings(defaults: defaults).liveBackground)
    }
}
