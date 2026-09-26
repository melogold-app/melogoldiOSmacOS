import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldPlayback

enum DownloadsSort: String, CaseIterable {
    case date, title, artist

    var title: LocalizedStringResource {
        switch self {
        case .date: "sort.downloadDate"
        case .title: "sort.title"
        case .artist: "sort.artist"
        }
    }
}

/// «Скачанное» (REWRITE §3.2.3, задание 0003): «Скачивается» с прогрессом и «Пауза · Продолжить», «Ошибки · Повторить
/// все», скачиваемые плейлисты и альбомы «k из n», скачанные треки; ниже группа «В кэше · N · X МБ» — играют без сети,
/// пока их не сменят новые треки. Без сети экран работает полностью.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [DownloadEntry] = []
    @State private var collections: [DownloadCollection] = []
    @State private var cached: [Track] = []
    @State private var cachedBytes: Int64 = 0
    @State private var filter = ""
    @State private var sort: DownloadsSort = .date
    @State private var showCached = true

    var body: some View {
        let manager = model.services.downloads
        let completed = sorted(entries.filter { $0.state == .completed && !model.isHidden(PendingKey.download($0.videoId)) }
            .compactMap(\.track).filter { matches($0, filter) })
        let active = entries.filter { [.queued, .downloading, .waiting, .paused].contains($0.state) }
        let failed = entries.filter { $0.state == .failed }
        let cachedVisible = cached.filter { matches($0, filter) }
        SelectableList(target: { id in
            guard let (section, key) = RowID.split(id) else { return nil }
            let list = section == "c" ? cachedVisible : completed
            return list.firstIndex { $0.videoId == key }.map { .list(list, $0) }
        }) {
            if !completed.isEmpty {
                TrackListHeader(summary: LibraryText.summary(completed) + " · " + bytes(manager?.store.totalBytes() ?? 0)) {
                    model.playAll(completed, shuffled: false)
                } shuffle: {
                    model.playAll(completed, shuffled: true)
                }
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { entry in activeRow(entry, manager) }
                } header: {
                    HStack {
                        Text("downloads.active \(active.count)")
                        Spacer()
                        let paused = active.allSatisfy { $0.state == .paused }
                        Button(paused ? "downloads.resume" : "downloads.pause") { manager?.setPaused(!paused) }
                            .font(.subheadline)
                    }
                }
            }
            if !failed.isEmpty {
                Section {
                    ForEach(failed) { entry in failedRow(entry, manager) }
                } header: {
                    HStack {
                        Text("downloads.failed \(failed.count)")
                        Spacer()
                        Button("downloads.retryAll") { manager?.retryFailed() }.font(.subheadline)
                    }
                }
            }
            if !collections.isEmpty {
                Section {
                    ForEach(collections) { collection in collectionRow(collection) }
                } header: {
                    Text("downloads.collections")
                }
            }
            Section {
                ForEach(Array(completed.enumerated()), id: \.element.id) { index, track in
                    TrackListRow(track: track, target: .list(completed, index))
                        .tag(RowID.make("d", track.videoId))
                }
                if completed.isEmpty, active.isEmpty, failed.isEmpty {
                    EmptyRow(title: "library.downloads", systemImage: "arrow.down.circle", description: "downloads.empty", filter: filter)
                }
            }
            #if !os(watchOS)
            if !cachedVisible.isEmpty {
                Section(isExpanded: $showCached) {
                    ForEach(Array(cachedVisible.enumerated()), id: \.element.id) { index, track in
                        TrackListRow(track: track, target: .list(cachedVisible, index))
                            .tag(RowID.make("c", track.videoId))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("downloads.cached \(cachedVisible.count) \(bytes(cachedBytes))")
                        Text("downloads.cached.note").font(.footnote).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
            #endif
        }
        .listStyle(.plain)
        .navigationTitle(Text("library.downloads"))
        .inlineTitle()
        .searchable(text: $filter, prompt: Text("library.filter"))
        .toolbar {
            ToolbarItem {
                SortMenu(options: DownloadsSort.allCases, selection: $sort) { $0.title }
            }
        }
        .onAppear { sort = model.settings.sortOption("downloads", default: .date) }
        .onChange(of: sort) { _, value in model.settings.setSort(value.rawValue, for: "downloads") }
        .task(id: DownloadKey(library: model.library?.revision ?? 0, downloads: model.library?.downloadsRevision ?? 0)) { reload() }
    }

    private struct DownloadKey: Hashable {
        let library: Int
        let downloads: Int
    }

    private func activeRow(_ entry: DownloadEntry, _ manager: DownloadManager?) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: manager?.progress[entry.videoId] ?? entry.progress)
                .progressViewStyle(.circular)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.track?.title ?? entry.videoId).lineLimit(1)
                Text(status(entry)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { manager?.remove(entry.videoId) } label: {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("menu.cancelDownload"))
        }
    }

    private func failedRow(_ entry: DownloadEntry, _ manager: DownloadManager?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.track?.title ?? entry.videoId).lineLimit(1)
                Text(failureText(entry.failure)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button { manager?.retry(entry.videoId) } label: { Label("common.retry", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { manager?.remove(entry.videoId) } label: { Label("downloads.delete", systemImage: "trash") }
                if let track = entry.track {
                    Button { model.searchOtherVersions(of: track) } label: { Label("menu.otherVersions", systemImage: "square.on.square") }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 44)
            }
            .buttonStyle(.borderless)
        }
    }

    private func collectionRow(_ collection: DownloadCollection) -> some View {
        Button {
            switch collection.kind {
            case .playlist: if let id = Int64(collection.key) { model.open(.localPlaylist(id)) }
            case .album: model.open(.album(collection.key))
            case .liked: model.open(.favorites)
            }
        } label: {
            LabeledContent {
                Text("download.progress \(collection.done) \(collection.total)").monospacedDigit()
            } label: {
                Label {
                    Text(verbatim: collection.kind == .liked ? String(localized: "library.favorites") : (collection.title ?? collection.key))
                } icon: {
                    Image(systemName: collection.kind == .album ? "square.stack" : collection.kind == .liked ? "heart" : "music.note.list")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                model.services.downloads?.setCollection(collection.kind, key: collection.key, title: collection.title, downloading: false)
            } label: {
                Label("menu.removeDownload", systemImage: "trash")
            }
        }
    }

    /// «45 %», «Ждём Wi‑Fi», «Нет сети», «Не хватает места», «Пауза», «В очереди».
    private func status(_ entry: DownloadEntry) -> LocalizedStringResource {
        switch entry.state {
        case .waiting:
            switch entry.wait {
            case .wifi: "downloads.wait.wifi"
            case .storage: "downloads.wait.storage"
            default: "downloads.wait.network"
            }
        case .paused: "downloads.paused"
        case .downloading: "downloads.downloading \(Int((model.services.downloads?.progress[entry.videoId] ?? entry.progress) * 100))"
        default: "downloads.queued"
        }
    }

    private func failureText(_ code: String?) -> LocalizedStringResource {
        switch code.flatMap(StreamError.Kind.init(rawValue:)) {
        case .geo: "player.error.geo"
        case .unavailable: "player.error.unavailable"
        case .age: "player.error.age"
        case .botCheck: "player.error.botCheck"
        case .timeout: "player.error.timeout"
        case .network: "downloads.error.network"
        default: "player.error.extractor"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func sorted(_ list: [Track]) -> [Track] {
        switch sort {
        case .date: list
        case .title: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: list.sorted { ($0.artistsText ?? "").localizedStandardCompare($1.artistsText ?? "") == .orderedAscending }
        }
    }

    private func reload() {
        let store = model.services.downloads?.store
        entries = store?.entries() ?? []
        collections = store?.collections() ?? []
        #if !os(watchOS)
        let downloaded = Set(entries.filter { $0.state == .completed }.map(\.videoId))
        let sizes = (model.services.cache?.completeSizes() ?? []).filter { !downloaded.contains($0.videoId) }
        cached = sizes.compactMap { model.library?.library.track($0.videoId) }
        cachedBytes = sizes.reduce(0) { $0 + $1.bytes }
        #endif
    }
}
