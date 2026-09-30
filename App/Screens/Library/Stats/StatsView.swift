import Charts
import SwiftUI
import MelogoldCore
import MelogoldData

/// «Итоги» (задание 0018, Android `StatsScreen.kt`): сколько слушал и что больше всего — за неделю, месяц, год и всё время.
/// Период листают стрелками (сентябрь 2026 ← август 2026), устройства — как в Истории; числа со сравнением с прошлым таким
/// же периодом, топы (10 и «Показать все» до 50), «Когда слушал», «Время суток», «Открытия». Всё считается на устройстве
/// из Истории, без сети.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var period: StatsPeriod = .month
    @State private var offset = 0
    @State private var devices = DeviceFilterState()
    @State private var stats: ListeningStats?
    @State private var showAllTracks = false
    @State private var showAllArtists = false
    @State private var showAllAlbums = false

    private static let shown = 10

    private var calendar: Calendar { .current }
    private var locale: Locale { .current }

    var body: some View {
        let queue = stats?.topTracks ?? []
        let tracks = queue.map(\.track)
        let discovered = stats?.discoveries?.top ?? []
        SelectableList(target: target(queue: queue, discovered: discovered), rowIds: rowIds(queue: queue, discovered: discovered)) {
            controls
            if let stats {
                if stats.isEmpty {
                    empty
                } else {
                    content(stats, queue: queue, tracks: tracks, discovered: discovered)
                }
                if period == .allTime { note }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .navigationTitle(Text("stats.title"))
        .inlineTitle()
        .toolbar {
            ToolbarItem { DeviceFilterMenu(state: devices) }
        }
        .task(id: TaskKey(revision: model.library?.revision ?? 0, period: period, offset: offset, device: devices.effective,
                          devicesLoaded: devices.devices.count)) { await reload() }
        .task(id: model.sync.devicesRevision) { await devices.reload(model.sync) }
    }

    private struct TaskKey: Hashable {
        let revision: Int
        let period: StatsPeriod
        let offset: Int
        let device: DeviceFilterState.Choice
        let devicesLoaded: Int
    }

    // MARK: - Управление

    @ViewBuilder
    private var controls: some View {
        Section {
            Picker(selection: Binding(get: { period }, set: { period = $0; offset = 0 })) {
                Text("stats.week").tag(StatsPeriod.week)
                Text("stats.month").tag(StatsPeriod.month)
                Text("stats.year").tag(StatsPeriod.year)
                Text("stats.allTime").tag(StatsPeriod.allTime)
            } label: {
                Text("stats.title")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("stats.period")
            if let stats, period != .allTime {
                navigator(stats)
            }
        }
    }

    /// ‹ Сентябрь 2026 ›: назад — пока История начинается раньше, вперёд — не дальше текущего периода.
    private func navigator(_ stats: ListeningStats) -> some View {
        HStack {
            Button { offset -= 1 } label: {
                Label("stats.previous", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!stats.hasEarlier)
            .accessibilityIdentifier("stats.previous")
            Spacer()
            Text(verbatim: StatsFormat.windowTitle(stats.window, today: Date(), calendar: calendar, locale: locale))
                .font(.headline)
                .monospacedDigit()
                .accessibilityIdentifier("stats.windowTitle")
            Spacer()
            Button { offset += 1 } label: {
                Label("stats.next", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(stats.window.isCurrent)
            .accessibilityIdentifier("stats.next")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Содержимое

    @ViewBuilder
    private func content(_ stats: ListeningStats, queue: [TopTrack], tracks: [Track], discovered: [TopTrack]) -> some View {
        if period == .year {
            Section {
                Button {
                    model.wrappedYear = calendar.component(.year, from: stats.window.firstDay ?? Date())
                } label: {
                    Label("stats.wrapped", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("stats.wrapped")
            }
            .listRowBackground(Color.clear)
        }
        numbers(stats)
        if !queue.isEmpty {
            Section {
                let rows = showAllTracks ? queue : Array(queue.prefix(Self.shown))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, top in
                    trackRow(top, index: index, queue: tracks, key: "top")
                }
                showAll(count: queue.count, expanded: $showAllTracks, id: "stats.tracksAll")
            } header: {
                Text("stats.topTracks")
            }
        }
        if !stats.topArtists.isEmpty {
            Section {
                let rows = showAllArtists ? stats.topArtists : Array(stats.topArtists.prefix(Self.shown))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, artist in
                    groupRow(artist, number: index + 1, circle: true, key: "ar")
                }
                showAll(count: stats.topArtists.count, expanded: $showAllArtists, id: "stats.artistsAll")
            } header: {
                Text("stats.topArtists")
            }
        }
        if !stats.topAlbums.isEmpty {
            Section {
                let rows = showAllAlbums ? stats.topAlbums : Array(stats.topAlbums.prefix(Self.shown))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, album in
                    groupRow(album, number: index + 1, circle: false, key: "al")
                }
                showAll(count: stats.topAlbums.count, expanded: $showAllAlbums, id: "stats.albumsAll")
            } header: {
                Text("stats.topAlbums")
            }
        }
        whenSection(stats)
        if let discoveries = stats.discoveries, discoveries.count > 0 {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stats.discovered \(discoveries.count)").font(.headline)
                    Text("stats.discoveriesText").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(discovered.enumerated()), id: \.element.id) { index, top in
                    trackRow(top, index: index, queue: discovered.map(\.track), key: "new")
                }
            } header: {
                Text("stats.discoveries")
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("stats.empty", systemImage: "chart.bar")
        }
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("stats.empty")
    }

    private var note: some View {
        Text("stats.allTimeNote")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    // MARK: - Числа

    private func numbers(_ stats: ListeningStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("stats.listeningTime")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: StatsFormat.listeningTime(ms: stats.totalMs, locale: locale))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityIdentifier("stats.time")
                if let change = changeText(stats) {
                    Text(verbatim: change)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("stats.change")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                tile(stats.plays, "stats.plays", id: "stats.plays")
                tile(stats.tracks, "stats.tracks", id: "stats.tracks")
                tile(stats.artists, "stats.artists", id: "stats.artists")
            }
        }
    }

    private func tile(_ value: Int, _ label: LocalizedStringResource, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value.formatted(.number))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(id)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// «+12 % к августу»; без прошлого периода для сравнения — ничего.
    private func changeText(_ stats: ListeningStats) -> String? {
        guard let percent = stats.changePercent, let first = stats.window.firstDay else { return nil }
        let target: String
        switch stats.window.period {
        case .week:
            target = String(localized: "stats.vsLastWeek")
        case .year:
            target = String(localized: "stats.vsYear \(calendar.component(.year, from: first) - 1)")
        case .month:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: first) else { return nil }
            let month = calendar.component(.month, from: previous)
            let name = monthCompare(month)
            let year = calendar.component(.year, from: previous)
            // Месяц другого года называет год, чтобы «к декабрю 2025» не читалось как этот год
            target = year == calendar.component(.year, from: Date()) ? name : String(localized: "stats.vsMonthYear \(name) \(year)")
        case .allTime:
            return nil
        }
        let signed = StatsFormat.signedPercent(percent, language: locale.language.languageCode?.identifier ?? "en")
        return String(localized: "stats.change \(signed) \(target)")
    }

    private func monthCompare(_ month: Int) -> String {
        let keys: [LocalizedStringResource] = [
            "stats.vsMonth.1", "stats.vsMonth.2", "stats.vsMonth.3", "stats.vsMonth.4", "stats.vsMonth.5", "stats.vsMonth.6",
            "stats.vsMonth.7", "stats.vsMonth.8", "stats.vsMonth.9", "stats.vsMonth.10", "stats.vsMonth.11", "stats.vsMonth.12",
        ]
        return String(localized: keys[(month - 1) % 12])
    }

    // MARK: - Топы

    private func trackRow(_ top: TopTrack, index: Int, queue: [Track], key: String) -> some View {
        let subtitle = [top.artist, String(localized: "stats.playsCount \(top.plays)")].compactMap { $0 }.joined(separator: " · ")
        return TrackListRow(track: top.track, subtitle: subtitle, number: index + 1,
                            trailing: StatsFormat.listeningTime(ms: top.ms, locale: locale), target: .list(queue, index))
            .tag(RowID.make(key, top.track.videoId))
    }

    /// Исполнитель или альбом топа: нажатие открывает страницу YouTube Music, а у своего названия без неё — ищет его.
    private func groupRow(_ group: TopGroup, number: Int, circle: Bool, key: String) -> some View {
        TapTarget(target: openTarget(group, isArtist: circle)) {
            HStack(spacing: 12) {
                Text(verbatim: "\(number)")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24)
                ArtworkView(url: group.thumbnailUrl, size: 48, shape: circle ? .circle : .rounded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.name).font(.body).lineLimit(1)
                    Text(verbatim: String(localized: "stats.playsCount \(group.plays)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(verbatim: StatsFormat.listeningTime(ms: group.ms, locale: locale))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .tag(RowID.make(key, group.key))
    }

    private func openTarget(_ group: TopGroup, isArtist: Bool) -> RowTarget {
        if let browseId = group.browseId { return .open(isArtist ? .artist(browseId) : .album(browseId)) }
        return .action { [model] in
            model.section = .search
            model.routes[.search] = []
            model.searchQuery = group.name
            model.search.submit(group.name)
        }
    }

    @ViewBuilder
    private func showAll(count: Int, expanded: Binding<Bool>, id: String) -> some View {
        if count > Self.shown {
            Button(expanded.wrappedValue ? "stats.showLess" : "stats.showAll") {
                withAnimation { expanded.wrappedValue.toggle() }
            }
            .accessibilityIdentifier(id)
        }
    }

    // MARK: - Когда слушал

    private func whenSection(_ stats: ListeningStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                StatsBarsChart(stats: stats, calendar: calendar, locale: locale)
                Text("stats.timeOfDay")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                StatsHoursChart(stats: stats)
            }
            .padding(.vertical, 4)
        } header: {
            Text("stats.when")
        }
    }

    // MARK: - Список

    private func target(queue: [TopTrack], discovered: [TopTrack]) -> (String) -> RowTarget? {
        let tracks = queue.map(\.track)
        let newTracks = discovered.map(\.track)
        return { id in
            guard let (section, key) = RowID.split(id) else { return nil }
            switch section {
            case "top": return tracks.firstIndex { $0.videoId == key }.map { .list(tracks, $0) }
            case "new": return newTracks.firstIndex { $0.videoId == key }.map { .list(newTracks, $0) }
            case "ar": return stats?.topArtists.first { $0.key == key }.map { openTarget($0, isArtist: true) }
            case "al": return stats?.topAlbums.first { $0.key == key }.map { openTarget($0, isArtist: false) }
            default: return nil
            }
        }
    }

    private func rowIds(queue: [TopTrack], discovered: [TopTrack]) -> [String] {
        let top = showAllTracks ? queue : Array(queue.prefix(Self.shown))
        return top.map { RowID.make("top", $0.track.videoId) } + discovered.map { RowID.make("new", $0.track.videoId) }
    }

    // MARK: - Подсчёт

    private func reload() async {
        guard let library = model.library?.library else { return }
        let window = StatsWindow.make(period, offset: offset)
        let filter = devices.filter(currentDeviceId: model.sync.currentDeviceId)
        let overrides = library.allTrackOverrides().mapValues(\.statOverride)
        let calendar = calendar
        let result = await Task.detached(priority: .userInitiated) {
            library.listeningStats(window: window, device: filter, overrides: overrides, calendar: calendar)
        }.value
        guard !Task.isCancelled else { return }
        stats = result
    }
}
