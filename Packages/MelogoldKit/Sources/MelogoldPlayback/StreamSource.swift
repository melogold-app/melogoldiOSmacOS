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

/// Байты трека для плеера (docs/PROMPT.md §4): сначала загрузки, затем кэш, недостающее — из googlevideo короткими
/// диапазонами HTTP Range, и сразу в кэш (как `ChunkedYouTubeDataSource` Android и `HttpRangeReader` Windows).
///
/// - 403, 401, 410 от googlevideo и истёкший адрес — не пропуск: свежий адрес в новом сеансе YouTube и повтор, до четырёх
///   раз подряд, перед вторым, третьим и четвёртым — паузы 1,5, 4 и 8 с (`freshURLPauses`; грабли §9 п. 1). Адрес
///   googlevideo привязан к IP: после смены сети или сервера VPN и свежий адрес, взятый в ту же секунду, ещё получает 403,
///   и песня обрывалась на середине (задание 0033 §2, как `HttpRangeReader` Windows и `reader.rs` Linux). Удачное чтение
///   сбрасывает счёт; не помогли все четыре — ошибка с байтом и клиентом, и плеер переоткрывает трек;
/// - 429 — проверка на бота, без повторов;
/// - сетевая ошибка — повтор через 1 и 3 с;
/// - трек целиком в кэше не делает ни одного запроса: ни `player`, ни googlevideo.
public actor StreamSource {
    /// Паузы перед свежими адресами подряд на 401/403/410, секунды: первый — сразу; их число — сколько адресов пробовать.
    /// Те же, что у Linux (`FRESH_URL_DELAYS`) и Windows (`DefaultRefreshPauses`).
    public static let freshURLPauses: [TimeInterval] = [0, 1.5, 4, 8]

    public nonisolated let videoId: String
    private let resolver: StreamResolver
    private let cache: AudioCache?
    private let downloads: DownloadStore?
    private let session: URLSession
    /// Источник создан действием пользователя (нажатие, «Далее», «Повторить»): пока YouTube не пускает адрес, такой
    /// источник всё же пробует один запрос потока (`StreamResolver.resolve(_:userInitiated:)`).
    private let userInitiated: Bool
    private let freshURLPauses: [TimeInterval]
    /// Трек скачан целиком: байты — из загрузок, сети не нужно.
    private var downloaded = false
    private var info: StreamInfo?
    /// Растёт, когда адрес сменился (получен или сброшен): чтение, получившее 403, берёт свежий, только если адрес всё тот же.
    private var generation = 0
    /// Сколько свежих адресов подряд не помогло; удачное чтение обнуляет.
    private var refreshes = 0
    /// Свежий адрес — не раньше этого: пауза после 403 общая для всех чтений источника.
    private var freshURLAt: Date?
    private var content: StreamContent?

    /// Последняя ошибка — для карточки ошибки и решения о пропуске.
    public private(set) var lastError: StreamError?
    /// Сколько байт пришло из сети (для «Сведений о потоке» и проверки «без запросов»).
    public private(set) var networkBytes: Int64 = 0
    /// Сколько раз запрашивался адрес потока.
    public private(set) var resolveCount = 0

    /// `freshURLPauses` — тестам нулевые.
    public init(videoId: String, resolver: StreamResolver, cache: AudioCache?, downloads: DownloadStore? = nil, session: URLSession,
                userInitiated: Bool = false, freshURLPauses: [TimeInterval] = StreamSource.freshURLPauses) {
        self.videoId = videoId
        self.userInitiated = userInitiated
        self.freshURLPauses = freshURLPauses
        self.resolver = resolver
        self.cache = cache
        self.downloads = downloads
        self.session = session
    }

    public var streamInfo: StreamInfo? { info }

    /// Что известно о потоке сейчас — для «Сведений о потоке».
    public struct Details: Sendable {
        public var info: StreamInfo?
        public var content: StreamContent?
        /// Байты — из загрузок.
        public var downloaded: Bool
        public var networkBytes: Int64
    }

    public var details: Details {
        Details(info: info, content: content, downloaded: downloaded, networkBytes: networkBytes)
    }

    /// Длина, тип, длительность. Из индекса кэша — без сети; иначе через адрес потока.
    public func contentInfo() async throws -> StreamContent {
        if let content { return content }
        if let saved = downloads?.completeInfo(videoId) {
            let value = StreamContent(length: saved.length, mimeType: saved.mimeType, durationMs: saved.durationMs,
                                      loudnessDb: saved.loudnessDb, fromCache: true)
            content = value
            downloaded = true
            return value
        }
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
        if downloaded, let data = downloads?.read(videoId, offset: offset, length: wanted), data.count == wanted {
            return data
        }
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
        // Пауза перед свежим адресом после 403: сеть после переключения успевает устояться
        if let freshURLAt, freshURLAt > Date() {
            try await Task.sleep(for: .seconds(freshURLAt.timeIntervalSinceNow))
            if let info, !info.url.isEmpty, info.expiresAt > Date() { return info }
        }
        do {
            resolveCount += 1
            let fresh = try await resolver.resolve(videoId, userInitiated: userInitiated)
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
                // Адрес истёк или не принят: свежий адрес и повтор. Параллельное чтение уже могло его сменить — тогда
                // просто повторить с новым.
                guard seen == generation else { continue }
                guard refreshes < freshURLPauses.count else {
                    // Не «нет сети»: сеть есть, а адрес умер. Место и клиент — в тексте: по журналу видно, на каком байте и
                    // у какого клиента оборвалось.
                    let error = StreamError(.extractor, "googlevideo \(status.code) after \(freshURLPauses.count) fresh URLs at byte \(offset) of \(total) (\(current.source))")
                    lastError = error
                    throw error
                }
                let pause = freshURLPauses[refreshes]
                refreshes += 1
                Log.warning("stream", "\(videoId): googlevideo \(status.code) на байте \(offset) — свежий адрес в новом сеансе (\(refreshes)-й, пауза \(pause) с)")
                info = nil
                generation += 1
                freshURLAt = Date().addingTimeInterval(pause)
                // В «помеченном» сеансе свежие адреса тоже обрываются на первом мегабайте (задание 0025).
                await resolver.renewVisitor()
                continue
            } catch let status as HTTPStatusError where status.code == 429 {
                // Лимит по адресу, как у `player`: проверка на бота, повторы только углубляют блок. Адрес закрыт и для фона
                // (заготовка следующих треков, загрузки), как у Linux и Windows.
                let error = StreamError(.botCheck, "googlevideo 429")
                Log.warning("stream", "\(videoId): \(error)")
                lastError = error
                await resolver.markBlocked(error)
                throw error
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
