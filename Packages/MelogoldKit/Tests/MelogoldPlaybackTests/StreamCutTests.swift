import Foundation
import Testing
import MelogoldCore
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Обрыв потока и пропажа сети (задания 0025, 0026, 0033 §2) на подставных YouTube и googlevideo (`FakeGoogleVideo`). Сеть у
/// подставки общая, поэтому всё — одним набором по очереди.
@Suite("Обрыв потока и пропажа сети", .serialized)
struct StreamCutTests {
    // MARK: - Чтение диапазонов (StreamSource)

    /// Чтение диапазонов: адрес googlevideo привязан к IP, после смены сети или сервера VPN первые свежие адреса ещё получают
    /// 403. Чтение не сдаётся, пока не перепробует четыре (как Linux `reader.rs` и Windows `HttpRangeReaderTests`).
    @Suite("Чтение: свежий адрес после 403")
    struct Reader {
        static let body = Data("0123456789abcdefghijklmnopqrstuv".utf8)

        /// Источник без кэша на подставке; паузы перед свежими адресами — нулевые, если не сказано другое.
        func source(pauses: [TimeInterval] = [0, 0, 0, 0], visitor: String = "test-visitor",
                    answer: @escaping @Sendable (FakeGoogleVideo.Request) -> FakeGoogleVideo.Answer) async -> (StreamSource, InnerTubeClient, StreamResolver) {
            FakeGoogleVideo.serve(Self.body, answer: answer)
            let stack = await FakeGoogleVideo.stack(visitor: visitor)
            let source = StreamSource(videoId: "kagerouDays", resolver: stack.resolver, cache: nil, session: FakeGoogleVideo.session(),
                                      freshURLPauses: pauses)
            return (source, stack.client, stack.resolver)
        }

        @Test func theDefaultPausesAreThoseOfLinuxAndWindows() {
            #expect(StreamSource.freshURLPauses == [0, 1.5, 4, 8])
        }

        @Test func threeForbiddenAnswersThenTheRangePlays() async throws {
            let (source, _, _) = await source { $0.number >= 3 ? .bytes : .status(403) }
            let data = try await source.read(offset: 4, length: 8)
            #expect(data == Self.body.subdata(in: 4 ..< 12))
            #expect(FakeGoogleVideo.players.count == 1 + 3, "первый адрес и три свежих: \(FakeGoogleVideo.players)")
            #expect(FakeGoogleVideo.ranges.count == 4)
        }

        @Test func alwaysForbiddenFailsAfterFourFreshURLsAndSaysWhere() async {
            let (source, _, _) = await source { _ in .status(403) }
            do {
                _ = try await source.read(offset: 16, length: 8)
                Issue.record("вечный 403 не должен давать байты")
            } catch let error as StreamError {
                // Сеть есть, а адрес умер: не «нет сети» (её плеер ждал бы 10 минут), а переоткрытие трека и пропуск
                #expect(error.kind == .extractor)
                #expect(error.message == "googlevideo 403 after 4 fresh URLs at byte 16 of 32 (VISIONOS)")
            } catch {
                Issue.record("не StreamError: \(error)")
            }
            #expect(FakeGoogleVideo.players.count == 1 + 4)
            #expect(FakeGoogleVideo.ranges.count == 5)
        }

        /// Удачное чтение сбрасывает счёт: 403 через раз не копится до отказа.
        @Test func forbiddenEveryOtherReadNeverRunsOut() async throws {
            let (source, _, _) = await source { $0.number % 2 == 0 ? .status(403) : .bytes }
            for round in 0 ..< 10 {
                let start = (round * 3) % 24
                let data = try await source.read(offset: Int64(start), length: 4)
                #expect(data == Self.body.subdata(in: start ..< start + 4), "чтение \(round)")
            }
            #expect(FakeGoogleVideo.players.count == 1 + 10)
        }

        /// Задание 0025: свежий адрес — в новом сеансе YouTube. В «помеченном» сеансе свежие адреса тоже обрываются на первом
        /// мегабайте, поэтому `visitorData` забывается и берётся новый.
        @Test func aForbiddenAnswerRenewsTheYouTubeSession() async throws {
            let (source, client, _) = await source(visitor: "старый сеанс") { $0.number >= 1 ? .bytes : .status(403) }
            #expect(try await source.read(offset: 0, length: 4) == Self.body.prefix(4))
            #expect(FakeGoogleVideo.visitors == 1, "новый visitorData спрошен один раз")
            let visitor = await client.visitorData
            #expect(visitor != nil && visitor != "старый сеанс", "свежий адрес взят в старом сеансе YouTube: \(visitor ?? "nil")")
        }

