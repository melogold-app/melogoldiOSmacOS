import SwiftUI
import MelogoldCore
import MelogoldData

/// «История» (REWRITE §3.2.4): «Недавние» — разные треки по последнему прослушиванию, по дням, тап — трек и радио;
/// «Чаще всего» за период — номера 1…100, тап — список. «Очистить историю…» — с «Отменить». Фильтр по устройствам
/// (задание 0002) — со срезом 5.
struct HistoryView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case recent, top
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .recent
    @State private var recent: [HistoryEntry] = []
    @State private var top: [TopEntry] = []
    @State private var confirmClear = false
    @State private var playCount = 0

    var body: some View {
        @Bindable var settings = model.settings
        let clearing = model.isHidden(PendingKey.allHistory)
        let visibleRecent = clearing ? [] : recent.filter { !model.isHidden(PendingKey.history($0.track.videoId)) }
        let visibleTop = clearing ? [] : top.filter { !model.isHidden(PendingKey.history($0.track.videoId)) }
        let topTracks = visibleTop.map(\.track)
        SelectableList(target: { id in
            guard let (section, key) = RowID.split(id) else { return nil }
            if section == "r" { return visibleRecent.first { $0.track.videoId == key }.map { .single($0.track) } }
            return topTracks.firstIndex { $0.videoId == key }.map { .list(topTracks, $0) }
        }, context: { _ in .history }) {
            Section {
                Picker(selection: $mode) {
                    Text("history.recent").tag(Mode.recent)
                    Text("history.top").tag(Mode.top)
                } label: {
                    Text("library.history")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
                if settings.historyPaused {
                    HStack {
                        Label("history.paused", systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("history.resume") { settings.historyPaused = false }
                            .buttonStyle(.borderless)
                    }
                    .listRowSeparator(.hidden)
                }
                if mode == .top {
                    Picker(selection: $settings.historyPeriod) {
                        ForEach(HistoryPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    } label: {
                        Text("history.period")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowSeparator(.hidden)
                }
            }
            if mode == .recent {
                ForEach(groups(visibleRecent), id: \.day) { group in
                    Section {
                        ForEach(group.entries, id: \.track.id) { entry in
                            TrackListRow(track: entry.track,
                                         trailing: Date(timeIntervalSince1970: Double(entry.playedAt) / 1000).formatted(date: .omitted, time: .shortened),
                                         target: .single(entry.track), context: .history)
                                .tag(RowID.make("r", entry.track.videoId))
                        }
                    } header: {
                        Text(verbatim: group.title)
                    }
                }
                if visibleRecent.isEmpty {
                    EmptyRow(title: "library.history", systemImage: "clock", description: "history.empty")
                }
            } else {
                ForEach(Array(visibleTop.enumerated()), id: \.element.track.id) { index, entry in
                    TrackListRow(track: entry.track,
                                 subtitle: [entry.track.artistsText, LibraryText.playTime(entry.playTimeMs)].compactMap { $0 }.joined(separator: " · "),
                                 number: index + 1, showsArtwork: false, target: .list(topTracks, index), context: .history)
                        .tag(RowID.make("t", entry.track.videoId))
                }
                if visibleTop.isEmpty {
                    EmptyRow(title: "library.history", systemImage: "chart.bar", description: playCount == 0 ? "history.empty" : "history.emptyPeriod")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text("library.history"))
        .inlineTitle()
        .toolbar {
            ToolbarItem {
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("history.clear", systemImage: "trash")
                    }
                    .disabled(playCount == 0)
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog(Text("history.clear.confirm \(playCount)"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button("history.clear", role: .destructive) { model.clearHistory() }
        } message: {
            Text("history.clear.message")
        }
        .task(id: TaskKey(revision: model.library?.revision ?? 0, mode: mode, period: settings.historyPeriod)) { reload() }
    }

    private struct TaskKey: Hashable {
        let revision: Int
        let mode: Mode
        let period: HistoryPeriod
    }

    private func reload() {
        guard let library = model.library?.library else { return }
        playCount = library.playCount()
        switch mode {
        case .recent: recent = library.recentHistory()
        case .top: top = library.mostPlayed(since: model.settings.historyPeriod.since)
        }
    }

    /// Группы по дням: «Сегодня», «Вчера», «пн, 21 сентября».
    private func groups(_ entries: [HistoryEntry]) -> [(day: Date, title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(day: Date, title: String, entries: [HistoryEntry])] = []
        for entry in entries {
            let date = Date(timeIntervalSince1970: Double(entry.playedAt) / 1000)
            let day = calendar.startOfDay(for: date)
            if result.last?.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                let title: String = if calendar.isDateInToday(date) {
                    String(localized: "history.today")
                } else if calendar.isDateInYesterday(date) {
                    String(localized: "history.yesterday")
                } else {
                    date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
                }
                result.append((day, title, [entry]))
            }
        }
        return result
    }
}

extension HistoryPeriod {
    var title: LocalizedStringResource {
        switch self {
        case .days7: "history.period.7d"
        case .days30: "history.period.30d"
        case .year: "history.period.year"
        case .allTime: "history.period.all"
        }
    }

    /// Начало периода, epoch-мс; всё время — `nil`.
    var since: Int64? {
        let day: Int64 = 24 * 3600 * 1000
        let now = EpochMs.now()
        switch self {
        case .days7: return now - 7 * day
        case .days30: return now - 30 * day
        case .year: return now - 365 * day
        case .allTime: return nil
        }
    }
}
