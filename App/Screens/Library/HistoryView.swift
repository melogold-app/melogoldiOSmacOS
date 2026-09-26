import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldServer

/// «История» (REWRITE §3.2.4): «Недавние» — разные треки по последнему прослушиванию, по дням, тап — трек и радио;
/// «Чаще всего» за период — номера 1…100, тап — список. «Очистить историю…» — с подтверждением и «Отменить».
/// С аккаунтом история общая (задание 0002): фильтр по устройствам в панели инструментов, «Убрать из истории» и
/// «Очистить историю» — на всех устройствах.
struct HistoryView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case recent, top
        var id: String { rawValue }
    }

    /// Чьи прослушивания показаны (задание 0002 §3.5).
    enum DeviceChoice: Hashable {
        case all, thisDevice
        case other(String)
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .recent
    @State private var recent: [HistoryEntry] = []
    @State private var top: [TopEntry] = []
    @State private var confirmClear = false
    /// Все прослушивания здесь — для «Очистить историю…»; `shownCount` — выбранного устройства.
    @State private var playCount = 0
    @State private var shownCount = 0
    /// Другие устройства, чьи прослушивания лежат здесь; пусто — фильтра нет.
    @State private var devices: [HistoryDevice] = []
    @State private var device: DeviceChoice = .all

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
                    EmptyRow(title: "library.history", systemImage: "chart.bar", description: shownCount == 0 || clearing ? "history.empty" : "history.emptyPeriod")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(Text("library.history"))
        #if !os(visionOS)
        .navigationSubtitle(subtitle)
        #endif
        .inlineTitle()
        .toolbar {
            if !devices.isEmpty {
                ToolbarItem {
                    deviceMenu
                }
            }
            ToolbarItem {
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("history.clear", systemImage: "trash")
                    }
                    .disabled(playCount == 0)
                } label: {
                    Label("menu.more", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("history.more")
            }
        }
        .confirmationDialog(clearTitle, isPresented: $confirmClear, titleVisibility: .visible) {
            Button("history.clear.action", role: .destructive) { model.clearHistory() }
        } message: {
            Text("history.clear.message")
        }
        .task(id: TaskKey(revision: model.library?.revision ?? 0, mode: mode, period: settings.historyPeriod, filter: filter)) { reload() }
        // Список устройств: имена перечитываются на `devices.updated` (SSE), события — с каждой правкой истории
        .task(id: DevicesKey(revision: model.library?.revision ?? 0, devicesRevision: model.sync.devicesRevision,
                             signedIn: model.account.isSignedIn)) { await reloadDevices() }
    }

    private struct TaskKey: Hashable {
        let revision: Int
        let mode: Mode
        let period: HistoryPeriod
        let filter: HistoryDeviceFilter
    }

    private struct DevicesKey: Hashable {
        let revision: Int
        let devicesRevision: Int
        let signedIn: Bool
    }

    /// Выбор, который действует: без фильтра или без выбранного устройства в списке — «Все устройства».
    private var choice: DeviceChoice {
        switch device {
        case .all: .all
        case .thisDevice: devices.isEmpty ? .all : .thisDevice
        case .other(let id): devices.contains { $0.id == id } ? device : .all
        }
    }

    private var filter: HistoryDeviceFilter {
        switch choice {
        case .all: .all
        case .thisDevice: .thisDevice(currentDeviceId: model.sync.currentDeviceId)
        case .other(let id): .device(id)
        }
    }

    /// Меню «Все устройства · Это устройство · <имя устройства>…» (задание 0002 §3.5).
    private var deviceMenu: some View {
        Menu {
            Picker(selection: $device) {
                Label("history.device.all", systemImage: "laptopcomputer.and.iphone")
                    .tag(DeviceChoice.all)
                Label("history.device.this", systemImage: DeviceSymbol.name(for: model.account.identity.platform))
                    .tag(DeviceChoice.thisDevice)
                ForEach(devices) { device in
                    Label {
                        Text(deviceName(device))
                    } icon: {
                        Image(systemName: device.platform.map(DeviceSymbol.name) ?? "questionmark.circle")
                    }
                    .tag(DeviceChoice.other(device.id))
                }
            } label: {
                Text("history.device.choose")
            }
            .pickerStyle(.inline)
        } label: {
            #if os(visionOS)
            // Подзаголовка на visionOS нет: выбранное устройство — в самой кнопке
            if choice == .all {
                Label("history.device.choose", systemImage: "laptopcomputer.and.iphone")
            } else {
                Label { Text(subtitle) } icon: { Image(systemName: "laptopcomputer.and.iphone") }
                    .labelStyle(.titleAndIcon)
            }
            #else
            Label("history.device.choose", systemImage: "laptopcomputer.and.iphone")
            #endif
        }
        .accessibilityValue(Text(choice == .all ? String(localized: "history.device.all") : subtitle))
        .accessibilityIdentifier("history.devices")
    }

    private func deviceName(_ device: HistoryDevice) -> String {
        device.name ?? String(localized: "history.device.other")
    }

    /// Выбранное устройство под заголовком; «Все устройства» — без подзаголовка.
    private var subtitle: String {
        switch choice {
        case .all: ""
        case .thisDevice: String(localized: "history.device.this")
        case .other(let id): devices.first { $0.id == id }.map(deviceName) ?? ""
        }
    }

    /// С аккаунтом история общая: очищается на всех устройствах аккаунта.
    private var clearTitle: Text {
        model.account.isSignedIn ? Text("history.clear.confirmEverywhere \(playCount)") : Text("history.clear.confirm \(playCount)")
    }

    private func reload() {
        guard let library = model.library?.library else { return }
        let filter = filter
        playCount = library.playCount()
        shownCount = filter == .all ? playCount : library.playCount(device: filter)
        switch mode {
        case .recent: recent = library.recentHistory(device: filter)
        case .top: top = library.mostPlayed(since: model.settings.historyPeriod.since, device: filter)
        }
    }

    private func reloadDevices() async {
        let list = await model.sync.historyDevices()
        guard !Task.isCancelled else { return }
        devices = list
        // Устройства больше нет среди прослушиваний или вышли из аккаунта — снова все устройства
        if choice != device { device = .all }
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