        /// 429 — проверка «вы не бот»: ни свежего адреса, ни повтора, и фон 10 минут молчит (адрес закрыт и в резолвере).
        @Test func tooManyRequestsIsABotCheckWithoutRetries() async {
            let (source, _, resolver) = await source { _ in .status(429) }
            do {
                _ = try await source.read(offset: 0, length: 8)
                Issue.record("429 не должен давать байты")
            } catch let error as StreamError {
                #expect(error.kind == .botCheck && error.stopsQueue)
            } catch {
                Issue.record("не StreamError: \(error)")
            }
            #expect(FakeGoogleVideo.players.count == 1, "свежего адреса нет")
            #expect(FakeGoogleVideo.ranges.count == 1, "повтора нет")
            #expect(await resolver.blockedError?.kind == .botCheck, "заготовка следующих треков и загрузки не идут в YouTube")
        }

        /// Паузы — параметром: перед вторым свежим адресом чтение ждёт, перед первым — нет; их число — сколько адресов.
        @Test func pausesComeBeforeTheFreshURLs() async {
            let (source, _, _) = await source(pauses: [0, 0.4]) { _ in .status(403) }
            let started = Date()
            do {
                _ = try await source.read(offset: 0, length: 8)
                Issue.record("вечный 403 не должен давать байты")
            } catch let error as StreamError {
                #expect(error.message.contains("after 2 fresh URLs"), "\(error.message)")
            } catch {
                Issue.record("не StreamError: \(error)")
            }
            #expect(Date().timeIntervalSince(started) >= 0.4)
            #expect(FakeGoogleVideo.players.count == 1 + 2)
        }
    }

    // MARK: - Плеер

    /// Плеер на подставке: настоящий файл формата YouTube (60 с, фрагменты по 10 с), звук выключен, рендерер настоящий.
    @Suite("Плеер: обрыв посреди трека и ожидание сети")
    @MainActor
    struct Engine {
        static let seconds = 60.0
        static let file: Data = { (try? SyntheticMP4.audibleFile(seconds: seconds)) ?? Data() }()

        /// Где в файле начинается фрагмент со звуком на `seconds` секунде трека.
        static func fragmentOffset(at seconds: Double) throws -> Int {
            let (header, index, _) = try #require(try FragmentedMP4.parseHeader(file))
            let segments = try #require(index)
            return segments.segments[segments.segment(at: seconds + Double(header.priming) / Double(header.timescale))].offset
        }

        func track(_ id: String) -> Track { Track(videoId: id, title: id, durationMs: Int64(Self.seconds * 1000)) }

        func engine(youTubeOffline: Bool = false,
                    answer: @escaping @Sendable (FakeGoogleVideo.Request) -> FakeGoogleVideo.Answer = { _ in .bytes }) async throws -> PlayerEngine {
            try #require(!Self.file.isEmpty, "не собрался AAC")
            FakeGoogleVideo.serve(Self.file, youTubeOffline: youTubeOffline, answer: answer)
            let stack = await FakeGoogleVideo.stack()
            let engine = PlayerEngine(catalog: stack.catalog, resolver: stack.resolver, cache: nil, session: FakeGoogleVideo.session())
            // Тихо: рендерер настоящий, но без звука ещё до первого буфера
            engine.outputMuted = true
            engine.volume = 0
            engine.autoplayEnabled = false
            engine.pipeline.renderer.volume = 0
            engine.pipeline.renderer.isMuted = true
            engine.freshURLPauses = [0, 0, 0, 0]
            return engine
        }

