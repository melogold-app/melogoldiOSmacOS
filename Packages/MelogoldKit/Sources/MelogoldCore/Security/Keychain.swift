import Foundation
import Security
import Synchronization

/// Где лежат секреты устройства: токены сессии и `platformId` (docs/PROMPT.md §3).
public protocol SecretStore: Sendable {
    func data(_ account: String) -> Data?
    @discardableResult func set(_ data: Data, for account: String) -> Bool
    @discardableResult func delete(_ account: String) -> Bool
}

extension SecretStore {
    public func string(_ account: String) -> String? {
        data(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public func set(_ value: String, for account: String) -> Bool {
        set(Data(value.utf8), for: account)
    }
}

/// Секреты в Keychain с `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: доступны в фоне после первой
/// разблокировки, не уходят в резервную копию и не переезжают на новое устройство. Поэтому новое устройство получает
/// новый `hwid`, и сервер видит его отдельной строкой (API §1.6).
///
/// На iPhone, iPad, часах и Vision это всегда Keychain с защитой данных. На Mac — обычный Keychain входа: Keychain с
/// защитой данных там требует подписи командой разработчика, а локальные сборки подписаны ad hoc.
public struct Keychain: SecretStore {
    public let service: String

    /// `service` — пространство имён записей. По умолчанию — идентификатор приложения, у часов он свой.
    public init(service: String = (Bundle.main.bundleIdentifier ?? "app.melogold") + ".secure") {
        self.service = service
    }

    public func data(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public func set(_ data: Data, for account: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            Log.error("keychain", "Запись не обновилась: \(status)")
            return false
        }
        var insert = base(account)
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added != errSecSuccess { Log.error("keychain", "Запись не добавилась: \(added)") }
        return added == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        let status = SecItemDelete(base(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Секреты в памяти: тесты и превью.
public final class MemorySecretStore: SecretStore {
    private let storage = Mutex<[String: Data]>([:])

    public init() {}

    public func data(_ account: String) -> Data? {
        storage.withLock { $0[account] }
    }

    @discardableResult
    public func set(_ data: Data, for account: String) -> Bool {
        storage.withLock { $0[account] = data }
        return true
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        storage.withLock { _ = $0.removeValue(forKey: account) }
        return true
    }
}
