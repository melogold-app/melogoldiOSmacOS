import Foundation

/// Воспроизведение, пульт и ссылки через сеанс аккаунта: токен обновляется сам (`authorized`).
extension Account {
    /// Сервер поддерживает пульт (`features.remote`, сервер 0.1.2+).
    public var supportsRemote: Bool { serverInfo?.features.remote != nil }
    /// Сервер поддерживает ссылки на свои плейлисты (`features.share`).
    public var supportsShare: Bool { serverInfo?.features.share != nil }

    public func playbackState() async throws -> PlaybackStateResponse {
        try await authorized { api, token in try await api.playbackState(token: token) }
    }

    public func putPlaybackState(_ body: PlaybackPut) async throws -> PlaybackPutResult {
        try await authorized { api, token in try await api.putPlaybackState(token: token, body) }
    }

    public func deletePlaybackState() async throws {
        try await authorized { api, token in try await api.deletePlaybackState(token: token) }
    }

    public func playbackDevices() async throws -> RemoteDeviceList {
        try await authorized { api, token in try await api.playbackDevices(token: token) }
    }

    public func sendPlaybackCommand(_ command: RemoteCommand) async throws -> RemoteCommandResult {
        try await authorized { api, token in try await api.sendPlaybackCommand(token: token, command) }
    }

    public func createShare(name: String, tracks: [TrackInput]) async throws -> ShareCreated {
        let body = CreateShareRequest(name: name, tracks: tracks)
        return try await authorized { api, token in try await api.createShare(token: token, body) }
    }

    public func shares() async throws -> ShareList {
        try await authorized { api, token in try await api.shares(token: token) }
    }

    public func deleteShare(_ shareId: String) async throws {
        try await authorized { api, token in try await api.deleteShare(token: token, shareId: shareId) }
    }

    /// Снимок по ссылке с сервера из ссылки (может быть не свой) — без входа.
    public func publicShare(server: String, id: String) async throws -> ShareDto {
        try await api(server).share(id: id)
    }
}
