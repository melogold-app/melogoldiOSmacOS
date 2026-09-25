import Foundation
import MelogoldCore
import MelogoldData

/// Что плеер знает о файле трека до чтения байтов.
public struct StreamContent: Sendable, Equatable {
    public var length: Int64
    public var mimeType: String
    public var durationMs: Int64?
    public var loudnessDb: Double?
    /// Трек целиком в кэше: играет без сети и без запроса потока.
    public var fromCache: Bool
}

/// Байты трека для плеера (docs/PROMPT.md §4): сначала кэш, недостающее — из googlevideo короткими диапазонами
/// HTTP Range, и сразу в кэш (как `ChunkedYouTubeDataSource` Android и `HttpRangeReader` Windows).
///
/// - 403, 401, 410 от googlevideo и истёкший адрес — не пропуск: адрес сбрасывается, берётся свежий, и чтение
///   повторяется, до двух раз подряд (грабли §9 п. 1);
/// - сетевая ошибка — повтор через 1 и 3 с;
/// - трек целиком в кэше не делает ни одного запроса: ни `player`, ни googlevideo.
public actor StreamSource {
    public nonisolated let videoId: String
    private let resolver: StreamResolver
    private let cache: AudioCache?
    private let session: URLSession
    private var info: StreamInfo?
    private var generation = 0
    private var refreshes = 0
    private var content: StreamContent?

    /// Последняя ошибка — для карточки ошибки и решения о пропуске.
    public private(set) var lastError: StreamError?
    /// Сколько байт пришло из сети (для «Сведений о потоке» и проверки «без запросов»).
    public private(set) var networkBytes: Int64 = 0
    /// Сколько раз запрашивался адрес потока.
    public private(set) var resolveCount = 0

    public init(videoId: String, resolver: StreamResolver, cache: AudioCache?, session: URLSession) {
        self.videoId = videoId
        self.resolver = resolver
        self.cache = cache
        self.session = session
    }

    public var streamInfo: StreamInfo? { info }

    /// Длина, тип, длительность. Из индекса кэша — без сети; иначе через адрес потока.
    public func contentInfo() async throws -> StreamContent {
        if let content { return content }
        if let entry = cache?.entry(videoId), let length = entry.contentLength {
            let value = StreamContent(length: length, mimeType: entry.mimeType, durationMs: entry.durationMs,
                                      loudnessDb: entry.loudnessDb, fromCache: entry.complete)
            content = value
            cache?.touch(videoId)
            return value
        }
        let resolved = try await resolveInfo()
        var length = resolved.contentLength
        if length == nil {
            length = try await probeLength()
        }
        guard let length else { throw StreamError(.extractor, "\(videoId): длина потока неизвестна") }
        cache?.prepare(videoId: videoId, itag: resolved.itag, mimeType: resolved.mimeType, contentLength: length,
                       durationMs: resolved.durationMs, loudnessDb: resolved.loudnessDb)
        let value = StreamContent(length: length, mimeType: resolved.mimeType, durationMs: resolved.durationMs,
                                  loudnessDb: resolved.loudnessDb, fromCache: false)
        content = value
        return value
    }

    /// Байты `[offset, offset + length)`; может вернуть меньше, если столько есть подряд в кэше.
    public func read(offset: Int64, length: Int) async throws -> Data {
        let total = try await contentInfo().length
        let end = min(offset + Int64(length), total)
        guard end > offset else { return Data() }
        let wanted = Int(end - offset)
        if let cache {
            if let data = cache.read(videoId, offset: offset, length: wanted) { return data }
            let available = cache.available(videoId, from: offset)
            if available > 0, let data = cache.read(videoId, offset: offset, length: Int(min(available, Int64(wanted)))) {
                return data
            }
        }
        return try await fetch(offset: offset, length: wanted, total: total)
    }

    // MARK: - Сеть

    private func resolveInfo() async throws -> StreamInfo {
        if let info, !info.url.isEmpty, info.expiresAt > Date() { return info }
        do {
            resolveCount += 1
            let fresh = try await resolver.resolve(videoId)
            info = fresh
            generation += 1
            return fresh
        } catch let error as StreamError {
            lastError = error
            throw error
        }
    }

    /// Длина из `Content-Range` ответа на `bytes=0-0`, если `player` её не дал.
    private func probeLength() async throws -> Int64? {
        let (_, total) = try await request(range: 0..<1, info: try await resolveInfo())
        return total
    }

    private func fetch(offset: Int64, length: Int, total: Int64) async throws -> Data {
        var networkRetries = 0
        while true {
            try Task.checkCancellation()
            let current = try await resolveInfo()
            let seen = generation
            do {
                let started = Date()
                Log.debug("stream", "\(videoId): сеть \(offset)+\(length)…")
                let (data, reportedTotal) = try await request(range: offset..<(offset + Int64(length)), info: current)
                Log.debug("stream", "\(videoId): сеть \(offset)+\(data.count) за \(Int(Date().timeIntervalSince(started) * 1000)) мс")
                refreshes = 0
                networkBytes += Int64(data.count)
                cache?.write(videoId, offset: offset, data: data, total: reportedTotal ?? total)
                lastError = nil
                return data
            } catch let status as HTTPStatusError where [401, 403, 410].contains(status.code) {
                // Адрес истёк или не принят: свежий адрес и повтор. Параллельное чтение уже могло его обновить.
                if seen == generation {
                    refreshes += 1
                    if refreshes > 2 {
                        let error = StreamError(.network, "googlevideo \(status.code) после свежих адресов")
                        lastError = error
                        throw error
                    }
                    Log.warning("stream", "\(videoId): googlevideo \(status.code) — беру свежий адрес")
                    await resolver.invalidate(videoId)
                    info = nil
                }
                continue
            } catch let status as HTTPStatusError where status.code == 416 {
                return Data()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                Log.debug("stream", "\(videoId): сеть \(offset) — \(error)")
                networkRetries += 1
                if networkRetries > 2 {
                    let failure = StreamError(.network, "чтение потока: \(error.localizedDescription)")
                    lastError = failure
                    throw failure
                }
                try await Task.sleep(for: .seconds(networkRetries == 1 ? 1 : 3))
            }
        }
    }

    /// Один запрос диапазона. Ответ не 2xx — `HTTPStatusError`.
    private func request(range: Range<Int64>, info: StreamInfo) async throws -> (Data, Int64?) {
        guard let url = URL(string: info.url) else { throw StreamError(.extractor, "нет адреса потока") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        if let userAgent = info.userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamError(.network, "нет ответа HTTP") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(code: http.statusCode) }
        return (data, Self.totalLength(http))
    }

    /// Полная длина из `Content-Range: bytes 0-1023/4598559`.
    static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), let slash = value.lastIndex(of: "/") else {
            return nil
        }
        return Int64(value[value.index(after: slash)...])
    }
}

struct HTTPStatusError: Error {
    let code: Int
}
