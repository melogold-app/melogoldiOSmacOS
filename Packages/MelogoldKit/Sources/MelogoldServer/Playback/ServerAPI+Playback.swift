import Foundation

extension ServerAPI {
    // MARK: - Воспроизведение (API §4.9): с X-Sync-Protocol

    func playbackState(token: String) async throws -> PlaybackStateResponse {
        let (data, _) = try await perform(withSyncProtocol(request("GET", "/playback/state", token: token)))
        return try decode(data)
    }

    func putPlaybackState(token: String, _ body: PlaybackPut) async throws -> PlaybackPutResult {
        let (data, _) = try await perform(withSyncProtocol(try withBody(request("PUT", "/playback/state", token: token), body)))
        return try decode(data)
    }

    func deletePlaybackState(token: String) async throws {
        _ = try await perform(withSyncProtocol(request("DELETE", "/playback/state", token: token)))
    }

    /// Пульт: свои устройства, кроме этого, с тем, что они играют (`features.remote`).
    func playbackDevices(token: String) async throws -> RemoteDeviceList {
        let (data, _) = try await perform(withSyncProtocol(request("GET", "/playback/devices", token: token)))
        return try decode(data)
    }

    func sendPlaybackCommand(token: String, _ command: RemoteCommand) async throws -> RemoteCommandResult {
        let (data, _) = try await perform(withSyncProtocol(try withBody(request("POST", "/playback/commands", token: token), command)))
        return try decode(data)
    }

    // MARK: - Ссылки (API §4.11): без X-Sync-Protocol

    func createShare(token: String, _ body: CreateShareRequest) async throws -> ShareCreated {
        try await send("POST", "/shares", body: body, token: token)
    }

    func shares(token: String) async throws -> ShareList {
        try await send("GET", "/shares", token: token)
    }

    func deleteShare(token: String, shareId: String) async throws {
        _ = try await perform(request("DELETE", "/shares/\(shareId)", token: token))
    }

    /// Снимок по ссылке — без входа и на любом сервере Melogold: `baseURL` этого `ServerAPI` — сервер из ссылки.
    public func share(id: String) async throws -> ShareDto {
        try await send("GET", "/shares/\(id)")
    }

    private func withSyncProtocol(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(String(Self.syncProtocol), forHTTPHeaderField: "X-Sync-Protocol")
        return request
    }
}
