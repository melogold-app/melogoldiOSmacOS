import Foundation
import MelogoldCore

extension ServerAPI {
    /// Версия протокола синхронизации этого клиента (API §1.1, заголовок `X-Sync-Protocol`).
    static let syncProtocol = 1
    /// Страница синка может быть большой (первая синхронизация — до 2000 строк на поток).
    static let syncTimeout: TimeInterval = 60
    /// Сервер шлёт heartbeat каждые 25 с (не реже раза в 60 с, API §10): дольше тишины — поток мёртв.
    static let eventsIdleTimeout: TimeInterval = 90

    // MARK: - Синк (API §4.7, §4.8)

    func sync(token: String, _ body: SyncRequest) async throws -> SyncResponse {
        var request = try withBody(request("POST", "/sync", token: token, timeout: Self.syncTimeout), body)
        request.setValue(String(Self.syncProtocol), forHTTPHeaderField: "X-Sync-Protocol")
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    func mergePlan(token: String, _ body: MergePlanRequest) async throws -> MergePlanResponse {
        var request = try withBody(request("POST", "/sync/merge-plan", token: token), body)
        request.setValue(String(Self.syncProtocol), forHTTPHeaderField: "X-Sync-Protocol")
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    // MARK: - Тексты (API §4.10): X-Sync-Protocol не нужен

    func lyrics(token: String, videoId: String) async throws -> LyricsResponse {
        try await send("GET", "/lyrics/\(videoId)", token: token)
    }

    func putLyrics(token: String, videoId: String, _ body: LyricsPut) async throws -> MyLyrics {
        try await send("PUT", "/lyrics/\(videoId)", body: body, token: token)
    }

    /// Надгробие своей версии; нет версии — тоже 204.
    func deleteLyrics(token: String, videoId: String) async throws {
        _ = try await perform(request("DELETE", "/lyrics/\(videoId)", token: token))
    }

    func lyricsChanges(token: String, after: Int64, limit: Int? = nil) async throws -> MyLyricsPage {
        try await send("POST", "/auth/me/lyrics/changes", body: LyricsChangesRequest(after: after, limit: limit), token: token)
    }

    // MARK: - SSE (API §6)

    /// Поток живых событий `GET /auth/me/events`. Кадр — `id:` и `data: <LiveEvent>` до пустой строки, строки
    /// с `:` — heartbeat. Поток заканчивается, когда сервер его закрыл; тишина дольше `eventsIdleTimeout` — ошибка сети.
    func events(token: String) -> AsyncThrowingStream<LiveEvent, any Error> {
        var prepared = request("GET", "/auth/me/events", token: token, timeout: Self.eventsIdleTimeout)
        prepared.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        prepared.cachePolicy = .reloadIgnoringLocalCacheData
        let request = prepared
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "No HTTP response") }
                    guard http.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes.prefix(16_384) { body.append(byte) }
                        if let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: body) {
                            throw envelope.error(status: http.statusCode)
                        }
                        throw APIError(status: http.statusCode, code: Self.codeForStatus(http.statusCode), message: "HTTP \(http.statusCode)")
                    }
                    var parser = EventStreamParser()
                    for try await byte in bytes {
                        if let data = parser.feed(byte), let event = LiveEvent.parse(data) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as APIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: APIError.network(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Разбор `text/event-stream` по байтам (HTML Living Standard, «Server-sent events»): строки до `\n`, `\r\n` или `\r`,
/// пустая строка закрывает кадр, строки `data:` склеиваются через `\n`. Комментарии (`:`), `id:`, `event:` и `retry:`
/// клиенту не нужны: реплея нет (API §6), паузу переподключения клиент выбирает сам. Кадр без пустой строки в конце
/// потока отбрасывается.
struct EventStreamParser {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var afterCR = false

    /// Следующий байт потока → данные кадра, если он закрылся.
    mutating func feed(_ byte: UInt8) -> String? {
        switch byte {
        case UInt8(ascii: "\n"):
            if afterCR {
                afterCR = false
                return nil
            }
            return endLine()
        case UInt8(ascii: "\r"):
            afterCR = true
            return endLine()
        default:
            afterCR = false
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            guard !data.isEmpty else { return nil }
            defer { data.removeAll() }
            return data.joined(separator: "\n")
        }
        let text = String(decoding: line, as: UTF8.self)
        guard !text.hasPrefix(":") else { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        if field == "data" { data.append(String(value)) }
        return nil
    }
}

extension LiveEvent {
    /// Кадр SSE → событие; неизвестный тип — `.other` (API §1.1: новые типы появляются без смены версии).
    static func parse(_ json: String) -> LiveEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let id = object["id"] as? String, let type = object["type"] as? String else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let kind: LiveEventKind
        switch type {
        case "system.connected":
            kind = .connected(heartbeatMs: payload["heartbeatMs"] as? Int, retryMs: payload["retryMs"] as? Int)
        case "sync.changed":
            kind = .syncChanged(cursor: payload["cursor"] as? String)
        case "devices.updated":
            kind = .devicesUpdated(reason: payload["reason"] as? String ?? "", deviceId: payload["deviceId"] as? String)
        case "session.invalidated":
            kind = .sessionInvalidated(reason: payload["reason"] as? String ?? "")
        case "account.updated":
            let by = payload["byDevice"] as? [String: Any]
            kind = .accountUpdated(reason: payload["reason"] as? String ?? "", byDeviceId: by?["id"] as? String, byDeviceName: by?["name"] as? String)
        case "link.updated":
            kind = .linkUpdated(linkId: payload["linkId"] as? String ?? "", status: payload["status"] as? String ?? "")
        case "lyrics.changed":
            kind = .lyricsChanged(videoId: payload["videoId"] as? String ?? "", rev: (payload["rev"] as? NSNumber)?.int64Value ?? 0)
        case "playback.updated":
            kind = .playbackUpdated
        default:
            kind = .other
        }
        return LiveEvent(id: id, type: type, at: object["at"] as? String ?? "", kind: kind)
    }
}
