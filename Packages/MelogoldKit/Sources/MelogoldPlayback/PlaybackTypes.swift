import Foundation
import MelogoldCore

/// Элемент очереди: трек и откуда он — от пользователя или из автовоспроизведения (REWRITE §4.10.4).
public struct QueueItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var track: Track
    public var fromAutoplay: Bool

    public init(track: Track, fromAutoplay: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.track = track
        self.fromAutoplay = fromAutoplay
    }
}

/// Что сейчас с плеером.
public enum PlaybackPhase: Equatable, Sendable {
    case idle
    /// Получаем поток или буферизуем: на месте ⏯ — индикатор (docs/PROMPT.md §5.7).
    case loading
    case playing
    case paused
    case failed
}

/// Почему не играет (карточка ошибки, REWRITE §3.10.9).
public struct PlaybackFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case network, timeout, botCheck, geo, unavailable, age, extractor
        /// Три пропуска подряд — воспроизведение встало.
        case manySkips
        /// Часы: нет Bluetooth-наушников или колонки (длинное аудио watchOS играет только в Bluetooth).
        case noAudioRoute
    }

    public var kind: Kind
    public var videoId: String?
    /// `.geo`: страна YouTube и число стран, где трек открыт (задание 0010); `nil` — неизвестно.
    public var country: String?
    public var availableCountries: Int?

    public init(kind: Kind, videoId: String?, country: String? = nil, availableCountries: Int? = nil) {
        self.kind = kind
        self.videoId = videoId
        self.country = country
        self.availableCountries = availableCountries
    }

    public init(_ error: StreamError, videoId: String?) {
        let kind: Kind = switch error.kind {
        case .network: .network
        case .timeout: .timeout
        case .botCheck: .botCheck
        case .geo: .geo
        case .unavailable: .unavailable
        case .age: .age
        case .extractor: .extractor
        }
        self.init(kind: kind, videoId: videoId, country: error.country, availableCountries: error.availableCountries)
    }
}

/// Сообщение плеера для плашки: пропуск трека и его причина (REWRITE §3.10.9).
public struct PlayerNotice: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public var skippedTitle: String
    public var reason: PlaybackFailure.Kind
}

/// Повтор: выкл · все · один (docs/PROMPT.md §4 «Очередь»).
public enum RepeatMode: String, Sendable, CaseIterable {
    case off, all, one
}

/// Команда системного пульта: медиаклавиши Mac, Пункт управления, экран блокировки, наушники.
public enum SystemPlaybackCommand: Sendable, Equatable {
    case play, pause, toggle, next, previous
    case seek(Double)
}
