import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Устройство» на часах (задание 0020, docs/PROMPT.md §5.6): только выбор, где играет музыка — другие устройства
/// аккаунта со статусом и «На часах» внизу. Выбор возвращает назад; управление выбранным устройством — в «Сейчас играет»
/// (`WatchRemotePlayer`). Своё воспроизведение часы другим не отдают: звук часов — наушники рядом с ними.
struct WatchRemoteView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let remote = model.remote
        List {
            if remote.loading && remote.devices.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if remote.devices.isEmpty {
                Text("remote.noDevices")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(remote.devices) { device in
                Button {
                    model.connect(device)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: DeviceSymbol.name(for: device.platform))
                            .foregroundStyle(device.online ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: device.name)
                                .lineLimit(1)
                            Text(verbatim: status(device))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if remote.target?.deviceId == device.deviceId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel(Text("remote.selected"))
                        }
                    }
                }
                .disabled(!device.online || !device.controllable)
            }
            Section {
                Button {
                    remote.disconnect()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "airpods")
                            .accessibilityHidden(true)
                        Text("play.thisWatch")
                        Spacer(minLength: 0)
                        if !remote.isActive {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel(Text("remote.selected"))
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("remote.device"))
        .task { await remote.refresh() }
    }

    private func status(_ device: RemoteDevice) -> String {
        guard device.online else { return String(localized: "remote.offline.short") }
        guard device.controllable else { return String(localized: "remote.controlOff") }
        if let track = device.playing?.track {
            return [track.artistsText, track.title].compactMap { $0 }.joined(separator: " — ")
        }
        return String(localized: "remote.online")
    }
}

/// Управление выбранным устройством — «Сейчас играет», пока музыка играет не на часах.
struct WatchRemotePlayer: View {
    @Bindable var remote: RemoteControl
    /// Громкость под колёсиком: пока крутят — своя, команда уходит пультом с задержкой.
    @State private var crown: Double = 0
    @State private var crownReady = false
    /// Колёсико встало на громкость, пришедшую с цели: это не поворот, команду не слать (иначе эхо).
    @State private var applyingRemote = false

    var body: some View {
        let playing = remote.state?.playing ?? false
        ScrollView {
            VStack(spacing: 8) {
                // Где играет; нажатие — выбрать другое устройство или часы
                NavigationLink(value: WatchRoute.remote) {
                    Label {
                        Text("remote.playingOn \(remote.target?.name ?? "")")
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: DeviceSymbol.name(for: remote.target?.platform ?? ""))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)

                if let track = remote.state?.track {
                    Text(verbatim: track.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let artist = track.artistsText {
                        Text(verbatim: artist)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("remote.nothingPlaying")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Button { Task { await remote.previous() } } label: {
                        Image(systemName: "backward.fill")
                    }
                    .accessibilityLabel(Text("player.previous"))
                    // Явные «пауза» и «играть» по видимому состоянию: переключатель при устаревшем состоянии сделал бы обратное
                    Button { Task { if playing { await remote.pause() } else { await remote.play() } } } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel(Text(playing ? "player.pause" : "player.play"))
                    Button { Task { await remote.next() } } label: {
                        Image(systemName: "forward.fill")
                    }
                    .accessibilityLabel(Text("player.next"))
                }
                .buttonStyle(.bordered)

                if remote.volume != nil {
                    Gauge(value: crown, in: 0 ... 100) {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .accessibilityLabel(Text("player.volume"))
                    .accessibilityValue(Text(verbatim: "\(Int(crown)) %"))
                }

            }
            .padding(.horizontal, 4)
        }
        .focusable()
        .digitalCrownRotation($crown, from: 0, through: 100, by: 2, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear {
            crown = Double(remote.volume ?? 0)
            crownReady = true
        }
        .onChange(of: remote.volume) { _, value in
            // Громкость пришла с цели (или от другого пульта): колёсико встаёт на неё, если его сейчас не крутят
            if let value, abs(Double(value) - crown) > 2 {
                applyingRemote = true
                crown = Double(value)
            }
        }
        .onChange(of: crown) { _, value in
            if applyingRemote {
                applyingRemote = false
                return
            }
            guard crownReady, remote.volume != nil else { return }
            remote.setVolume(Int(value.rounded()))
        }
    }
}

/// «Где слушать?» после нажатия на трек: сверху устройства аккаунта (на них трек включится пультом), снизу — эти часы с
/// AirPods и другими наушниками. Список сразу из прошлого ответа сервера, свежий подтягивается в фоне.
struct WatchPlayTargetView: View {
    @Environment(WatchModel.self) private var model
    let pending: WatchModel.PendingPlay

    var body: some View {
        let remote = model.remote
        List {
            Section {
                if remote.devices.isEmpty {
                    if remote.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("remote.noDevices")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(remote.devices) { device in
                    Button {
                        model.play(pending, on: device)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: DeviceSymbol.name(for: device.platform))
                                .foregroundStyle(device.online ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: device.name)
                                    .lineLimit(1)
                                Text(device.online ? (device.controllable ? "remote.online" : "remote.controlOff") : "remote.offline.short")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!device.online || !device.controllable)
                }
            } header: {
                Text("remote.otherDevices")
            }
            Section {
                Button {
                    model.playHere(pending)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "airpods")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("play.thisWatch")
                            Text("play.thisWatch.detail")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("play.where"))
    }
}
