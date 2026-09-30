import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Устройство» (задание 0020): где играет музыка. Это устройство — и системный выбор вывода звука (AirPlay,
/// Bluetooth); другие устройства аккаунта — со статусом, тем, что они играют, и громкостью. Выбор другого устройства
/// превращает лист в пульт; «Отключиться» возвращает управление этому устройству.
struct RemoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Список устройств поверх открытого пульта («Сменить устройство»).
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Group {
                if let remote = model.remoteBridge?.remote, remote.isActive, !picking {
                    RemotePlayerView(remote: remote, onPickDevice: { picking = true })
                } else {
                    DeviceList(onDone: { picking = false })
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("account.done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
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
                    remote?.disconnect()
                    onDone()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: DeviceSymbol.name(for: model.account.identity.platform))
                            .font(.title3)
                            .frame(width: 32)
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
                        .frame(width: 30, height: 30)
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
                            remote.connect(device)
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
                .frame(width: 32)
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

/// Пульт: что играет на выбранном устройстве, кнопки, перемотка и громкость — команды уходят туда
/// (`POST /playback/commands`). Позиция между событиями считается от `at` состояния.
struct RemotePlayerView: View {
    @Environment(AppModel.self) private var model
    @Bindable var remote: RemoteControl
    let onPickDevice: () -> Void

    @State private var scrubbing: Double?

    var body: some View {
        let target = remote.target
        ScrollView {
            VStack(spacing: 20) {
                Button(action: onPickDevice) {
                    Label {
                        Text("remote.playingOn \(target?.name ?? "")")
                    } icon: {
                        Image(systemName: DeviceSymbol.name(for: target?.platform ?? ""))
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .glassButton()

                if let state = remote.state, let track = state.track {
                    ArtworkView(url: track.thumbnailUrl, size: 260)
                        .accessibilityHidden(true)
                    VStack(spacing: 4) {
                        Text(verbatim: track.title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        if let artist = track.artistsText {
                            Text(verbatim: artist)
                                .foregroundStyle(.secondary)
                        }
                    }
                    progress(state)
                    transport(playing: state.playing)
                } else {
                    ContentUnavailableView {
                        Label("remote.nothingPlaying", systemImage: "music.note")
                    }
                    transport(playing: false)
                }

                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: Binding(get: { Double(remote.volume ?? 0) }, set: { remote.setVolume(Int($0.rounded())) }), in: 0 ... 100)
                        .accessibilityLabel(Text("player.volume"))
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await model.remoteBridge?.listenHere() }
                    } label: {
                        Text("remote.listenHere")
                            .frame(maxWidth: .infinity)
                    }
                    .prominentGlassButton()
                    .controlSize(.large)
                    Button("remote.disconnect") { remote.disconnect() }
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("remote.device"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func progress(_ state: PlaybackSummary) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = Double(state.durationMs ?? 0) / 1000
            let live = Double(remote.livePositionMs() ?? state.positionMs) / 1000
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { scrubbing ?? live }, set: { scrubbing = $0 }),
                    in: 0 ... max(duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubbing else { return }
                        scrubbing = nil
                        Task { await remote.seek(toMs: Int64(target * 1000)) }
                    }
                )
                .disabled(duration <= 0)
                .accessibilityLabel(Text("player.seek"))
                HStack {
                    Text(verbatim: Durations.format(Int64((scrubbing ?? live) * 1000)))
                    Spacer()
                    Text(verbatim: "−" + Durations.format(Int64(max(0, duration - (scrubbing ?? live)) * 1000)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// ⏮ ⏯ ⏭ пульта — как в «Сейчас играет»: значки без рамок, под пальцем круг (`TransportPressStyle`). Явные «пауза»
    /// и «играть» по тому, что видно на пульте: переключатель при устаревшем состоянии сделал бы обратное.
    private func transport(playing: Bool) -> some View {
        HStack(spacing: Design.Space.xl) {
            Button { Task { await remote.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 30, weight: .semibold)).frame(width: 60, height: 60)
            }
            .buttonStyle(TransportPressStyle(diameter: 60))
            .accessibilityLabel(Text("player.previous"))
            Button { Task { if playing { await remote.pause() } else { await remote.play() } } } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .frame(width: 76, height: 76)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(TransportPressStyle(diameter: 76))
            .accessibilityLabel(Text(playing ? "player.pause" : "player.play"))
            .sensoryFeedback(.selection, trigger: playing)
            Button { Task { await remote.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 30, weight: .semibold)).frame(width: 60, height: 60)
            }
            .buttonStyle(TransportPressStyle(diameter: 60))
            .accessibilityLabel(Text("player.next"))
        }
    }
}

/// Кнопка «Устройство» в нижнем ряду «Сейчас играет» (задание 0020): с аккаунтом на сервере с пультом — лист
/// «Устройство» (в нём и AirPlay этого устройства); без аккаунта или на старом сервере — системный AirPlay. Пока пульт
/// управляет другим устройством — значок того устройства, акцентом.
struct DeviceButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.account.isSignedIn, model.account.supportsRemote, let remote = model.remoteBridge?.remote {
            Button { model.remoteSheet = true } label: {
                Image(systemName: remote.isActive ? DeviceSymbol.name(for: remote.target?.platform ?? "") : "airplay.audio")
                    .font(.title3)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(remote.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: Design.Size.minTap, height: Design.Size.minTap)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
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
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
