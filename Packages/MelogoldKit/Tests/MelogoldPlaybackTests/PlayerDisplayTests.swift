import Foundation
import Testing
import MelogoldCore
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Свои названия в плеере (задание 0014): очередь и «Сейчас играет» получают правку данными, а в снимок очереди и в базу
/// уходит оригинал.
@MainActor
@Suite("Плеер — свои названия")
struct PlayerDisplayTests {
    let fan = Track(videoId: "a1aaaaaaaaa", title: "Кино — Звезда (live, fan upload)", artistsText: "Fan Channel", albumTitle: nil, durationMs: 200_000)
    let other = Track(videoId: "b2bbbbbbbbb", title: "Другая", artistsText: "Кто-то", durationMs: 100_000)

    private func engine() -> PlayerEngine {
        let catalog = YouTubeMusic(client: InnerTubeClient())
        return PlayerEngine(catalog: catalog, resolver: StreamResolver(catalog: catalog), cache: nil)
    }

    private func snapshot(_ tracks: [Track]) -> PlayerEngine.Snapshot {
        PlayerEngine.Snapshot(items: tracks.map { .init(track: $0, fromAutoplay: false) }, index: 0, position: 0)
    }

    @Test func queueAndCurrentTrackShowTheOverride() {
        let player = engine()
        var overrides: [String: TrackOverride] = [:]
        player.display = { track in overrides[track.videoId]?.apply(to: track) ?? track.raw }
        player.restore(snapshot([fan, other]), play: false)
        #expect(player.currentTrack?.title == "Кино — Звезда (live, fan upload)")

        overrides["a1aaaaaaaaa"] = TrackOverride(title: "Звезда", artistsText: "Кино", albumTitle: "Концерт")
        player.refreshDisplay()
        #expect(player.currentTrack?.title == "Звезда" && player.currentTrack?.albumTitle == "Концерт")
        #expect(player.items.map(\.track.title) == ["Звезда", "Другая"])
        #expect(player.upcoming.map(\.track.title) == ["Другая"])

        // Снимок очереди — оригинал: правка живёт в своей таблице и переживёт очередь только там
        let saved = player.snapshot()
        #expect(saved?.items.first?.track.raw == fan)
        let json = try? JSONEncoder().encode(saved)
        let restored = json.flatMap { try? JSONDecoder().decode(PlayerEngine.Snapshot.self, from: $0) }
        #expect(restored?.items.first?.track == fan)

        // «Как на YouTube»
        overrides = [:]
        player.refreshDisplay()
        #expect(player.currentTrack == fan)
    }

    /// Треки, добавленные позже («В конец очереди», «Играть следующим»), тоже показываются с правкой — и уже показанные
    /// (из меню плеера) не наслаивают правку на правку.
    @Test func enqueuedTracksAreShownToo() {
        let player = engine()
        let override = TrackOverride(title: "Своё")
        player.display = { track in track.videoId == "b2bbbbbbbbb" ? override.apply(to: track) : track.raw }
        player.restore(snapshot([fan]), play: false)
        player.enqueue([other])
        #expect(player.items.map(\.track.title) == [fan.title, "Своё"])
        player.enqueue([override.apply(to: other)])
        #expect(player.items.last?.track.original?.title == "Другая", "оригинал сохранён")
        #expect(player.items.last?.track.raw == other)
    }
}
