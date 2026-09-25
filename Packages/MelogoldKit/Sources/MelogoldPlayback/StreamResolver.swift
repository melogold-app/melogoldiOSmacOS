import Foundation
import MelogoldCore
import MelogoldInnerTube

/// Получает адрес потока трека на чистом Swift, без yt-dlp (docs/PROMPT.md §4): запрос InnerTube `player`
/// клиентами из `StreamClients`, которые отдают прямые ссылки без расшифровки подписи (сейчас VISIONOS).
///
/// - формат — itag 140 (AAC в m4a), запасной 139; Opus AVFoundation не играет;
/// - адреса кэшируются (LRU на 64) до `expire − 5 мин`; сброс — на 403 и при смене сети;
/// - одновременно не больше двух извлечений, у каждого сторож 20 с; один трек не резолвится дважды параллельно.
public actor StreamResolver {
    public static let cacheSize = 64
    public static let watchdogSeconds: Double = 20
    public static let maxConcurrent = 2

    private let catalog: YouTubeMusic
    private var clients: [ClientProfile] = StreamClients.builtIn
    private var cache: [StreamInfo] = []
    private var inFlight: [String: Task<StreamInfo, any Error>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let preferredItags: [Int]

    public init(catalog: YouTubeMusic, preferredItags: [Int] = [140, 139]) {
        self.catalog = catalog
        self.preferredItags = preferredItags
    }

    public func setClients(_ profiles: [ClientProfile]) {
        guard !profiles.isEmpty else { return }
        clients = profiles
    }

    public var clientNames: [String] { clients.map(\.name) }

    /// Адрес из кэша, если он ещё жив.
    public func cached(_ videoId: String) -> StreamInfo? {
        guard let index = cache.firstIndex(where: { $0.videoId == videoId }) else { return nil }
        let info = cache.remove(at: index)
        guard info.expiresAt > Date() else { return nil }
        cache.insert(info, at: 0)
        return info
    }

    public func resolve(_ videoId: String) async throws -> StreamInfo {
        if let hit = cached(videoId) { return hit }
        if let running = inFlight[videoId] { return try await running.value }
        let task = Task { try await self.extract(videoId) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        return try await task.value
    }

    /// Забыть адрес трека (403 при чтении): следующий резолв спросит заново.
    public func invalidate(_ videoId: String) {
        cache.removeAll { $0.videoId == videoId }
    }

    /// Сеть сменилась: адреса googlevideo привязаны к адресу клиента, сбрасываются все.
    public func invalidateAll() {
        cache.removeAll()
    }

    private func acquire() async {
        if active < Self.maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    private func release() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    private func extract(_ videoId: String) async throws -> StreamInfo {
        await acquire()
        defer { release() }
        if let hit = cached(videoId) { return hit }
        var last: StreamError?
        for profile in clients {
            try Task.checkCancellation()
            let started = Date()
            do {
                let info = try await withWatchdog { try await self.fromClient(profile, videoId) }
                remember(info)
                Log.info("stream", "\(videoId): поток \(profile.name), itag \(info.itag), \(Int(Date().timeIntervalSince(started) * 1000)) мс")
                return info
            } catch let error as StreamError where error.isFinal {
                Log.warning("stream", "\(videoId): \(error)")
                throw error
            } catch let error as StreamError {
                Log.warning("stream", "\(videoId): \(profile.name) — \(error)")
                last = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = StreamError(.network, error.localizedDescription)
            }
        }
        throw last ?? StreamError(.extractor, "no stream clients")
    }

    private func withWatchdog(_ work: @escaping @Sendable () async throws -> StreamInfo) async throws -> StreamInfo {
        try await withThrowingTaskGroup(of: StreamInfo.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.watchdogSeconds))
                throw StreamError(.timeout, "YouTube не ответил за \(Int(Self.watchdogSeconds)) с")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StreamError(.timeout, "no result") }
            return first
        }
    }

    private func remember(_ info: StreamInfo) {
        cache.removeAll { $0.videoId == info.videoId }
        cache.insert(info, at: 0)
        if cache.count > Self.cacheSize { cache.removeLast(cache.count - Self.cacheSize) }
    }

    private func fromClient(_ profile: ClientProfile, _ videoId: String) async throws -> StreamInfo {
        let response: PlayerResponse
        do {
            try await catalog.client.ensureVisitorData()
            response = try await catalog.player(videoId: videoId, profile: profile)
        } catch let error as YouTubeError {
            throw StreamError(error.kind == .blocked ? .botCheck : .network, error.message)
        }
        guard response.status == "OK" else {
            let text = "\(response.status) \(response.reason ?? "")"
            throw StreamError(StreamError.classify(text), "\(profile.name): \(text)".trimmingCharacters(in: .whitespaces))
        }
        let formats = response.audioFormats
        let chosen = preferredItags.lazy.compactMap { itag in formats.first { $0.itag == itag } }.first
            ?? formats.filter { $0.mimeType.hasPrefix("audio/mp4") }.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard let chosen else { throw StreamError(.extractor, "\(profile.name): нет AAC с прямой ссылкой") }
        return StreamInfo(
            videoId: videoId, url: chosen.url, itag: chosen.itag, mimeType: chosen.mimeType, contentLength: chosen.contentLength,
            bitrate: chosen.bitrate, expiresAt: StreamInfo.expiry(of: chosen.url), source: profile.name,
            userAgent: profile.mediaUserAgent, loudnessDb: chosen.loudnessDb ?? response.loudnessDb,
            durationMs: chosen.approxDurationMs ?? response.durationMs
        )
    }
}
