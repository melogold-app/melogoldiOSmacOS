import AVFoundation
import CoreAudio
import Foundation
import Testing
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Настоящий AAC-LC 44,1 кГц стерео (тон) в DASH-m4a как у YouTube: тестам старта нужен рендерер, которому есть что играть.
extension SyntheticMP4 {
    private final class EncoderState: @unchecked Sendable {
        var frames: Int
        var phase = 0.0
        init(frames: Int) { self.frames = frames }
    }

    /// Пакеты AAC по 1024 кадра (`seconds` секунд звука).
    static func aacPackets(seconds: Double) throws -> [Data] {
        let rate = 44_100.0
        let pcm = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let aac = try #require(AVAudioFormat(streamDescription: &description))
        let converter = try #require(AVAudioConverter(from: pcm, to: aac))
        converter.bitRate = 128_000
        let state = EncoderState(frames: Int(seconds * rate))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024))
        let output = AVAudioCompressedBuffer(format: aac, packetCapacity: 64, maximumPacketSize: converter.maximumOutputPacketSize)
        var packets: [Data] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard state.frames > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = min(1024, state.frames)
                input.frameLength = AVAudioFrameCount(count)
                let step = 2 * Double.pi * 440 / rate
                for channel in 0..<2 {
                    guard let samples = input.floatChannelData?[channel] else { continue }
                    for index in 0..<count { samples[index] = Float(sin(state.phase + Double(index) * step)) * 0.2 }
                }
                state.phase += Double(count) * step
                state.frames -= count
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let packet = descriptions[index]
                    packets.append(Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize)))
                }
            }
            if status == .endOfStream || status == .error { break }
        }
        return packets
    }

    /// Файл формата YouTube: фрагменты по 10 с (430 пакетов).
    static func audibleFile(seconds: Double) throws -> Data {
        let packets = try aacPackets(seconds: seconds)
        let fragments = stride(from: 0, to: packets.count, by: 430).map { Array(packets[$0..<min($0 + 430, packets.count)]) }
        return build(fragments: fragments).file
    }
}

/// Есть ли на машине выход звука. На машине CI (переменная `CI`) звуковой карты нет, и часы рендерера могут не ходить, —
/// там тесты старта трека пропускаются, если не задано `MELOGOLD_AUDIO_TESTS=1`.
enum AudioHardware {
    static var canRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["MELOGOLD_AUDIO_TESTS"] == "1" { return true }
        return environment["CI"] == nil && hasOutput
    }

    static var hasOutput: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
    }
}

/// Заглушка сети для движка: googlevideo отдаёт диапазоны файла с задержкой, `player` — адрес этого файла. В интернет
/// тест не ходит ни при каких условиях.
final class TrackStartStub: URLProtocol, @unchecked Sendable {
    private struct State {
        var file = Data()
        var delay = 0.15
        var ranges: [Range<Int>] = []
    }

    private static let state = NSLock()
    nonisolated(unsafe) private static var current = State()

    static func serve(_ file: Data, delay: Double = 0.15) {
        state.withLock { current = State(file: file, delay: delay) }
    }

