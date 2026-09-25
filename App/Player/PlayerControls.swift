import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Подпись под названием: исполнитель; пока нет потока — «Получаем поток…» (3 с) и «Долго… · Пропустить» (15 с);
/// при ошибке — причина словами (docs/PROMPT.md §5.7, REWRITE §3.10.9).
struct PlayerStatusLine: View {
    @Environment(AppModel.self) private var model
    var font: Font = .subheadline

    var body: some View {
        let player = model.services.player
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if player.phase == .failed, let failure = player.failure {
                    Label(failure.text, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                } else if player.phase == .loading, let since = player.loadingSince, context.date.timeIntervalSince(since) >= 15 {
                    Text("player.slow")
                        .foregroundStyle(.secondary)
                } else if player.phase == .loading, let since = player.loadingSince, context.date.timeIntervalSince(since) >= 3 {
                    Text("player.gettingStream")
                        .foregroundStyle(.secondary)
                } else {
                    Text(player.currentTrack?.artistsText ?? "")
                        .foregroundStyle(.secondary)
                }
            }
            .font(font)
            .lineLimit(1)
        }
    }
}

/// ⏯: пока нет потока — индикатор на его месте; при ошибке — «Повторить».
struct PlayPauseButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title2

    var body: some View {
        let player = model.services.player
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                if player.phase == .loading, player.isPlaying {
                    ProgressView()
                } else if player.phase == .failed {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
            }
            .font(size)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(player.phase == .failed ? "common.retry" : (player.isPlaying ? "player.pause" : "player.play")))
    }
}

struct NextButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3

    var body: some View {
        Button { model.services.player.next() } label: {
            Image(systemName: "forward.fill")
                .font(size)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.services.player.hasNext)
        .accessibilityLabel(Text("player.next"))
    }
}

struct PreviousButton: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3

    var body: some View {
        Button { model.services.player.previous() } label: {
            Image(systemName: "backward.fill")
                .font(size)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("player.previous"))
    }
}

/// Ползунок перемотки: перетаскивание относительное, позиция применяется при отпускании; слева прошедшее время,
/// справа оставшееся со знаком минус (docs/PROMPT.md §5.7).
struct SeekBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: Double?

    var body: some View {
        let player = model.services.player
        let duration = max(player.duration, 0.1)
        let value = dragging ?? min(player.position, duration)
        VStack(spacing: 4) {
            Slider(value: Binding(get: { value }, set: { dragging = $0 }), in: 0...duration) { editing in
                if !editing, let target = dragging {
                    player.seek(to: target)
                    dragging = nil
                }
            }
            .disabled(player.duration <= 0)
            .accessibilityLabel(Text("player.position"))
            .accessibilityValue(Text(verbatim: Durations.format(seconds: value)))
            HStack {
                Text(verbatim: Durations.format(seconds: value))
                Spacer()
                Text(verbatim: "−" + Durations.format(seconds: max(0, duration - value)))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

extension PlaybackFailure {
    /// Текст карточки ошибки (REWRITE §3.10.9).
    var text: LocalizedStringResource {
        switch kind {
        case .network: "player.error.network"
        case .botCheck: "player.error.botCheck"
        case .geo: "player.error.geo"
        case .unavailable: "player.error.unavailable"
        case .age: "player.error.age"
        case .timeout: "player.error.timeout"
        case .extractor: "player.error.extractor"
        case .manySkips: "player.error.manySkips"
        case .noAudioRoute: "player.error.noRoute"
        }
    }

    /// Причина в плашке пропуска: «Пропущен „Трек“: недоступен в регионе».
    var shortText: LocalizedStringResource {
        switch kind {
        case .network: "player.skip.network"
        case .botCheck: "player.skip.botCheck"
        case .geo: "player.skip.geo"
        case .unavailable: "player.skip.unavailable"
        case .age: "player.skip.age"
        case .timeout: "player.skip.timeout"
        case .extractor, .manySkips: "player.skip.extractor"
        case .noAudioRoute: "player.skip.noRoute"
        }
    }
}
