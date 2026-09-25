import Foundation
import MelogoldCore

/// Аудиоформат из `streamingData.adaptiveFormats` с прямой ссылкой (без `signatureCipher`).
public struct AudioFormat: Hashable, Sendable {
    public var itag: Int
    public var url: String
    public var mimeType: String
    public var contentLength: Int64?
    public var bitrate: Int?
    /// Длительность звука формата, мс. У DASH-m4a AVFoundation считает длительность вдвое больше настоящей
    /// (длительность `mdhd` прибавляется к шкале фрагментов), поэтому конец трека ставится по этому значению.
    public var approxDurationMs: Int64?
    /// Громкость относительно эталона YouTube, дБ (у формата — своя).
    public var loudnessDb: Double?
}

/// Ответ `/player`: можно ли играть, форматы, громкость и длительность.
public struct PlayerResponse: Hashable, Sendable {
    public var status: String
    public var reason: String?
    public var audioFormats: [AudioFormat]
    public var loudnessDb: Double?
    public var durationMs: Int64?

    /// Насколько трек громче эталона YouTube, дБ: `loudnessDb`, а если его нет (ответы 2026 года) —
    /// `trackAbsoluteLoudnessLkfs` (или `perceptualLoudnessDb`) минус `loudnessTargetLkfs` (по умолчанию −14).
    static func loudness(_ audioConfig: JSON) -> Double? {
        if let direct = audioConfig["loudnessDb"].double { return direct }
        let target = audioConfig["loudnessTargetLkfs"].double ?? -14
        if let absolute = audioConfig["trackAbsoluteLoudnessLkfs"].double ?? audioConfig["perceptualLoudnessDb"].double {
            return absolute - target
        }
        return nil
    }

    /// Разбор ответа `/player`. Форматы без прямой ссылки (с `signatureCipher`) отбрасываются.
    static func parse(_ response: JSON) -> PlayerResponse {
        let formats = response.items("streamingData", "adaptiveFormats").compactMap { format -> AudioFormat? in
            guard let mime = format.str("mimeType"), mime.hasPrefix("audio/"), let url = format.str("url") else { return nil }
            return AudioFormat(
                itag: Int(format.int("itag") ?? 0), url: url, mimeType: mime,
                contentLength: format.int("contentLength"), bitrate: format.int("bitrate").map { Int($0) },
                approxDurationMs: format.int("approxDurationMs"), loudnessDb: format["loudnessDb"].double
            )
        }
        let seconds = response.int("videoDetails", "lengthSeconds")
        return PlayerResponse(
            status: response.str("playabilityStatus", "status") ?? "ERROR",
            reason: response.str("playabilityStatus", "reason"),
            audioFormats: formats,
            loudnessDb: loudness(response.at("playerConfig", "audioConfig")),
            durationMs: seconds.flatMap { $0 > 0 ? $0 * 1000 : nil }
        )
    }
}
