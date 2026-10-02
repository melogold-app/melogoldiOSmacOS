import Foundation
import Testing
@testable import MelogoldCore

/// Секреты Mac в файле вместо Keychain входа: без окна с паролем после обновлений.
@Suite("Файл секретов")
struct SecretFileTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("secret-file-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }

    @Test func keepsValuesBetweenLaunchesWithOwnerOnlyAccess() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(SecretFile(url: url).set("token", for: "session"))
        #expect(SecretFile(url: url).string("session") == "token")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect((try url.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true)
    }

    @Test func movesLegacyKeychainValueOnce() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = MemorySecretStore()
        legacy.set("old-token", for: "session")
        let store = SecretFile(url: url, legacy: legacy)
        #expect(store.string("session") == "old-token")
        // Запись Keychain удалена, значение — в файле
        #expect(legacy.data("session") == nil)
        #expect(SecretFile(url: url).string("session") == "old-token")
    }

    @Test func signedOutSessionDoesNotComeBackFromKeychain() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = MemorySecretStore()
        legacy.set("old-token", for: "session")
        let store = SecretFile(url: url, legacy: legacy)
        _ = store.string("session")
        store.delete("session")
        // Даже если удалить запись Keychain не вышло (её держит другая сборка), после выхода она не воскресает
        legacy.set("old-token", for: "session")
        #expect(SecretFile(url: url, legacy: legacy).string("session") == nil)
    }

    @Test func newValueWinsOverLegacy() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = MemorySecretStore()
        legacy.set("old-token", for: "session")
        let store = SecretFile(url: url, legacy: legacy)
        store.set("new-token", for: "session")
        #expect(SecretFile(url: url, legacy: legacy).string("session") == "new-token")
    }
}
