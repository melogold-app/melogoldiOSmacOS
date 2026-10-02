import Foundation
import Synchronization

/// Секреты Mac в файле `Application Support/Melogold/secrets.json` с правами 0600 (читает только владелец), вне
/// резервной копии — как `ThisDeviceOnly` у Keychain на остальных платформах.
///
/// Почему не Keychain входа: Mac-сборки подписаны своим сертификатом без команды разработчика Apple, и система
/// привязывает запись к хешу кода конкретной сборки. Новая версия, перезаписав сеанс при обновлении токена, отбирала
/// запись у прежней, а следующая версия снова получала окно «Melogold хочет получить доступ к ключу…» с паролем входа —
/// после каждого обновления, «Всегда разрешать» не помогало (проверено двумя сборками с разным хешем, 2026-10-02).
/// Keychain с защитой данных требует подписи командой разработчика. Открытый доступ к записи Keychain (как было в 0.2.4)
/// и так позволял читать её любой программе пользователя, файл 0600 — та же защита, но без вопросов.
///
/// Записи прежних версий переезжают из Keychain при первом чтении (`legacy`), один раз на запись: если запись к тому
/// времени привязана к другой сборке, система спросит пароль в последний раз; «Запретить» — значит войти заново.
public final class SecretFile: SecretStore, @unchecked Sendable {
    private struct Contents: Codable {
        var values: [String: Data] = [:]
        /// Записи, которые уже искали в Keychain прежних версий: после выхода из аккаунта старый сеанс не воскресает.
        var migrated: Set<String> = []
    }

    public let url: URL
    private let legacy: (any SecretStore)?
    private let state = Mutex<Contents?>(nil)

    public init(url: URL, legacy: (any SecretStore)? = nil) {
        self.url = url
        self.legacy = legacy
    }

    public func data(_ account: String) -> Data? {
        state.withLock { cached in
            var contents = cached ?? load()
            defer { cached = contents }
            if let value = contents.values[account] { return value }
            guard let legacy, !contents.migrated.contains(account) else { return nil }
            contents.migrated.insert(account)
            let value = legacy.data(account)
            if let value { contents.values[account] = value }
            save(contents)
            if value != nil { legacy.delete(account) }
            return value
        }
    }

    @discardableResult
    public func set(_ data: Data, for account: String) -> Bool {
        state.withLock { cached in
            var contents = cached ?? load()
            contents.values[account] = data
            // Новое значение главнее старой записи Keychain: искать её больше незачем
            contents.migrated.insert(account)
            cached = contents
            return save(contents)
        }
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        state.withLock { cached in
            var contents = cached ?? load()
            contents.values.removeValue(forKey: account)
            contents.migrated.insert(account)
            cached = contents
            return save(contents)
        }
    }

    private func load() -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents() }
        return (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
    }

    @discardableResult
    private func save(_ contents: Contents) -> Bool {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(contents)
            // Сначала файл с правами 0600 во временном имени, потом замена: чужие права не успевают появиться ни на миг
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                Log.error("secrets", "Файл секретов не записался")
                return false
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try target.setResourceValues(values)
            return true
        } catch {
            Log.error("secrets", "Файл секретов не записался: \(error.localizedDescription)")
            return false
        }
    }
}
