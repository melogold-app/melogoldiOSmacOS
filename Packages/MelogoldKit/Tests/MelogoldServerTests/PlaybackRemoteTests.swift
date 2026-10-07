import Foundation
import Testing
@testable import MelogoldServer

/// Пульт и «что играет» (API §4.9, §6; задание 0020): разбор событий, отчёт `PUT /playback/state` с правилами
/// сервера, пульт другого устройства, выполнение команд.
@MainActor
@Suite("Воспроизведение и пульт")
struct PlaybackRemoteTests {
    nonisolated static let serverTime = "2026-09-23T10:00:00.000Z"

    static func track(_ n: Int) -> TrackInput {
        var input = TrackInput(videoId: String(format: "vid%08d", n))
        input.title = "Song \(n)"
        input.artists = [ArtistRefDto(id: nil, name: "Artist")]
        return input
    }

    static func snapshot(tracks: Int = 3, identity: Int = 1, index: Int = 0, positionMs: Int64 = 0, playing: Bool = true, volume: Int = 80) -> PlaybackSnapshot {
        PlaybackSnapshot(queue: (0 ..< tracks).map(track), queueIdentity: identity, index: index, positionMs: positionMs,
                         durationMs: 200_000, playing: playing, volume: volume)
    }

    static func applied() -> PlaybackPutResult {
        PlaybackPutResult(applied: true, rev: 1, reason: nil, state: nil, serverTime: serverTime)
    }

    static func summary(device: String = "mac", rev: Int64 = 10, positionMs: Int64 = 10_000, playing: Bool = true, at: String = serverTime, volume: Int? = 40) -> PlaybackSummary {
        let json = """
        {"rev":\(rev),"deviceId":"\(device)","deviceName":"MacBook Air","sessionId":"s1","queueVersion":1,"index":0,"queueLength":3,
         "track":{"videoId":"dQw4w9WgXcQ","title":"Never Gonna Give You Up"},"positionMs":\(positionMs),"durationMs":213000,
         "playing":\(playing),"at":"\(at)","updatedAt":"\(at)","handoffFrom":null,"volume":\(volume.map(String.init) ?? "null")}
        """
        return try! JSONDecoder().decode(PlaybackSummary.self, from: Data(json.utf8))
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("не дождались: \(what)")
    }

    // MARK: - События

