import Foundation

// Воспроизведение и пульт (API §4.9, §6; задание 0020): что играет на устройствах аккаунта, команды другому
// устройству. Ответы читаются терпимо, как в синке: отсутствующее поле — `nil`, неизвестные пропускаются.

public struct PlaybackHandoff: Codable, Sendable, Equatable {
    public let deviceId: String
    public let sessionId: String
    /// В ответе сервера — когда передали; в запросе не пишется.
    public let at: String?

    public init(deviceId: String, sessionId: String, at: String? = nil) {
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.at = at
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(sessionId, forKey: .sessionId)
    }

    enum CodingKeys: String, CodingKey { case deviceId, sessionId, at }
}

/// Полное состояние `GET /playback/state` (с очередью до 200 треков).
public struct PlaybackState: Decodable, Sendable, Equatable {
    public let rev: Int64
    public let deviceId: String
    public let deviceName: String?
    public let sessionId: String
    public let queueVersion: Int
    public let index: Int
    public let positionMs: Int64
    public let durationMs: Int64?
    public let playing: Bool
    /// Время позиции (`effAt`): другие считают позицию от него.
    public let at: String
    public let updatedAt: String
    public let queue: [TrackDto]
    public let handoffFrom: PlaybackHandoff?
    /// 0..100 — громкость устройства-автора; `nil` — не сообщало.
    public let volume: Int?
}

public struct PlaybackStateResponse: Decodable, Sendable, Equatable {
    public let state: PlaybackState?
    public let serverTime: String
}

/// Состояние без очереди — в SSE `playback.updated` и в списке устройств.
public struct PlaybackSummary: Decodable, Sendable, Equatable {
    public let rev: Int64
    public let deviceId: String
    public let deviceName: String?
    public let sessionId: String
    public let queueVersion: Int
    public let index: Int
    public let queueLength: Int
    public let track: TrackDto?
    public let positionMs: Int64
    public let durationMs: Int64?
    public let playing: Bool
    public let at: String
    public let updatedAt: String
    public let handoffFrom: PlaybackHandoff?
    public let volume: Int?

    /// Позиция сейчас (DESIGN §3.12.5): от `at`, если играет, но не дальше конца трека.
    public func livePositionMs(serverNow: Date) -> Int64 {
        var position = positionMs
        if playing, let at = IsoTime.date(at) {
            position += max(0, Int64(serverNow.timeIntervalSince(at) * 1000))
        }
        if let durationMs, durationMs > 0 { position = min(position, durationMs) }
        return max(0, position)
    }
}

/// `PUT /playback/state`. Поля без значения не пишутся.
public struct PlaybackPut: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var queueVersion: Int
    public var at: String
    public var index: Int
    public var positionMs: Int64
    public var durationMs: Int64?
    public var playing: Bool
    /// Только если пара `(sessionId, queueVersion)` изменилась с последнего принятого PUT (DESIGN §3.12.2).
    public var queue: [TrackInput]?
    /// Только при «Слушать здесь».
    public var handoffFrom: PlaybackHandoff?
    /// 0..100 — громкость плеера этого устройства (пульт).
    public var volume: Int?

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(queueVersion, forKey: .queueVersion)
        try container.encode(at, forKey: .at)
        try container.encode(index, forKey: .index)
        try container.encode(positionMs, forKey: .positionMs)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encode(playing, forKey: .playing)
        try container.encodeIfPresent(queue, forKey: .queue)
        try container.encodeIfPresent(handoffFrom, forKey: .handoffFrom)
        try container.encodeIfPresent(volume, forKey: .volume)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, queueVersion, at, index, positionMs, durationMs, playing, queue, handoffFrom, volume
    }
}

public struct PlaybackPutResult: Decodable, Sendable, Equatable {
    public let applied: Bool
    public let rev: Int64?
    /// `newer_state` или `handed_off`, когда `applied == false`.
    public let reason: String?
    public let state: PlaybackState?
    public let serverTime: String
}

// MARK: - Пульт

