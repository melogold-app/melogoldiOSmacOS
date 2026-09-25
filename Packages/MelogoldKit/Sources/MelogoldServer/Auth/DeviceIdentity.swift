import CryptoKit
import Foundation
import MelogoldCore

#if canImport(UIKit)
import UIKit
#endif
#if os(watchOS)
import WatchKit
#endif
#if os(macOS)
import IOKit
#endif

/// Это устройство для сервера (API §1.2, §1.6, §4.1): платформа, `hwid`, имя, система, модель и версия клиента.
public struct DeviceIdentity: Sendable, Equatable {
    /// `ios`, `ipados`, `macos`, `visionos` или `watchos`.
    public let platform: String
    /// Mac — `IOPlatformUUID`; остальные — UUID v4 из Keychain (API §1.6).
    public let platformId: String
    public let name: String
    public let osVersion: String
    public let model: String
    public let clientVersion: String

    /// Поля устройства — до 64 единиц UTF-16 (API §4.1).
    static let fieldLimit = 64
    static let platformIdAccount = "platformId"

    public init(platform: String, platformId: String, name: String, osVersion: String, model: String, clientVersion: String) {
        self.platform = platform
        self.platformId = platformId
        self.name = Self.clip(name.isEmpty ? "Apple" : name)
        self.osVersion = Self.clip(osVersion)
        self.model = Self.clip(model)
        self.clientVersion = Self.clip(clientVersion)
    }

    /// `melogold-<platform>/<версия>` (API §1.2).
    public var userAgent: String { "melogold-\(platform)/\(clientVersion)" }

    /// `hex(sha256("melogold-hwid-v1|" + platformId + "|" + serverId))`: у каждого сервера свой (API §1.6).
    public func hwid(serverId: String) -> String {
        Self.hwid(platformId: platformId, serverId: serverId)
    }

    public static func hwid(platformId: String, serverId: String) -> String {
        SHA256.hash(data: Data("melogold-hwid-v1|\(platformId)|\(serverId)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func input(serverId: String) -> DeviceInput {
        DeviceInput(
            hwid: hwid(serverId: serverId),
            name: name,
            platform: platform,
            osVersion: osVersion,
            model: model,
            clientVersion: clientVersion
        )
    }

    /// Это устройство. `platformId` создаётся один раз и хранится в `secrets`.
    @MainActor
    public static func current(secrets: any SecretStore) -> DeviceIdentity {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceIdentity(
            platform: currentPlatform,
            platformId: platformId(secrets: secrets),
            name: currentName,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            model: currentModel,
            clientVersion: AppVersion.current
        )
    }

    @MainActor
    static var currentPlatform: String {
        #if os(macOS)
        "macos"
        #elseif os(visionOS)
        "visionos"
        #elseif os(watchOS)
        "watchos"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// Имя, которое видно в списке устройств. На iPhone и iPad без особого права Apple система отдаёт «iPhone» или
    /// «iPad», а не имя владельца, — так и остаётся (docs/PROMPT.md §3).
    @MainActor
    static var currentName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        WKInterfaceDevice.current().name
        #else
        UIDevice.current.name
        #endif
    }

    /// Идентификатор модели: `Mac14,7`, `iPhone18,1`, `Watch7,5`. В симуляторе — модель, которую он изображает.
    static var currentModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        if let model = sysctlString("hw.model") { return model }
        #endif
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func platformId(secrets: any SecretStore) -> String {
        #if os(macOS)
        if let uuid = macPlatformUUID() { return uuid }
        #endif
        if let stored = secrets.string(platformIdAccount), !stored.isEmpty { return stored }
        let created = UUID().uuidString.lowercased()
        secrets.set(created, for: platformIdAccount)
        return created
    }

    /// Обрезка до лимита без разрыва суррогатной пары (API §1.4).
    static func clip(_ text: String) -> String {
        var result = ""
        var units = 0
        for character in text {
            let length = character.utf16.count
            if units + length > fieldLimit { break }
            result.append(character)
            units += length
        }
        return result
    }

    #if os(macOS)
    private static func macPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    #endif
}
