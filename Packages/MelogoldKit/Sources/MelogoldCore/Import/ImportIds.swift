import CryptoKit
import Foundation

/// Id прослушиваний из копии ViTune или ViMusic (spec/backup-format.md §3, Android `ImportIds`): UUIDv5 строки
/// `"<videoId>|<timestamp>|<playTime>"` в пространстве `NS_MELOGOLD_IMPORT`. Одна копия, импортированная на двух
/// устройствах, даёт те же id — история на сервере не удваивается. Векторы — `spec/import-ids.vectors.json`.
public enum ImportIds {
    /// `NS_MELOGOLD_IMPORT` (REWRITE §4.5.3).
    public static let namespace = UUID(uuidString: "4a3b8c8a-1d9c-48f2-938b-3077d54ab4fb")!

    /// Id прослушивания; `playTimeMs` — уже зажатое в 1…86 400 000, как хранится.
    public static func eventId(videoId: String, timestampMs: Int64, playTimeMs: Int64) -> String {
        uuid5(namespace: namespace, name: "\(videoId)|\(timestampMs)|\(playTimeMs)").uuidString.lowercased()
    }

    /// RFC 9562, версия 5: SHA-1 пространства и имени.
    public static func uuid5(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize())
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
