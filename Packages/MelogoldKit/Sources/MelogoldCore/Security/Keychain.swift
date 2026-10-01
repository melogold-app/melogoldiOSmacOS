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
///
/// В Keychain входа запись по умолчанию доступна только программе, которая её создала, и когда подпись программы
/// меняется (сборка из Xcode, другой сертификат), система спрашивает пароль входа: «Melogold хочет получить доступ к
/// ключу…». Поэтому на Mac записи создаются с доступом «любой программе пользователя» (`SecAccessCreate` без списка
/// доверенных программ) — вопрос больше не возникает; старая запись один раз читается (с вопросом, если он будет) и
/// тут же записывается заново так же.
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
        let value = result as? Data
        #if os(macOS)
        if let value { openAccessIfNeeded(account, value: value) }
        #endif
        return value
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
        #if os(macOS)
        if let access = openAccess() { insert[kSecAttrAccess as String] = access }
        #endif
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added != errSecSuccess { Log.error("keychain", "Запись не добавилась: \(added)") }
        return added == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        let status = SecItemDelete(base(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    #if os(macOS)
    /// Доступ «любой программе пользователя без вопроса»: список доверенных программ — `nil`. `SecAccessCreate` помечена
    /// устаревшей вместе со всем Keychain входа, но замены для доступа без вопроса у него нет (запись с защитой данных
    /// требует подписи командой разработчика), поэтому функция берётся по имени, а не по ссылке на устаревший символ.
    private func openAccess() -> SecAccess? {
        typealias Create = @convention(c) (CFString, CFArray?, UnsafeMutablePointer<SecAccess?>) -> OSStatus
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "SecAccessCreate") else { return nil }
        var access: SecAccess?
        let create = unsafeBitCast(symbol, to: Create.self)
        return create(service as CFString, nil, &access) == errSecSuccess ? access : nil
    }

    private var openFlagKey: String { "keychain.openAccess.\(service)" }

    /// Запись, созданная прежней версией, ограничена её подписью: прочитанную записываем заново с открытым доступом,
    /// один раз на запись.
    private func openAccessIfNeeded(_ account: String, value: Data) {
        let defaults = UserDefaults.standard
        var done = Set(defaults.stringArray(forKey: openFlagKey) ?? [])
        guard !done.contains(account), let access = openAccess() else { return }
        _ = SecItemDelete(base(account) as CFDictionary)
        var insert = base(account)
        insert[kSecValueData as String] = value
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrAccess as String] = access
        if SecItemAdd(insert as CFDictionary, nil) == errSecSuccess {
            done.insert(account)
            defaults.set(Array(done), forKey: openFlagKey)
        } else {
            // Не вышло — вернуть как было, иначе сеанс потеряется
            insert.removeValue(forKey: kSecAttrAccess as String)
            _ = SecItemAdd(insert as CFDictionary, nil)
        }
    }
    #endif

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
