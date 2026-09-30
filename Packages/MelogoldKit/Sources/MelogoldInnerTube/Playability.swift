import Foundation
import MelogoldCore

/// Почему YouTube не играет видео — со слов самого YouTube (задание 0010): спрашивается, когда поток не получен.
public struct Playability: Equatable, Sendable {
    /// `OK`, `UNPLAYABLE`, `LOGIN_REQUIRED`, `ERROR`…
    public let status: String?
    public let reason: String?
    /// Страна, в которой YouTube видит это устройство (из `visitorData`): за VPN, который YouTube считает российским, — `RU`.
    public let country: String?
    /// Где правообладатель открыл видео; пусто, если YouTube не говорит.
    public let availableCountries: [String]

    public init(status: String?, reason: String?, country: String?, availableCountries: [String]) {
        self.status = status
        self.reason = reason
        self.country = country
        self.availableCountries = availableCountries
    }

    /// Правообладатель закрыл видео в стране, где YouTube видит устройство.
    public var isBlockedHere: Bool {
        guard let country, !availableCountries.isEmpty else { return false }
        return !availableCountries.contains(country)
    }

    static func parse(_ response: JSON) -> Playability {
        let web = response.at("microformat", "playerMicroformatRenderer", "availableCountries").array
        let remix = response.at("microformat", "microformatDataRenderer", "availableCountries").array
        return Playability(
            status: response.str("playabilityStatus", "status"),
            reason: response.str("playabilityStatus", "reason"),
            country: VisitorData.country(response.str("responseContext", "visitorData")),
            availableCountries: (web.isEmpty ? remix : web).compactMap(\.string)
        )
    }
}

/// Страна, в которой YouTube разместил запрос, из `visitorData` ответа: base64 url-safe протобуфа, поле 6 — сообщение,
/// в его поле 1 — код страны ISO (`CgtRTWpH…MigKAk5M…` → `NL`). То, по чему решает YouTube, что бы ни говорило устройство.
public enum VisitorData {
    public static func country(_ visitorData: String?) -> String? {
        guard var text = visitorData, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "%3D", with: "=").replacingOccurrences(of: "%3d", with: "=")
        while text.hasSuffix("=") { text.removeLast() }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return nil }
        let bytes = [UInt8](data)
        guard let outer = field(bytes, 0 ..< bytes.count, number: 6), let inner = field(bytes, outer, number: 1),
              let code = String(bytes: bytes[inner], encoding: .utf8),
              code.count == 2, code.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return code
    }

    /// Байты первого поля `number` с длиной (тип 2) в сообщении `bytes[range]`.
    static func field(_ bytes: [UInt8], _ range: Range<Int>, number: Int) -> Range<Int>? {
        var index = range.lowerBound
        while index < range.upperBound {
            guard let (key, afterKey) = varint(bytes, index, range.upperBound) else { return nil }
            index = afterKey
            switch key & 7 {
            case 0:
                guard let (_, next) = varint(bytes, index, range.upperBound) else { return nil }
                index = next
            case 1: index += 8
            case 2:
                guard let (length, start) = varint(bytes, index, range.upperBound), length <= UInt64(range.upperBound - start) else { return nil }
                let end = start + Int(length)
                if Int(key >> 3) == number { return start ..< end }
                index = end
            case 5: index += 4
            default: return nil
            }
        }
        return nil
    }

    static func varint(_ bytes: [UInt8], _ start: Int, _ end: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < end, shift < 64 {
            let byte = bytes[index]
            value |= UInt64(byte & 0x7f) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
        }
        return nil
    }
}

extension YouTubeMusic {
    /// Клиент WEB на `youtubei.googleapis.com`: присылает список стран, даже когда видео не играет. Клиенты потока
    /// (VISIONOS, ANDROID_VR) для этого не годятся.
    static let playabilityProfile: ClientProfile = {
        var profile = ClientProfile.web
        profile.host = "youtubei.googleapis.com"
        return profile
    }()

    /// Диагноз одним запросом `player` клиентом WEB, ответ не проверяется на пригодность; не дольше `timeout`.
    /// `nil` — сети нет или YouTube не ответил.
    public func playability(videoId: String, timeout: Duration = .seconds(8)) async -> Playability? {
        let client = client
        return await withTaskGroup(of: Playability?.self) { group in
            group.addTask {
                guard let response = try? await client.postJSON(Self.playabilityProfile, "player", body: [
                    "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
                ]) else { return nil }
                return Playability.parse(response)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
