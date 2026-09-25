import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Мини-плеер (docs/PROMPT.md §5.2): обложка, название, исполнитель, ⏯ и ⏭. Нажатие открывает «Сейчас играет»,
/// смахивание вбок — соседний трек (решение пользователя №8 Android); для VoiceOver — «Предыдущий трек» и
/// «Следующий трек». На iPhone — `tabViewBottomAccessory`, на iPad — полоса внизу колонки детали, на Vision — орнамент.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let player = model.services.player
        if let track = player.currentTrack {
            HStack(spacing: 10) {
                ArtworkView(url: track.artworkURL, size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    PlayerStatusLine(font: .caption)
                }
                .offset(x: dragOffset)
                Spacer(minLength: 4)
                PlayPauseButton(size: .title3)
                NextButton(size: .body)
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { model.showNowPlaying = true }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) { dragOffset = value.translation.width / 3 }
                    }
                    .onEnded { value in
                        withAnimation(.snappy) { dragOffset = 0 }
                        guard abs(value.translation.width) > 60, abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < 0 { player.next() } else { player.previous() }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(track.title), \(track.artistsText ?? "")"))
            .accessibilityHint(Text("player.openNowPlaying"))
            .accessibilityAction { model.showNowPlaying = true }
            .accessibilityAction(named: Text("player.previousTrack")) { player.previous() }
            .accessibilityAction(named: Text("player.nextTrack")) { player.next() }
            .accessibilityAction(named: Text(player.isPlaying ? "player.pause" : "player.play")) { player.togglePlayPause() }
        }
    }
}

/// Плашка пропуска: «Пропущен „Трек“: недоступен в регионе» — над мини-плеером, 4 секунды.
struct SkipNoticeOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        if let notice = player.notice {
            Text("player.skipped \(notice.skippedTitle) \(String(localized: PlaybackFailure(kind: notice.reason, videoId: nil).shortText))")
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                #if os(visionOS)
                .glassBackgroundEffect(in: .capsule)
                #else
                .glassEffect(.regular, in: .capsule)
                #endif
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if player.notice?.id == notice.id { player.notice = nil }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