    /// Запросы байтов с начала теста.
    static var ranges: [Range<Int>] { state.withLock { current.ranges } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackStartStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://www.youtube.com")!
        let (file, delay) = Self.state.withLock { (Self.current.file, Self.current.delay) }
        let response: HTTPURLResponse
        let body: Data
        if url.host?.contains("googlevideo") == true {
            let header = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
            let bounds = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
            let lower = bounds.first.flatMap { Int($0) } ?? 0
            let upper = min(bounds.count > 1 ? Int(bounds[1]) ?? file.count - 1 : file.count - 1, file.count - 1)
            Self.state.withLock { Self.current.ranges.append(lower..<(upper + 1)) }
            body = lower <= upper ? file.subdata(in: lower..<(upper + 1)) : Data()
            response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes \(lower)-\(upper)/\(file.count)", "Content-Type": "audio/mp4"])!
        } else {
            let json = """
                {"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"120"},"streamingData":{"adaptiveFormats":[
                {"itag":140,"url":"https://rr1---sn-x.googlevideo.com/videoplayback?expire=4102444800&itag=140",
                "mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":128000,"contentLength":"\(file.count)","approxDurationMs":"120000"}]}}
                """
            body = Data(json.utf8)
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Старт трека, когда данные уже под рукой (docs/PROMPT.md §4, задание 0021). На Linux такой трек не заигрывал: подача
/// кадров заполняла очередь ещё до запуска, а запуск её очищал и не будил ждущего. У Apple подача не ждёт места: рендерер
/// сам зовёт `requestMediaDataWhenReady`, а каждый сброс (`reset`) останавливает запрос и заводит его заново с первой
/// же порцией. Тесты держат это: трек из кэша, с позиции, с переключением, с одним началом в кэше — каждый раз звук
/// должен пойти без «перемотки». Звук выключен (`outputMuted`), но рендерер настоящий.
@Suite("Старт трека — данные под рукой", .enabled(if: AudioHardware.canRun), .serialized)
@MainActor
struct TrackStartTests {
    /// Звука больше, чем читается вперёд (40 с): подача идёт весь тест, и сброс застаёт её посреди работы, как у настоящего трека.
    static let seconds = 120.0
    /// Двенадцать фрагментов; файл собирается один раз на весь прогон.
    static let file: Data = { (try? SyntheticMP4.audibleFile(seconds: seconds)) ?? Data() }()

    struct Rig {
        let engine: PlayerEngine
        let cache: AudioCache
    }

    /// `cached` — сколько байт файла лежит в кэше заранее (`nil` — кэш пуст, все — целиком).
    func rig(ids: [String], cached: Int? = .max) async throws -> Rig {
        let file = Self.file
        try #require(!file.isEmpty, "не собрался AAC")
        TrackStartStub.serve(file)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-start-\(UUID().uuidString)")
        let cache = AudioCache(database: try AppDatabase.inMemory(), directory: directory, limit: { 0 })
        if let cached {
            for id in ids {
                cache.prepare(videoId: id, itag: 140, mimeType: "audio/mp4", contentLength: Int64(file.count), durationMs: Int64(Self.seconds * 1000), loudnessDb: nil)
                cache.write(id, offset: 0, data: file.prefix(cached), total: Int64(file.count))
            }
        }
        let client = InnerTubeClient(session: TrackStartStub.session(), preferredLanguages: ["en-US"])
        await client.setVisitorData("test-visitor")
        let catalog = YouTubeMusic(client: client)
        let resolver = StreamResolver(catalog: catalog)
        await resolver.setClients([.visionOS])
        let engine = PlayerEngine(catalog: catalog, resolver: resolver, cache: cache, session: TrackStartStub.session())
        // Звук выключен ещё до первого буфера: проверка работает на настоящем рендерере, но тихо
        engine.outputMuted = true
        engine.autoplayEnabled = false
        engine.pipeline.renderer.volume = 0
        engine.pipeline.renderer.isMuted = true
        return Rig(engine: engine, cache: cache)
    }

    func track(_ id: String) -> Track { Track(videoId: id, title: id, durationMs: Int64(Self.seconds * 1000)) }

    /// Ждёт, пока трек не пойдёт: «играет», позиция дальше `beyond`, а в рендерер отдано больше чем на 0,3 с вперёд.
    /// Одних часов мало: синхронизатор идёт и тогда, когда звука рендереру никто не подаёт. Состояние — в сообщение, если
    /// не дождались.
    func waitPlaying(_ engine: PlayerEngine, beyond: Double, timeout: Double = 8) async throws -> String? {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            let pipeline = engine.pipeline
            let handed = (pipeline.handedEnd - pipeline.currentTime).seconds
            if engine.phase == .playing, engine.position > beyond, engine.position < beyond + 6, handed > 0.3 { return nil }
            try await Task.sleep(for: .milliseconds(25))
        }
        return "phase \(engine.phase), position \(engine.position), failure \(String(describing: engine.failure)), \(engine.pipeline.diagnostics)"
    }

    @Test func coldStartFromFullCache() async throws {
        let rig = try await rig(ids: ["a"])
        for run in 1...5 {
            rig.engine.play(tracks: [track("a")], startAt: 0)
            let problem = try await waitPlaying(rig.engine, beyond: 0.5)
            #expect(problem == nil, "запуск \(run): \(problem ?? "")")
            rig.engine.pause()
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(TrackStartStub.ranges.isEmpty, "трек целиком в кэше не ходит в сеть")
        #expect(rig.engine.feederRecoveries == 0, "подачу пришлось будить")
        rig.engine.stop()
    }

    @Test func restoredQueueStartsAtItsPosition() async throws {
        let rig = try await rig(ids: ["a"])
        for (run, position) in [0.0, 4.0, 13.0, 27.5].enumerated() {
            let snapshot = PlayerEngine.Snapshot(items: [.init(track: track("a"), fromAutoplay: false)], index: 0, position: position,
                                                 radioSeed: nil, radioPlaylistId: nil, radioContinuation: nil)
            rig.engine.restore(snapshot, play: false)
            #expect(rig.engine.phase == .paused)
            rig.engine.play()
            let problem = try await waitPlaying(rig.engine, beyond: position + 0.5)
            #expect(problem == nil, "восстановление \(run + 1) с \(position) с: \(problem ?? "")")
            rig.engine.pause()
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(rig.engine.feederRecoveries == 0, "подачу пришлось будить")
        rig.engine.stop()
    }

    /// Очередь восстановлена после перезапуска и стоит на паузе: ползунок перемотки выбирает место старта (раньше он молчал,
    /// пока трек не запущен), «играть» начинает с него.
    @Test func seekBarOfRestoredQueueChoosesTheStart() async throws {
        let rig = try await rig(ids: ["a"])
        let snapshot = PlayerEngine.Snapshot(items: [.init(track: track("a"), fromAutoplay: false)], index: 0, position: 3,
                                             radioSeed: nil, radioPlaylistId: nil, radioContinuation: nil)
        rig.engine.restore(snapshot, play: false)
        rig.engine.seek(to: 52)
        #expect(rig.engine.phase == .paused)
        #expect(rig.engine.position == 52)
        rig.engine.play()
        let problem = try await waitPlaying(rig.engine, beyond: 52.5)
        #expect(problem == nil, "после перемотки до старта: \(problem ?? "")")
        rig.engine.stop()
    }

    @Test func switchingFromPlayingTrackToCachedOne() async throws {
        let rig = try await rig(ids: ["a", "b"])
        rig.engine.play(tracks: [track("a"), track("b")], startAt: 0)
        #expect(try await waitPlaying(rig.engine, beyond: 0.5) == nil)
        for run in 1...5 {
            rig.engine.next()
            var problem = try await waitPlaying(rig.engine, beyond: 0.5)
            #expect(problem == nil, "переключение вперёд \(run): \(problem ?? "")")
            rig.engine.previous()
            problem = try await waitPlaying(rig.engine, beyond: 0.5)
            #expect(problem == nil, "переключение назад \(run): \(problem ?? "")")
        }
        #expect(rig.engine.feederRecoveries == 0, "подачу пришлось будить")
        rig.engine.stop()
    }

    /// В кэше только начало файла (заготовка): дальше — сеть, но звук идёт без «перемотки».
    @Test func startWithOnlyTheBeginningCached() async throws {
        for cached in [64 * 1024, 100_000] {
            let rig = try await rig(ids: ["a"], cached: cached)
            for run in 1...3 {
                rig.engine.play(tracks: [track("a")], startAt: 0)
                let problem = try await waitPlaying(rig.engine, beyond: 0.5)
                #expect(problem == nil, "кэш \(cached) Б, запуск \(run): \(problem ?? "")")
                rig.engine.pause()
                try await Task.sleep(for: .milliseconds(150))
            }
            #expect(!TrackStartStub.ranges.isEmpty, "остальное — из сети")
            #expect(rig.engine.feederRecoveries == 0, "подачу пришлось будить")
            rig.engine.stop()
        }
    }

    /// Без кэша вообще: адрес, начало файла одним запросом, первый фрагмент — звук.
    @Test func startWithoutCache() async throws {
        let rig = try await rig(ids: ["a"], cached: nil)
        for run in 1...3 {
            rig.engine.play(tracks: [track("a")], startAt: 0)
            let problem = try await waitPlaying(rig.engine, beyond: 0.5)
            #expect(problem == nil, "без кэша, запуск \(run): \(problem ?? "")")
            rig.engine.pause()
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(rig.engine.feederRecoveries == 0, "подачу пришлось будить")
        rig.engine.stop()
    }

    /// Система сбросила очередь рендерера сама (маршрут звука, смена скорости): отданное пропало, часы идут. Движок должен
    /// подать звук заново с текущего места, а не ждать, пока человек подвинет ползунок.
    @Test func automaticFlushOfTheRendererIsRecovered() async throws {
        let rig = try await rig(ids: ["a"])
        rig.engine.play(tracks: [track("a")], startAt: 0)
        #expect(try await waitPlaying(rig.engine, beyond: 1.0) == nil)
        let pipeline = rig.engine.pipeline
        let before = pipeline.generation
        let at = pipeline.currentTime
        // То, что делает система: очередь рендерера пуста, а уведомление приходит с произвольного потока
        pipeline.renderer.flush()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: pipeline.renderer,
                                                userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: at)])
                continuation.resume()
            }
        }
        let started = Date()
        while pipeline.generation == before, Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(pipeline.generation > before, "движок не подал звук заново после сброса рендерера")
        let problem = try await waitPlaying(rig.engine, beyond: at.seconds + 0.5)
        #expect(problem == nil, "после сброса: \(problem ?? "")")
        rig.engine.stop()
    }

