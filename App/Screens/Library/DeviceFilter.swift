import SwiftUI
import MelogoldData
import MelogoldServer

/// Фильтр «Все устройства · Это устройство · <устройство аккаунта>» (задание 0002 §3.5) — тот же, что в Истории, для «Итогов»
/// (задание 0018). Устройства — те, чьи прослушивания лежат здесь (`LibrarySync.historyDevices`).
@MainActor
@Observable
final class DeviceFilterState {
    enum Choice: Hashable {
        case all, thisDevice
        case other(String)
    }

    var choice: Choice = .all
    private(set) var devices: [HistoryDevice] = []

    /// Выбор, который действует: без фильтра или без выбранного устройства в списке — «Все устройства».
    var effective: Choice {
        switch choice {
        case .all: .all
        case .thisDevice: devices.isEmpty ? .all : .thisDevice
        case .other(let id): devices.contains { $0.id == id } ? choice : .all
        }
    }

    func filter(currentDeviceId: String?) -> HistoryDeviceFilter {
        switch effective {
        case .all: .all
        case .thisDevice: .thisDevice(currentDeviceId: currentDeviceId)
        case .other(let id): .device(id)
        }
    }

    func reload(_ sync: LibrarySync) async {
        let list = await sync.historyDevices()
        guard !Task.isCancelled else { return }
        devices = list
        if effective != choice { choice = .all }
    }

    func name(_ device: HistoryDevice) -> String {
        device.name ?? String(localized: "history.device.other")
    }

    /// Выбранное устройство словами; «Все устройства» — пусто.
    var subtitle: String {
        switch effective {
        case .all: ""
        case .thisDevice: String(localized: "history.device.this")
        case .other(let id): devices.first { $0.id == id }.map(name) ?? ""
        }
    }
}

/// Меню выбора устройства: пока других устройств нет, его нет.
struct DeviceFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DeviceFilterState

    var body: some View {
        if !state.devices.isEmpty {
            Menu {
                Picker(selection: $state.choice) {
                    Label("history.device.all", systemImage: "laptopcomputer.and.iphone")
                        .tag(DeviceFilterState.Choice.all)
                    Label("history.device.this", systemImage: DeviceSymbol.name(for: model.account.identity.platform))
                        .tag(DeviceFilterState.Choice.thisDevice)
                    ForEach(state.devices) { device in
                        Label {
                            Text(state.name(device))
                        } icon: {
                            Image(systemName: device.platform.map(DeviceSymbol.name) ?? "questionmark.circle")
                        }
                        .tag(DeviceFilterState.Choice.other(device.id))
                    }
                } label: {
                    Text("history.device.choose")
                }
                .pickerStyle(.inline)
            } label: {
                Label("history.device.choose", systemImage: "laptopcomputer.and.iphone")
            }
            .accessibilityValue(Text(state.effective == .all ? String(localized: "history.device.all") : state.subtitle))
            .accessibilityIdentifier("stats.devices")
        }
    }
}
