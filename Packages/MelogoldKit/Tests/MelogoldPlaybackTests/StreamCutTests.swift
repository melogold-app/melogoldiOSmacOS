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
}