    /// Подача теряет запрос у рендерера (гонка, сбой AVFoundation — то, что у Linux 0.1.7 было с очередью источника):
    /// рендерер доигрывает отданное и замолкает, а часы идут и «играет» не гаснет. Движок замечает, что буферы ждут, а
    /// рендерер пуст, и подаёт заново с текущего места, не дожидаясь ползунка.
    @Test func deadFeederIsNoticedAndRestarted() async throws {
        let rig = try await rig(ids: ["a"])
        rig.engine.play(tracks: [track("a")], startAt: 0)
        #expect(try await waitPlaying(rig.engine, beyond: 0.5) == nil)
        #expect(rig.engine.feederRecoveries == 0)
        let pipeline = rig.engine.pipeline
        #expect(pipeline.pendingCount > 0, "читаем вперёд: в очереди подачи есть что отдавать")
        pipeline.renderer.stopRequestingMediaData()
        let started = Date()
        while rig.engine.feederRecoveries == 0, Date().timeIntervalSince(started) < 25 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rig.engine.feederRecoveries == 1, "движок не заметил, что подача встала")
        let restartedAt = rig.engine.position
        let problem = try await waitPlaying(rig.engine, beyond: restartedAt + 1, timeout: 10)
        #expect(problem == nil, "после пробуждения подачи: \(problem ?? "")")
        rig.engine.stop()
    }
}