    @Test func playbackEventsAreParsed() throws {
        let updated = try #require(LiveEvent.parse("""
        {"id":"e1","type":"playback.updated","at":"\(Self.serverTime)","payload":{"rev":7,"cleared":false,"state":{"rev":7,"deviceId":"d1","deviceName":null,"sessionId":"s","queueVersion":2,"index":1,"queueLength":5,"track":null,"positionMs":1000,"durationMs":null,"playing":false,"at":"\(Self.serverTime)","updatedAt":"\(Self.serverTime)","handoffFrom":null,"volume":55}}}
        """))
        guard case .playbackUpdated(7, false, let state?) = updated.kind else { Issue.record("\(updated.kind)"); return }
        #expect(state.deviceId == "d1" && state.volume == 55 && state.queueLength == 5)

        let cleared = try #require(LiveEvent.parse(#"{"id":"e2","type":"playback.updated","at":"x","payload":{"rev":8,"cleared":true,"state":null}}"#))
        #expect(cleared.kind == .playbackUpdated(rev: 8, cleared: true, state: nil))

        let command = try #require(LiveEvent.parse("""
        {"id":"e3","type":"playback.command","at":"x","payload":{"commandId":"c1","fromDeviceId":"p","fromDeviceName":"Pixel 7 Pro","action":"play_queue","positionMs":null,"volume":null,"queue":[{"videoId":"dQw4w9WgXcQ","title":"T"}],"index":0}}
        """))
        guard case .playbackCommand(let parsed) = command.kind else { Issue.record("\(command.kind)"); return }
        #expect(parsed.action == .playQueue && parsed.queue?.first?.videoId == "dQw4w9WgXcQ" && parsed.fromDeviceName == "Pixel 7 Pro")

        let future = try #require(LiveEvent.parse(#"{"id":"e4","type":"playback.command","at":"x","payload":{"commandId":"c2","fromDeviceId":"p","fromDeviceName":null,"action":"teleport","positionMs":null,"volume":null,"queue":null,"index":null}}"#))
        guard case .playbackCommand(let unknown) = future.kind else { Issue.record("\(future.kind)"); return }
        #expect(unknown.action == nil, "неизвестное действие пропускается")
    }

    @Test func livePositionCountsFromAt() {
        let at = IsoTime.date(Self.serverTime)!
        #expect(Self.summary(positionMs: 10_000).livePositionMs(serverNow: at.addingTimeInterval(5)) == 15_000)
        #expect(Self.summary(positionMs: 10_000, playing: false).livePositionMs(serverNow: at.addingTimeInterval(5)) == 10_000)
        #expect(Self.summary(positionMs: 212_000).livePositionMs(serverNow: at.addingTimeInterval(60)) == 213_000, "не дальше конца")
    }

    // MARK: - Отчёт

    final class Clock {
        var now = IsoTime.date(PlaybackRemoteTests.serverTime)!
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    final class Sent {
        var bodies: [PlaybackPut] = []
        var results: [Result<PlaybackPutResult, APIError>] = []
    }

    func reporter(_ clock: Clock, _ sent: Sent) -> PlaybackReporter {
        let reporter = PlaybackReporter(
            send: { body in
                sent.bodies.append(body)
                if sent.results.isEmpty { return PlaybackRemoteTests.applied() }
                return try sent.results.removeFirst().get()
            },
            now: { clock.now },
            coalesce: .milliseconds(20)
        )
        reporter.enabled = true
        return reporter
    }

    @Test func nothingIsPublishedUntilSoundPlayed() async throws {
        let clock = Clock(), sent = Sent()
        let reporter = reporter(clock, sent)
        reporter.update(Self.snapshot(playing: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sent.bodies.isEmpty)
        reporter.update(Self.snapshot(playing: true))
        try await until("первый PUT") { sent.bodies.count == 1 }
        let first = sent.bodies[0]
        #expect(first.queue?.count == 3 && first.queueVersion == 0 && first.playing && first.volume == 80)
        #expect(first.queue?.allSatisfy { $0.artists == nil } == true, "карта исполнителей не уходит")
    }

    @Test func onlySignificantChangesGoAndQueueOnlyWhenItChanged() async throws {
        let clock = Clock(), sent = Sent()
        let reporter = reporter(clock, sent)
        reporter.update(Self.snapshot(positionMs: 0))
        try await until("первый PUT") { sent.bodies.count == 1 }

        clock.advance(2)
        reporter.update(Self.snapshot(positionMs: 2000))
        reporter.update(Self.snapshot(positionMs: 2000, volume: 82))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sent.bodies.count == 1, "позиция по ходу воспроизведения и громкость на 2 — не значимо")

        reporter.update(Self.snapshot(positionMs: 2000, playing: false))
        try await until("пауза") { sent.bodies.count == 2 }
        #expect(sent.bodies[1].queue == nil, "та же очередь — без неё")
        #expect(sent.bodies[1].playing == false)

        clock.advance(2)
        reporter.update(Self.snapshot(identity: 2, index: 1, positionMs: 0, playing: false))
        try await until("новая очередь") { sent.bodies.count == 3 }
        #expect(sent.bodies[2].queueVersion == 1 && sent.bodies[2].queue?.count == 3)

        clock.advance(2)
        reporter.update(Self.snapshot(identity: 2, index: 1, positionMs: 90_000, playing: false))
        try await until("перемотка") { sent.bodies.count == 4 }
        #expect(sent.bodies[3].positionMs == 90_000 && sent.bodies[3].queue == nil)
    }

    /// Сервер не отвечает: отправка не повторяется в цикле (было ~1900 попыток за 6 с), а ждёт срока повтора — и новое
    /// изменение раньше срока тоже не шлёт; после срока уходит.
    @Test func failuresWaitBeforeRetryingInsteadOfLooping() async throws {
        let clock = Clock(), sent = Sent()
        let down = APIError(status: 503, code: "unavailable", message: "")
        sent.results = Array(repeating: .failure(down), count: 50)
        let reporter = reporter(clock, sent)
        reporter.update(Self.snapshot(playing: true))
        try await until("первая попытка") { sent.bodies.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent.bodies.count == 1, "без паузы повтора — сотни попыток: \(sent.bodies.count)")
        // Значимое изменение раньше срока повтора (2 с) — тоже ждёт
        reporter.update(Self.snapshot(index: 1, playing: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent.bodies.count == 1)
        // Срок прошёл: следующее изменение уходит сразу
        clock.advance(3)
        reporter.update(Self.snapshot(index: 2, playing: true))
        try await until("попытка после срока") { sent.bodies.count == 2 }
    }

    @Test func queueRequiredIsAnsweredWithTheQueue() async throws {
        let clock = Clock(), sent = Sent()
        let reporter = reporter(clock, sent)
        reporter.update(Self.snapshot())
        try await until("первый PUT") { sent.bodies.count == 1 }
        clock.advance(2)
        sent.results = [.failure(APIError(status: 409, code: "playback_queue_required", message: "")), .success(Self.applied())]
        reporter.update(Self.snapshot(playing: false))
        try await until("повтор с очередью") { sent.bodies.count == 3 }
        guard sent.bodies.count == 3 else { return }
        #expect(sent.bodies[1].queue == nil && sent.bodies[2].queue?.count == 3)
    }

    @Test func handedOffStartsANewSession() async throws {
        let clock = Clock(), sent = Sent()
        let reporter = reporter(clock, sent)
        var handed = 0
        reporter.onHandedOff = { _ in handed += 1 }
        reporter.update(Self.snapshot())
        try await until("первый PUT") { sent.bodies.count == 1 }
        let session = reporter.sessionId
        clock.advance(2)
        sent.results = [.success(PlaybackPutResult(applied: false, rev: nil, reason: "handed_off", state: nil, serverTime: Self.serverTime))]
        reporter.update(Self.snapshot(playing: false))
        try await until("handed_off") { handed == 1 }
        #expect(reporter.sessionId != session)
        reporter.update(Self.snapshot(playing: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sent.bodies.count == 2, "после передачи — ничего, пока здесь снова не заиграет")
    }

    @Test func sseHandoffOfThisSessionIsNoticed() {
        let clock = Clock(), sent = Sent()
        let reporter = reporter(clock, sent)
        var handed = 0
        reporter.onHandedOff = { _ in handed += 1 }
        let json = """
        {"rev":2,"deviceId":"other","deviceName":null,"sessionId":"x","queueVersion":0,"index":0,"queueLength":1,"track":null,
         "positionMs":0,"durationMs":null,"playing":true,"at":"\(Self.serverTime)","updatedAt":"\(Self.serverTime)",
         "handoffFrom":{"deviceId":"me","sessionId":"\(reporter.sessionId)","at":"\(Self.serverTime)"},"volume":null}
        """
        let summary = try! JSONDecoder().decode(PlaybackSummary.self, from: Data(json.utf8))
        reporter.noticeUpdate(summary, myDeviceId: "someone-else")
        #expect(handed == 0)
        reporter.noticeUpdate(summary, myDeviceId: "me")
        #expect(handed == 1)
    }

    @Test func takeOverSendsHandoffOnce() async throws {
        let clock = Clock(), sent = Sent()
        let reporter = reporter(clock, sent)
        let state = try JSONDecoder().decode(PlaybackState.self, from: Data("""
        {"rev":5,"deviceId":"pixel","deviceName":"Pixel","sessionId":"ps","queueVersion":3,"index":0,"positionMs":0,"durationMs":null,
         "playing":true,"at":"\(Self.serverTime)","updatedAt":"\(Self.serverTime)","queue":[],"handoffFrom":null,"volume":null}
        """.utf8))
        reporter.takeOver(from: state)
        reporter.update(Self.snapshot(playing: false))
        try await until("PUT с передачей") { sent.bodies.count == 1 }
        #expect(sent.bodies[0].handoffFrom == PlaybackHandoff(deviceId: "pixel", sessionId: "ps"))
        clock.advance(2)
        reporter.update(Self.snapshot(playing: true))
        try await until("следующий PUT") { sent.bodies.count == 2 }
        #expect(sent.bodies[1].handoffFrom == nil)
    }

    @Test func windowIsAtMost200AroundTheCurrentAndYouTubeOnly() {
        var queue = (0 ..< 300).map(Self.track)
        queue.insert(TrackInput(videoId: "local:song.mp3"), at: 10)
        let (window, index) = PlaybackReporter.window(queue, index: 251)
        #expect(window.count == 100, "[index−50, конец очереди]")
        #expect(index == 50)
        #expect(window[index].videoId == queue[251].videoId)
        let (middle, middleIndex) = PlaybackReporter.window(queue, index: 121)
        #expect(middle.count == 200 && middleIndex == 50 && middle[50].videoId == queue[121].videoId)
        #expect(!window.contains { $0.videoId.hasPrefix("local:") })
        #expect(PlaybackReporter.window(queue, index: 10).tracks.isEmpty, "текущий не с YouTube — публиковать нечего")
        let (short, shortIndex) = PlaybackReporter.window(Array(queue.prefix(5)), index: 4)
        #expect(short.count == 5 && shortIndex == 4)
    }

    // MARK: - Пульт

    final class FakeRemotePort: RemotePort {
        var commands: [RemoteCommand] = []
        var failure: APIError?
        var devices: [RemoteDevice] = []

        func playbackDevices() async throws -> RemoteDeviceList { RemoteDeviceList(devices: devices, serverTime: PlaybackRemoteTests.serverTime) }

        func sendPlaybackCommand(_ command: RemoteCommand) async throws -> RemoteCommandResult {
            commands.append(command)
            if let failure { throw failure }
            return RemoteCommandResult(delivered: true)
        }

        func playbackState() async throws -> PlaybackStateResponse { PlaybackStateResponse(state: nil, serverTime: PlaybackRemoteTests.serverTime) }
    }

    static func device(online: Bool = true, controllable: Bool = true, playing: PlaybackSummary? = PlaybackRemoteTests.summary()) -> RemoteDevice {
        RemoteDevice(deviceId: "mac", name: "MacBook Air", platform: "macos", online: online, controllable: controllable, playing: playing, volume: playing?.volume)
    }

    @Test func watchIsNotOfferedAsTarget() async {
        let port = FakeRemotePort()
        port.devices = [
            Self.device(),
            RemoteDevice(deviceId: "watch", name: "Apple Watch", platform: "watchos", online: false, controllable: false, playing: nil, volume: nil),
        ]
        let remote = RemoteControl(port: port)
        await remote.refresh()
        #expect(remote.devices.map(\.deviceId) == ["mac"])
    }

    @Test func commandsGoToTheTargetAndErrorsDisconnect() async throws {
        let port = FakeRemotePort()
        let clock = Clock()
        let remote = RemoteControl(port: port, now: { clock.now }, volumeDelay: .milliseconds(10))
        remote.connect(Self.device())
        #expect(remote.isActive && remote.volume == 40 && remote.state?.track?.videoId == "dQw4w9WgXcQ")

        await remote.pause()
        await remote.seek(toMs: 61_000)
        await remote.playQueue((0 ..< 3).map(Self.track), index: 2)
        #expect(port.commands.map(\.action) == [.pause, .seek, .playQueue])
        #expect(port.commands.allSatisfy { $0.targetDeviceId == "mac" })
        #expect(port.commands[1].positionMs == 61_000)
        #expect(port.commands[2].index == 2 && port.commands[2].queue?.count == 3)
        #expect(Set(port.commands.map(\.commandId)).count == 3, "у каждой команды свой id")

        port.failure = APIError(status: 409, code: "device_offline", message: "")
        await remote.next()
        #expect(!remote.isActive && remote.notice == .offline(name: "MacBook Air"))

        remote.connect(Self.device())
        port.failure = APIError(status: 409, code: "remote_control_disabled", message: "")
        await remote.toggle()
        #expect(!remote.isActive && remote.notice == .disabled(name: "MacBook Air"))
    }

    @Test func volumeGoesAfterTheSliderStops() async throws {
        let port = FakeRemotePort()
        let remote = RemoteControl(port: port, volumeDelay: .milliseconds(30))
        remote.connect(Self.device())
        remote.setVolume(50)
        remote.setVolume(60)
        remote.setVolume(140)
        #expect(remote.volume == 100)
        try await until("команда громкости") { port.commands.count == 1 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(port.commands.count == 1)
        #expect(port.commands[0].action == .volume && port.commands[0].volume == 100)
    }

    @Test func eventsUpdateTheTargetOnly() {
        let remote = RemoteControl(port: FakeRemotePort())
        remote.connect(Self.device(playing: Self.summary(rev: 10)))
        remote.apply(rev: 11, cleared: false, state: Self.summary(device: "pixel", rev: 11, positionMs: 1))
        #expect(remote.state?.positionMs == 10_000, "чужое устройство")
        remote.apply(rev: 9, cleared: false, state: Self.summary(rev: 9, positionMs: 2))
        #expect(remote.state?.positionMs == 10_000, "старее виденного")
        remote.apply(rev: 12, cleared: false, state: Self.summary(rev: 12, positionMs: 3, volume: 70))
        #expect(remote.state?.positionMs == 3 && remote.volume == 70)
        remote.apply(rev: 13, cleared: true, state: nil)
        #expect(remote.state == nil && remote.isActive)
    }

    // MARK: - Выполнение команд

    final class FakePlayer: RemotePlayable {
        var calls: [String] = []
        func remotePlay() { calls.append("play") }
        func remotePause() { calls.append("pause") }
        func remoteToggle() { calls.append("toggle") }
        func remoteNext() { calls.append("next") }
        func remotePrevious() { calls.append("previous") }
        func remoteSeek(toMs positionMs: Int64) { calls.append("seek \(positionMs)") }
        func remoteSetVolume(_ volume: Int) { calls.append("volume \(volume)") }
        func remotePlayQueue(_ tracks: [TrackDto], index: Int, startMs: Int64) {
            calls.append(startMs > 0 ? "queue \(tracks.count) \(index) \(startMs)" : "queue \(tracks.count) \(index)")
        }
        func remoteStop() { calls.append("stop") }
    }

    static func command(_ id: String, _ action: String, extra: String = "") -> PlaybackCommand {
        let json = #"{"commandId":"\#(id)","fromDeviceId":"p","fromDeviceName":"Pixel 7 Pro","action":"\#(action)"\#(extra)}"#
        return try! JSONDecoder().decode(PlaybackCommand.self, from: Data(json.utf8))
    }

    @Test func executorRunsEachActionOnceAndNoticesEvery30Seconds() {
        let player = FakePlayer()
        let clock = Clock()
        let executor = RemoteCommandExecutor(now: { clock.now })
        executor.player = player
        #expect(executor.execute(Self.command("1", "pause")) == "Pixel 7 Pro")
        #expect(executor.execute(Self.command("1", "pause")) == nil, "повтор той же команды")
        #expect(executor.execute(Self.command("2", "seek", extra: #","positionMs":61000"#)) == nil, "уведомление не чаще раза в 30 с")
        executor.execute(Self.command("3", "volume", extra: #","volume":130"#))
        executor.execute(Self.command("4", "play_queue", extra: #","queue":[{"videoId":"dQw4w9WgXcQ","title":"T"},{"videoId":"a1B2c3D4e5F","title":"U"}],"index":5"#))
        executor.execute(Self.command("5", "next"))
        executor.execute(Self.command("6", "seek"))
        #expect(player.calls == ["pause", "seek 61000", "volume 100", "queue 2 1", "next"])
        clock.advance(31)
        #expect(executor.execute(Self.command("7", "toggle")) == "Pixel 7 Pro")
    }
}
