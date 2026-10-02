import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Устройство» (задание 0020): только выбор, где играет музыка — это устройство (и системный выбор вывода звука:
/// AirPlay, Bluetooth) или другое устройство аккаунта. Выбор закрывает лист; что играет и кнопки — в плеере окна
/// (`PlaybackFacade`). Пользователь (2026-10-02): «окно выбора устройства только делает выбор, органы управления — на
/// основном» — прежний второй плеер в этом листе путал: окно показывало одно, играло другое.
struct RemoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DeviceList(onDone: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("account.done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

/// Список устройств: это и другие устройства аккаунта (`GET /playback/devices`).
private struct DeviceList: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        let remote = model.remoteBridge?.remote
        List {
            Section {
                Button {
                    model.selectPlaybackDevice(nil)
                    onDone()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: DeviceSymbol.name(for: model.account.identity.platform))
                            .font(.title3)
                            .frame(minWidth: 32)
                            .accessibilityHidden(true)
                        Text("remote.thisDevice")
                        Spacer()
                        if remote?.isActive != true {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel(Text("remote.selected"))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if !os(visionOS)
                HStack {
                    Text("remote.audioOutput")
                    Spacer()
                    RoutePickerButton()
                        .frame(width: Design.Size.hitTarget, height: Design.Size.hitTarget)
                        .accessibilityLabel(Text("player.airplay"))
                }
                #endif
            }

            Section {
                if !model.account.isSignedIn {
                    Text("remote.signIn")
                        .foregroundStyle(.secondary)
                } else if !model.account.supportsRemote {
                    Text("remote.serverOld")
                        .foregroundStyle(.secondary)
                } else if let remote {
                    if remote.loading && remote.devices.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if remote.devices.isEmpty {
                        Text("remote.noDevices")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(remote.devices) { device in
                        Button {
                            model.selectPlaybackDevice(device)
                            onDone()
                        } label: {
                            RemoteDeviceRow(device: device, selected: remote.target?.deviceId == device.deviceId)
                        }
                        .buttonStyle(.plain)
                        .disabled(!device.online || !device.controllable)
                    }
                }
            } header: {
                Text("remote.otherDevices")
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        .navigationTitle(Text("remote.device"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await remote?.refresh() }
        .refreshable { await remote?.refresh() }
    }
}

/// Строка устройства: значок, имя и «В сети · Кино — Группа крови · Громкость 60 %» / «Не в сети» / «Управление
/// выключено».
private struct RemoteDeviceRow: View {
    let device: RemoteDevice
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceSymbol.name(for: device.platform))
                .font(.title3)
                .frame(minWidth: 32)
                .foregroundStyle(device.online ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(Text(DeviceSymbol.kind(for: device.platform)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.name)
                    .foregroundStyle(device.online ? .primary : .secondary)
                Text(verbatim: status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text("remote.selected"))
            }
        }
        .contentShape(Rectangle())
    }

    private var status: String {
        guard device.online else { return String(localized: "remote.offline.short") }
        var parts = [String(localized: "remote.online")]
        if !device.controllable { parts.append(String(localized: "remote.controlOff")) }
        if let track = device.playing?.track {
            parts.append([track.artistsText, track.title].compactMap { $0 }.joined(separator: " — "))
        }
        if let volume = device.playing?.volume ?? device.volume {
            parts.append(String(localized: "remote.volumePercent \(volume)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Кнопка «Устройство» в нижнем ряду «Сейчас играет» (задание 0020): с аккаунтом на сервере с пультом — лист
/// «Устройство» (в нём и AirPlay этого устройства); без аккаунта или на старом сервере — системный AirPlay. Пока пульт
/// управляет другим устройством — значок того устройства, акцентом.
struct DeviceButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.secondaryOnTint) private var secondaryTint

    var body: some View {
        if model.account.isSignedIn, model.account.supportsRemote, let remote = model.remoteBridge?.remote {
            Button { model.remoteSheet = true } label: {
                Image(systemName: remote.isActive ? DeviceSymbol.name(for: remote.target?.platform ?? "") : "airplay.audio")
                    .font(.title3)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(remote.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(secondaryTint))
                    .frame(width: Design.Size.minTap, height: Design.Size.minTap)
                    .contentShape(Rectangle())
                    .symbolReplace()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("remote.device"))
            .accessibilityValue(remote.isActive ? Text("remote.playingOn \(remote.target?.name ?? "")") : Text(verbatim: ""))
        } else {
            #if !os(visionOS)
            RoutePickerButton()
                .frame(width: Design.Size.minTap, height: Design.Size.minTap)
                .accessibilityLabel(Text("player.airplay"))
            #endif
        }
    }
}

/// «Играет на «Pixel»»: пока пульт управляет другим устройством, над нижним рядом «Сейчас играет»; нажатие — пульт.
struct RemotePlayingPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let remote = model.remoteBridge?.remote, remote.isActive, let target = remote.target {
            Button { model.remoteSheet = true } label: {
                Label {
                    Text("remote.playingOn \(target.name)")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: DeviceSymbol.name(for: target.platform))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, 6)
                .controlGlass(Capsule(), interactive: true)
                .tapTarget()
            }
            .buttonStyle(.plain)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
