import SwiftUI
import MelogoldCore
import MelogoldServer

/// Пульт на часах (задание 0020, docs/PROMPT.md §5.6): другие устройства аккаунта со статусом; выбранное — что на нём
/// играет, ⏮ ⏯ ⏭ и громкость колёсиком Digital Crown (команда через 150 мс после последнего поворота). «Отключиться» —
/// обратно к списку. Своё воспроизведение часы другим не отдают: звук часов — наушники рядом с ними.
struct WatchRemoteView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let remote = model.remote
        Group {
            if remote.isActive {
                WatchRemotePlayer(remote: remote)
            } else {
                WatchDeviceList(remote: remote)
            }
        }
        .navigationTitle(Text("remote.device"))
    }
}

/// Другие устройства аккаунта: в сети и с управлением — нажимаются.
private struct WatchDeviceList: View {
    let remote: RemoteControl

    var body: some View {
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
                    remote.connect(device)
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
                    }
                }
                .disabled(!device.online || !device.controllable)
            }
        }
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

/// Управление выбранным устройством.
private struct WatchRemotePlayer: View {
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
                Label {
                    Text("remote.playingOn \(remote.target?.name ?? "")")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: DeviceSymbol.name(for: remote.target?.platform ?? ""))
                }
                .font(.caption2)
                .foregroundStyle(.tint)

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

                Button("remote.disconnect") { remote.disconnect() }
                    .font(.footnote)
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
