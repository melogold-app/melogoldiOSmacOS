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

    // MARK: - Решение по ошибке

    /// Что делает плеер с ошибкой потока (задания 0026, 0033 §2): нет сети — ждать; обрыв посреди трека — открыть заново,
    /// дважды; бот — стоп; причина в видео — пропуск; поток не получен — прежний повтор по классу.
    @Test func failureDecisionFollowsTheClassOfTheError() {
        func action(_ kind: StreamError.Kind, midStream: Bool, reopens: Int = 0, retries: Int = 0) -> PlayerEngine.FailureAction {
            PlayerEngine.action(for: StreamError(kind, ""), midStream: midStream, reopens: reopens, retries: retries)
        }
        for midStream in [false, true] {
            #expect(action(.botCheck, midStream: midStream) == .stop)
            #expect(action(.network, midStream: midStream, reopens: 2, retries: 9) == .waitForNetwork)
            #expect(action(.timeout, midStream: midStream) == .waitForNetwork)
            for final in [StreamError.Kind.geo, .age, .unavailable] {
                #expect(action(final, midStream: midStream) == .skip, "\(final)")
            }
        }
        // Сеть есть, а адрес умер посреди песни: до двух переоткрытий, третий обрыв — пропуск
        #expect(action(.extractor, midStream: true) == .reopen)
        #expect(action(.extractor, midStream: true, reopens: 1) == .reopen)
        #expect(action(.extractor, midStream: true, reopens: 2) == .skip)
        // Поток не получен вовсе — как раньше: один повтор, затем пропуск
        #expect(action(.extractor, midStream: false) == .retry)
        #expect(action(.extractor, midStream: false, retries: 1) == .skip)
    }

    /// Строка журнала — как у Linux и Windows.
    @Test func reopenLogLineIsThatOfTheOtherClients() {
        let error = StreamError(.extractor, "googlevideo 403 after 4 fresh URLs at byte 1048576 of 3567210 (VISIONOS)")
        #expect(PlayerEngine.reopenLine(videoId: "uDhUT3I5OSI", at: 83.6, attempt: 2, error: error)
            == "Reopening uDhUT3I5OSI at 1:23 (attempt 2): extractor: googlevideo 403 after 4 fresh URLs at byte 1048576 of 3567210 (VISIONOS)")
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

        /// Задание 0033 §2: адрес googlevideo умер посреди трека (403 и на четыре свежих адреса — смена сети или сервера
        /// VPN), а сеть есть. Трек открывается заново с той же секунды со свежим адресом — дважды, потом пропуск. Раньше
        /// он начинался с 0:00.
        @Test func aCutMidTrackReopensAtTheSameSecondTwiceThenSkips() async throws {
            let cut = try Self.fragmentOffset(at: 30)
            let engine = try await engine { request in
                request.videoId == "aaaaaaaaaaa" && request.range.lowerBound > 0 ? .status(403) : .bytes
            }
            engine.play(tracks: [track("aaaaaaaaaaa"), track("bbbbbbbbbbb")], startAt: 0, from: 30)
            try await until("трек пропущен после двух переоткрытий", engine: engine) { engine.index == 1 }
            let reads = FakeGoogleVideo.ranges.filter { $0.videoId == "aaaaaaaaaaa" && $0.range.lowerBound > 0 }
            // Каждое открытие — с фрагмента с 0:30, а не с начала; в каждом — первый адрес и четыре свежих
            #expect(reads.allSatisfy { $0.range.lowerBound == cut }, "\(reads.map(\.range))")
            #expect(reads.count == 3 * 5)
            #expect(FakeGoogleVideo.ranges.filter { $0.videoId == "aaaaaaaaaaa" && $0.range.lowerBound == 0 }.count == 3,
                    "начало файла — по разу на открытие")
            // Переоткрытие не берёт умерший адрес из кэша резолвера: и его первый адрес — свежий
            #expect(players("aaaaaaaaaaa") == 3 * 5)
            #expect(engine.notice?.skippedTitle == "aaaaaaaaaaa" && engine.notice?.reason == .extractor)
            engine.stop()
        }

        /// Задание 0027, получатель: очередь с другого устройства начинается сразу с той секунды — первый запрос после
        /// начала файла уже за фрагментом с этой секундой, а не старт с 0:00 и перемотка вдогонку.
        @Test func aHandedOffQueueStartsAtItsSecond() async throws {
            let engine = try await engine()
            engine.play(tracks: [track("aaaaaaaaaaa"), track("bbbbbbbbbbb")], startAt: 0, from: 52)
            #expect(engine.position == 52)
            try await until("чтение после начала файла") { FakeGoogleVideo.ranges.contains { $0.range.lowerBound > 0 } }
            let first = FakeGoogleVideo.ranges.first { $0.videoId == "aaaaaaaaaaa" && $0.range.lowerBound > 0 }
            #expect(first?.range.lowerBound == (try Self.fragmentOffset(at: 52)))
            engine.stop()
        }
    }
}