public struct RemoteDevice: Decodable, Sendable, Equatable, Identifiable {
    public let deviceId: String
    public let name: String
    public let platform: String
    /// У устройства открыт поток событий прямо сейчас.
    public let online: Bool
    /// Устройство разрешило управление (поток с `remote=1`).
    public let controllable: Bool
    /// Что оно играет, если оно — автор текущего состояния.
    public let playing: PlaybackSummary?
    public let volume: Int?

    public var id: String { deviceId }
}

public struct RemoteDeviceList: Decodable, Sendable, Equatable {
    public let devices: [RemoteDevice]
    public let serverTime: String
}

public enum RemoteAction: String, Codable, Sendable, CaseIterable {
    case play, pause, toggle, next, previous, seek, volume, stop
    case playQueue = "play_queue"
}

/// `POST /playback/commands`. Поля без значения не пишутся.
public struct RemoteCommand: Encodable, Sendable, Equatable {
    public var commandId: String
    public var targetDeviceId: String
    public var action: RemoteAction
    public var positionMs: Int64?
    public var volume: Int?
    public var queue: [TrackInput]?
    public var index: Int?

    public init(
        commandId: String = UUID().uuidString.lowercased(), targetDeviceId: String, action: RemoteAction,
        positionMs: Int64? = nil, volume: Int? = nil, queue: [TrackInput]? = nil, index: Int? = nil
    ) {
        self.commandId = commandId
        self.targetDeviceId = targetDeviceId
        self.action = action
        self.positionMs = positionMs
        self.volume = volume
        self.queue = queue
        self.index = index
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(targetDeviceId, forKey: .targetDeviceId)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(positionMs, forKey: .positionMs)
        try container.encodeIfPresent(volume, forKey: .volume)
        try container.encodeIfPresent(queue, forKey: .queue)
        try container.encodeIfPresent(index, forKey: .index)
    }

    enum CodingKeys: String, CodingKey { case commandId, targetDeviceId, action, positionMs, volume, queue, index }
}

public struct RemoteCommandResult: Decodable, Sendable, Equatable {
    /// `false` — цель ушла из сети в этот самый момент.
    public let delivered: Bool
}

/// SSE `playback.command`: команда этому устройству от другого устройства аккаунта.
public struct PlaybackCommand: Decodable, Sendable, Equatable {
    public let commandId: String
    public let fromDeviceId: String
    public let fromDeviceName: String?
    /// `nil` — действие, которого этот клиент ещё не знает: пропускается.
    public let action: RemoteAction?
    public let positionMs: Int64?
    public let volume: Int?
    public let queue: [TrackDto]?
    public let index: Int?

    enum CodingKeys: String, CodingKey { case commandId, fromDeviceId, fromDeviceName, action, positionMs, volume, queue, index }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try c.decode(String.self, forKey: .commandId)
        fromDeviceId = try c.decode(String.self, forKey: .fromDeviceId)
        fromDeviceName = try c.decodeIfPresent(String.self, forKey: .fromDeviceName)
        action = try c.decodeIfPresent(String.self, forKey: .action).flatMap(RemoteAction.init(rawValue:))
        positionMs = try c.decodeIfPresent(Int64.self, forKey: .positionMs)
        volume = try c.decodeIfPresent(Int.self, forKey: .volume)
        queue = try c.decodeIfPresent([TrackDto].self, forKey: .queue)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
    }
}

// MARK: - Ссылки на свои плейлисты (API §4.11, задание 0019)

public struct CreateShareRequest: Encodable, Sendable, Equatable {
    public var kind: String
    public var name: String
    public var tracks: [TrackInput]

    public init(name: String, tracks: [TrackInput]) {
        kind = "playlist"
        self.name = name
        self.tracks = tracks
    }
}

public struct ShareCreated: Decodable, Sendable, Equatable {
    public let shareId: String
    /// `<адрес сервера>/s/<shareId>` — то, чем делятся.
    public let url: String
    public let createdAt: String
}

public struct ShareDto: Decodable, Sendable, Equatable, Identifiable {
    public let shareId: String
    public let kind: String
    public let name: String
    public let url: String
    public let tracks: [TrackDto]
    public let createdAt: String

    public var id: String { shareId }
}

public struct ShareList: Decodable, Sendable, Equatable {
    public let shares: [ShareDto]
}
