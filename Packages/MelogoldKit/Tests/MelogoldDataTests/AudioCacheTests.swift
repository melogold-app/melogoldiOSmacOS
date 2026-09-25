import Foundation
import Testing
@testable import MelogoldData

@Suite("Кэш музыки — задание 0003")
struct AudioCacheTests {
    private func makeCache(limit: Int64) throws -> (AudioCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("melogold-cache-\(UUID().uuidString)")
        let cache = AudioCache(database: try AppDatabase.inMemory(), directory: directory, limit: { limit })
        return (cache, directory)
    }

    private func fill(_ cache: AudioCache, _ videoId: String, bytes: Int, readAt: Int64? = nil) {
        cache.prepare(videoId: videoId, itag: 140, mimeType: "audio/mp4", contentLength: Int64(bytes), durationMs: 1000, loudnessDb: nil)
        cache.write(videoId, offset: 0, data: Data(repeating: 7, count: bytes))
    }

    @Test func rangesMerge() {
        var ranges = ByteRanges()
        ranges.insert(0..<100)
        ranges.insert(200..<300)
        ranges.insert(100..<200)
        #expect(ranges.ranges == [0..<300])
        ranges.insert(500..<600)
        #expect(ranges.serialized == "0-300,500-600")
        #expect(ByteRanges(serialized: "0-300,500-600") == ranges)
        #expect(ranges.contains(10..<290))
        #expect(!ranges.contains(250..<550))
        #expect(ranges.available(from: 250) == 50)
        #expect(ranges.totalBytes == 400)
    }

    @Test func completeWithPartialLastChunk() throws {
        let (cache, directory) = try makeCache(limit: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.prepare(videoId: "aaaaaaaaaaa", itag: 140, mimeType: "audio/mp4", contentLength: 1_300_000, durationMs: 80_000, loudnessDb: 0.4)
        cache.write("aaaaaaaaaaa", offset: 0, data: Data(repeating: 1, count: 524_288))
        #expect(!cache.isComplete("aaaaaaaaaaa"))
        cache.write("aaaaaaaaaaa", offset: 1_048_576, data: Data(repeating: 3, count: 1_300_000 - 1_048_576))
        #expect(!cache.isComplete("aaaaaaaaaaa"))
        cache.write("aaaaaaaaaaa", offset: 524_288, data: Data(repeating: 2, count: 524_288))
        #expect(cache.isComplete("aaaaaaaaaaa"))
        #expect(cache.read("aaaaaaaaaaa", offset: 1_299_990, length: 10) == Data(repeating: 3, count: 10))
        #expect(cache.read("aaaaaaaaaaa", offset: 1_299_990, length: 11) == nil)
        #expect(cache.completeEntry("aaaaaaaaaaa")?.durationMs == 80_000)
    }

    @Test func formatChangeDropsOldBytes() throws {
        let (cache, directory) = try makeCache(limit: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        fill(cache, "bbbbbbbbbbb", bytes: 1000)
        #expect(cache.isComplete("bbbbbbbbbbb"))
        cache.prepare(videoId: "bbbbbbbbbbb", itag: 139, mimeType: "audio/mp4", contentLength: 500, durationMs: 1000, loudnessDb: nil)
        #expect(!cache.isComplete("bbbbbbbbbbb"))
        #expect(cache.entry("bbbbbbbbbbb")?.itag == 139)
        #expect(cache.entry("bbbbbbbbbbb")?.cachedBytes == 0)
        #expect(cache.read("bbbbbbbbbbb", offset: 0, length: 10) == nil)
    }

    @Test func evictsLeastRecentlyReadFirst() throws {
        let (cache, directory) = try makeCache(limit: 2500)
        defer { try? FileManager.default.removeItem(at: directory) }
        fill(cache, "track000001", bytes: 1000)
        Thread.sleep(forTimeInterval: 0.01)
        fill(cache, "track000002", bytes: 1000)
        Thread.sleep(forTimeInterval: 0.01)
        cache.touch("track000001")
        Thread.sleep(forTimeInterval: 0.01)
        fill(cache, "track000003", bytes: 1000)
        // 3000 > 2500: уходит тот, кого дольше всех не слушали, — второй
        #expect(cache.entry("track000002") == nil)
        #expect(cache.entry("track000001") != nil)
        #expect(cache.entry("track000003") != nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL("track000002").path))
        #expect(cache.totalBytes() == 2000)
    }

    @Test func playingTrackIsNotEvicted() throws {
        let (cache, directory) = try makeCache(limit: 1500)
        defer { try? FileManager.default.removeItem(at: directory) }
        fill(cache, "playing0001", bytes: 1000)
        cache.setProtected(["playing0001"])
        Thread.sleep(forTimeInterval: 0.01)
        fill(cache, "newtrack001", bytes: 1000)
        #expect(cache.entry("playing0001") != nil)
        #expect(cache.entry("newtrack001") != nil || cache.totalBytes() <= 1500)
    }

    @Test func reconcileRemovesStrayFilesAndForgetsMissing() throws {
        let (cache, directory) = try makeCache(limit: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        fill(cache, "kept0000001", bytes: 100)
        fill(cache, "gone0000001", bytes: 100)
        try FileManager.default.removeItem(at: cache.fileURL("gone0000001"))
        let stray = directory.appendingPathComponent("stray000001.m4a")
        FileManager.default.createFile(atPath: stray.path, contents: Data([1, 2, 3]))
        cache.reconcile()
        #expect(cache.entry("gone0000001") == nil)
        #expect(cache.entry("kept0000001") != nil)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func searchHistoryKeepsRecentFirst() throws {
        let history = SearchHistory(database: try AppDatabase.inMemory())
        history.add("кино")
        Thread.sleep(forTimeInterval: 0.01)
        history.add("сплин")
        Thread.sleep(forTimeInterval: 0.01)
        history.add("кино")
        #expect(history.recent() == ["кино", "сплин"])
        history.remove("кино")
        #expect(history.recent() == ["сплин"])
        history.clear()
        #expect(history.recent().isEmpty)
    }
}