        /// Ждёт условия; не дождались — в сообщение и то, в каком состоянии плеер (`engine`).
        func until(_ what: String, timeout: Double = 10, engine: PlayerEngine? = nil, _ condition: () -> Bool) async throws {
            let started = Date()
            while !condition() {
                guard Date().timeIntervalSince(started) < timeout else {
                    let state = engine.map {
                        "\($0.phase), ждёт сеть \($0.isWaitingForNetwork), позиция \($0.position), \(String(describing: $0.failure)), будили подачу \($0.feederRecoveries)"
                    }
                    Issue.record("не дождались: \(what) — \(state ?? "")")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func players(_ videoId: String) -> Int { FakeGoogleVideo.players.filter { $0 == videoId }.count }

        /// По образцу Linux `engine::without_network_the_track_waits_instead_of_skipping` и Windows `NetworkWaitTests`
        /// (задание 0026): сети нет — трек не пропускается, а ждёт её в буферизации; «сеть появилась» — повтор сразу, не
        /// дожидаясь паузы; предел ожидания вышел — ошибка «нет сети», трек и очередь на месте.
        @Test func withoutNetworkTheTrackWaitsInsteadOfSkipping() async throws {
            let engine = try await engine(youTubeOffline: true)
            engine.networkWaitDelays = [2]
            engine.networkWaitLimit = 3
            engine.play(tracks: ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"].map(track), startAt: 0)

            // Отказ — буферизация на том же треке, не пропуск
            try await until("трек ждёт сеть", engine: engine) { engine.isWaitingForNetwork }
            #expect(engine.phase == .loading)
            #expect(engine.currentTrack?.videoId == "aaaaaaaaaaa")
            #expect(engine.notice == nil, "плашки «Пропущен…» нет")

            // Сеть появилась — повтор сразу, раньше паузы в 2 с; ожидание и его счёт времени — прежние
            let calls = players("aaaaaaaaaaa")
            let asked = Date()
            engine.networkBecameAvailable()
            try await until("по сигналу сети YouTube спрошен снова", timeout: 1.5) { players("aaaaaaaaaaa") > calls }
            #expect(Date().timeIntervalSince(asked) < 1, "повтор не ждал паузы")
            #expect(engine.isWaitingForNetwork)

            // Предел ожидания — ошибка «нет сети», трек и очередь на месте, ничего не пропущено
            try await until("плеер встал с ошибкой", timeout: 15, engine: engine) { engine.phase == .failed }
            #expect(engine.failure?.kind == .network)
            #expect(engine.index == 0 && engine.currentTrack?.videoId == "aaaaaaaaaaa")
            #expect(engine.notice == nil, "за всё ожидание ни одного пропуска")
            #expect(!engine.isPlaying && !engine.isWaitingForNetwork)
            engine.stop()
        }

        /// Сеть пропала посреди трека, когда 30 с звука уже поданы рендереру: трек ждёт на месте. Раньше часы шли по
        /// поданному звуку, ожидание снималось как удачный старт, а когда звук кончался, трек вставал без подачи и без
        /// повтора. Сеть вернулась — тот же трек с той же секунды.
        @Test func aNetworkDropMidTrackWaitsAtItsPlace() async throws {
            let cut = try Self.fragmentOffset(at: 30)
            let engine = try await engine { $0.range.lowerBound < cut ? .bytes : .noNetwork }
            // Повтор — только по сигналу сети
            engine.networkWaitDelays = [60]
            engine.play(tracks: [track("aaaaaaaaaaa")], startAt: 0)
            // Чтение вперёд: сразу, через 1 и через 3 с — и отказ; под нагрузкой (подачу будят перемоткой) дольше
            try await until("трек ждёт сеть", timeout: 40, engine: engine) { engine.isWaitingForNetwork }
            let at = engine.position
            try await Task.sleep(for: .milliseconds(600))
            #expect(engine.isWaitingForNetwork, "ожидание сняли поданные вперёд 30 с")
            #expect(engine.phase == .loading)
            #expect(abs(engine.position - at) < 0.01, "позиция стоит: \(at) → \(engine.position)")

            FakeGoogleVideo.answer { _ in .bytes }
            engine.networkBecameAvailable()
            #expect(abs(engine.position - at) < 0.01, "повтор — с того же места")
            try await until("трек снова играет", engine: engine) { engine.phase == .playing }
            #expect(!engine.isWaitingForNetwork && engine.index == 0 && engine.notice == nil)
            engine.stop()
        }

        /// Чтение вперёд оборвалось на паузе (человек поставил паузу и вошёл в лифт): трек не ждёт сеть и не заигрывает сам,
        /// когда она вернётся; «Играть» — с того же места.
        @Test func aCutWhilePausedNeitherWaitsNorResumesByItself() async throws {
            let cut = try Self.fragmentOffset(at: 30)
            let engine = try await engine { $0.range.lowerBound < cut ? .bytes : .noNetwork }
            engine.play(tracks: [track("aaaaaaaaaaa")], startAt: 0)
            try await until("первый звук", engine: engine) { engine.phase == .playing }
            engine.pause()
            let generation = engine.pipeline.generation
            // Чтение вперёд — сразу, через 1 и через 3 с — и отказ: поданный звук снят, трек остаётся на месте
            try await until("чтение вперёд оборвалось", timeout: 40, engine: engine) { engine.pipeline.generation != generation }
            #expect(FakeGoogleVideo.ranges.filter { $0.range.lowerBound >= cut }.count == 3)
            let at = engine.position
            #expect(engine.phase == .paused && !engine.isPlaying)
            #expect(!engine.isWaitingForNetwork, "на паузе сеть не ждут")

            FakeGoogleVideo.answer { _ in .bytes }
            engine.networkBecameAvailable()
            try await Task.sleep(for: .milliseconds(300))
            #expect(engine.phase == .paused, "сам не заиграл")
            #expect(engine.position == at)
            engine.play()
            #expect(engine.position == at, "с того же места")
            try await until("снова играет", engine: engine) { engine.phase == .playing }
            engine.stop()
        }
    }
}
