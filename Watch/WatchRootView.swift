import SwiftUI
import MelogoldCore

/// Корень часов — список (HIG watchOS): «Сейчас играет», когда есть очередь, затем разделы в общем порядке
/// Тренды · Новое · Библиотека · Поиск · Настройки (docs/PROMPT.md §5.6).
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            List {
                if let track = model.services.player.currentTrack {
                    NavigationLink(value: WatchRoute.nowPlaying) {
                        HStack(spacing: 8) {
                            ArtworkView(url: track.artworkURL, size: 32)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("player.openNowPlaying").font(.caption2).foregroundStyle(.secondary)
                                Text(track.title).font(.footnote).lineLimit(1)
                            }
                        }
                    }
                }
                ForEach(AppSection.allCases) { section in
                    NavigationLink(value: WatchRoute.section(section)) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "Melogold"))
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .section(let section): WatchSectionView(section: section)
                case .nowPlaying: WatchNowPlayingView()
                }
            }
        }
    }
}

struct WatchSectionView: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .search:
            WatchSearchView()
        case .settings:
            WatchSettingsView()
        default:
            ContentUnavailableView {
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationTitle(Text(section.title))
        }
    }
}

struct WatchSettingsView: View {
    var body: some View {
        List {
            Section {
                WatchAccountSection()
            }
            Section("settings.about") {
                LabeledContent {
                    Text(verbatim: AppVersion.current)
                } label: {
                    Text("settings.version")
                }
            }
        }
        .navigationTitle(Text(AppSection.settings.title))
    }
}
