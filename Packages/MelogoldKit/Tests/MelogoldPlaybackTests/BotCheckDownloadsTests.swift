import Foundation
import Testing
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Загрузки при проверке на бота: очередь встаёт вся сразу, ни ошибки, ни повтора, ни лишних запросов. Тесты — в том
/// же наборе, что и остальные про бота: заглушка YouTube одна на всех, наборы идут по одному.
extension BotCheckStopTests {
    private static let ids = ["a1aaaaaaaaa", "b2bbbbbbbbb", "c3ccccccccc"]

    @MainActor
    private func queue(_ respond: @escaping @Sendable (YouTubeStub.Seen) -> YouTubeStub.Reply) async throws
        -> (DownloadManager, DownloadStore, URL) {
        let (resolver, _) = await self.resolver(respond)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-bot-dl-\(UUID().uuidString)")
        let store = DownloadStore(database: try AppDatabase.inMemory(), directory: directory)
        // Разные `created_at`: порядок очереди — по нему
        for id in Self.ids {
            store.requestTrack(Track(videoId: id, title: id, durationMs: 200_000))
            try await Task.sleep(for: .milliseconds(3))
        }
        return (DownloadManager(store: store, resolver: resolver), store, directory)
    }

    /// Ждём, пока очередь встанет: у всех строк «ждёт» с причиной, загрузчик остановлен.
    @MainActor
    private func waitUntilHeld(_ manager: DownloadManager, _ store: DownloadStore, requests: Int) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < 10 {
            let held = manager.blockedByBotCheck && YouTubeStub.requests.count >= requests
                && store.entries().allSatisfy { $0.state == .waiting && $0.wait == .botCheck }
            if held { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("очередь не встала: \(store.entries().map { "\($0.videoId) \($0.state) \(String(describing: $0.wait))" }), запросов \(YouTubeStub.requests.count)")
    }

    /// Три загрузки в очереди, проверка на бота на первой: один запрос, остальные стоят на своих местах с причиной.
    @MainActor
    @Test func downloadQueueStopsWithOneRequestAndKeepsItsPlaces() async throws {
        let (manager, store, directory) = try await queue { _ in .json(Self.loginRequired) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = store.entries().map(\.createdAt).sorted()
        manager.pump()
        try await waitUntilHeld(manager, store, requests: 1)
        // С запасом на повторы и «следующие» загрузки
        try await Task.sleep(for: .seconds(1))
        #expect(YouTubeStub.requests.count == 1, "\(YouTubeStub.requests)")
        let entries = store.entries()
        #expect(entries.count == 3)
        for entry in entries {
            #expect(entry.state == .waiting && entry.wait == .botCheck, "\(entry.videoId): \(entry.state)")
            #expect(entry.failure == nil && entry.attempts == 0, "не ошибка и не попытка")
        }
        #expect(entries.map(\.createdAt).sorted() == created, "места в очереди те же")
        #expect(store.pending(limit: 10) == Self.ids, "порядок очереди сохранён")
        // Новая загрузка при закрытом адресе тоже встаёт, а не идёт в YouTube
        store.requestTrack(Track(videoId: "d4ddddddddd", title: "d", durationMs: 200_000))
        manager.pump()
        try await Task.sleep(for: .milliseconds(300))
        #expect(YouTubeStub.requests.count == 1)
        #expect(store.entry("d4ddddddddd")?.wait == .botCheck)
    }

    /// «Повторить» и смена сети: по одному запросу-пробе; адрес всё ещё закрыт — очередь снова стоит.
    @MainActor
    @Test func retryAndNetworkChangeResumeWithOneProbeEach() async throws {
        let (manager, store, directory) = try await queue { _ in .json(Self.loginRequired) }
        defer { try? FileManager.default.removeItem(at: directory) }
        manager.pump()
        try await waitUntilHeld(manager, store, requests: 1)

        manager.resumeAfterBotCheck()
        try await waitUntilHeld(manager, store, requests: 2)
        try await Task.sleep(for: .seconds(0.7))
        #expect(YouTubeStub.requests.count == 2, "«Повторить» — одна проба: \(YouTubeStub.requests)")
        #expect(store.pending(limit: 10) == Self.ids)

        // Двойное нажатие — всё та же одна проба
        manager.resumeAfterBotCheck()
        manager.resumeAfterBotCheck()
        try await waitUntilHeld(manager, store, requests: 3)
        try await Task.sleep(for: .seconds(0.7))
        #expect(YouTubeStub.requests.count == 3, "\(YouTubeStub.requests)")

        manager.networkChanged()
        try await waitUntilHeld(manager, store, requests: 4)
        try await Task.sleep(for: .seconds(0.7))
        #expect(YouTubeStub.requests.count == 4, "смена сети — одна проба")
        #expect(store.entries().allSatisfy { $0.failure == nil && $0.attempts == 0 })
    }
}
