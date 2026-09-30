import SwiftUI
import MelogoldCore
import MelogoldData

/// «Итоги» на часах (задание 0018): только время прослушивания за текущий месяц и трек месяца — без топов и графиков.
struct WatchStatsView: View {
    @Environment(WatchModel.self) private var model
    @State private var stats: ListeningStats?

    var body: some View {
        List {
            if let stats {
                if stats.isEmpty {
                    Text("stats.empty").foregroundStyle(.secondary)
                } else {
                    Section {
                        Text(verbatim: StatsFormat.listeningTime(ms: stats.totalMs, locale: .current))
                            .font(.title3.weight(.bold))
                        if let change = changeText(stats) {
                            Text(verbatim: change).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("stats.listeningTime")
                    }
                    if let top = stats.topTracks.first {
                        Section {
                            HStack(spacing: 8) {
                                ArtworkView(url: top.track.artworkURL, size: 40)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: top.title).font(.footnote).lineLimit(2)
                                    if let artist = top.artist {
                                        Text(verbatim: artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        } header: {
                            Text("stats.trackOfMonth")
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("stats.title"))
        .task(id: model.services.library?.revision) { await reload() }
    }

    private func changeText(_ stats: ListeningStats) -> String? {
        guard let percent = stats.changePercent else { return nil }
        return StatsFormat.signedPercent(percent, language: Locale.current.language.languageCode?.identifier ?? "en")
    }

    private func reload() async {
        guard let library = model.services.library?.library else { return }
        let overrides = library.allTrackOverrides().mapValues(\.statOverride)
        stats = await Task.detached(priority: .userInitiated) {
            library.listeningStats(window: .make(.month), overrides: overrides)
        }.value
    }
}
