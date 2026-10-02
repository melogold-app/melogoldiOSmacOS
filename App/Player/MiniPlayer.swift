import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Мини-плеер (docs/PROMPT.md §5.2): обложка, название, исполнитель, ⏯ и ⏭. Нажатие открывает «Сейчас играет»,
/// смахивание вбок листает треки, как страницы (решение пользователя №8 Android); для VoiceOver — «Предыдущий трек» и
/// «Следующий трек». На iPhone — `tabViewBottomAccessory`, на iPad — полоса внизу колонки детали, на Vision — орнамент.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    /// `.inline` — панель вкладок свёрнута (`tabBarMinimizeBehavior`), мини-плеер стоит рядом с ней в тесном месте.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif

    /// Тесный вид: обложка, название, ⏯ — без исполнителя и ⏭. Так же на крупном Dynamic Type.
    private var compact: Bool {
        #if os(iOS)
        if placement == .inline { return true }
        #endif
        return typeSize.isAccessibilitySize
    }

    var body: some View {
        if let track = model.playingTrack {
            let player = model.services.player
            // Пульт другого устройства соседей не знает: лента поддаётся, команда уходит, трек сменится по его отчёту
            let remote = model.remoteTarget != nil
            HStack(spacing: Design.Space.s) {
                TrackPager(
                    current: track,
                    previous: remote ? nil : player.previousItem?.track,
                    next: remote ? nil : player.nextItem?.track,
                    compact: compact,
                    onPrevious: { remote ? model.playbackPrevious() : player.skipBack() },
                    onNext: { model.playbackNext() },
                    commitsWithoutNeighbour: remote
                )
                PlayPauseButton(size: .title3)
                if !compact { NextButton(size: .body) }
            }
            .padding(.horizontal, Design.Space.s)
            .contentShape(Rectangle())
            #if os(visionOS)
            // Нажатие без кнопки: отклик на взгляд — свой, а не системный (у `onTapGesture` его нет)
            .hoverEffect()
            #endif
            .onTapGesture { model.showNowPlaying = true }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(track.title), \(track.artistsText ?? "")"))
            .accessibilityValue(Text(model.playingIsPlaying ? "player.playing" : "player.paused"))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("player.openNowPlaying"))
            .accessibilityAction { model.showNowPlaying = true }
            .accessibilityAction(named: Text("player.previousTrack")) { remote ? model.playbackPrevious() : player.skipBack() }
            .accessibilityAction(named: Text("player.nextTrack")) { model.playbackNext() }
            .accessibilityAction(named: Text(model.playingIsPlaying ? "player.pause" : "player.play")) { model.togglePlayback() }
        }
    }
}

/// Лента мини-плеера: предыдущий, текущий и следующий трек стоят рядом, палец тянет все три — как страницы
/// (пользователь, 2026-10-02: на iPhone строка съезжала вбок и возвращалась с той же стороны уже с новым треком, «точь-в-точь
/// как было на Android»; там то же исправлено в d43953c6). Отпущено дальше 40 % ширины с учётом скорости — соседний трек
/// доезжает до места и становится текущим без скачка, иначе пружина назад. Где соседа нет — лента поддаётся и
/// возвращается. Прерванный жест (система забрала касание) тоже возвращает ленту на место — не залипает сдвинутой.
private struct TrackPager: View {
    let current: Track
    let previous: Track?
    let next: Track?
    let compact: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    /// Пульт: соседей не видно, но команда по свайпу всё равно уходит.
    var commitsWithoutNeighbour = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var settling = false
    /// Палец на ленте; сбрасывается сам и при прерванном жесте — тогда лента возвращается.
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                slot(previous).frame(width: width)
                slot(current).frame(width: width)
                slot(next).frame(width: width)
            }
            .offset(x: -width + offset)
            .frame(width: width, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .highPriorityGesture(drag(width: width))
        }
        .frame(height: compact ? 32 : 40)
        .onChange(of: touching) { _, now in
            // Жест прервали без `onEnded`: лента не должна остаться сдвинутой
            if !now, !settling, offset != 0 { withAnimation(.snappy) { offset = 0 } }
        }
        .onChange(of: current.videoId) {
            // Трек сменился сам (кончился, выбран в списке) посреди жеста — лента встаёт на место без анимации
            if !settling, !touching { offset = 0 }
        }
    }

    private func slot(_ track: Track?) -> some View {
        HStack(spacing: Design.Space.s) {
            if let track {
                ArtworkView(url: track.artworkURL, size: compact ? 28 : 36, cornerRadius: compact ? 6 : Design.Radius.small)
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !compact {
                        if track.videoId == current.videoId {
                            // Пока выбрано другое устройство, строка говорит где (задание 0020)
                            PlayerStatusLine(font: .caption)
                        } else {
                            Text(track.artistsText ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                guard !settling, abs(value.translation.width) > abs(value.translation.height) else { return }
                let dx = value.translation.width
                let blocked = (dx > 0 && previous == nil) || (dx < 0 && next == nil)
                // Соседа нет — лента поддаётся втрое слабее и упирается
                offset = blocked ? dx / 3 : max(-width, min(width, dx))
            }
            .onEnded { value in
                guard !settling, width > 0 else { return }
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let forward = dx < 0
                let far = abs(dx) > width * 0.4 || abs(predicted) > width * 0.6
                let neighbour = forward ? next : previous
                guard far, abs(dx) > abs(value.translation.height) else {
                    springBack()
                    return
                }
                guard neighbour != nil else {
                    springBack()
                    if commitsWithoutNeighbour { forward ? onNext() : onPrevious() }
                    return
                }
                settling = true
                let finish = { [onNext, onPrevious] in
                    // Трек сменился в тот же такт, что лента встала в середину: новый текущий — уже на месте
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        forward ? onNext() : onPrevious()
                        offset = 0
                    }
                    settling = false
                }
                if reduceMotion {
                    finish()
                } else {
                    withAnimation(.snappy(duration: 0.28)) {
                        offset = forward ? -width : width
                    } completion: {
                        finish()
                    }
                }
            }
    }

    private func springBack() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { offset = 0 }
    }
}

/// Плашка над мини-плеером (REWRITE §2.3 «Снекбары»): пропуск трека и его причина или сообщение окна
/// («Играет следующим: …»). Одна на окно, держится 4 секунды.
struct ToastHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        Group {
            if let pending = model.pending {
                capsule {
                    HStack(spacing: 12) {
                        Text(verbatim: pending.text)
                        Button {
                            model.undoPending()
                        } label: {
                            Text("common.undo").fontWeight(.semibold).tapTarget()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else if let toast = model.toast {
                capsule {
                    HStack(spacing: 12) {
                        Text(verbatim: toast.text)
                        if let title = toast.actionTitle, let action = toast.action {
                            Button {
                                action()
                                model.toast = nil
                            } label: {
                                Text(title).fontWeight(.semibold).tapTarget()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
            } else if let notice = player.notice {
                capsule {
                    Text("player.skipped \(notice.skippedTitle) \(String(localized: PlaybackFailure(kind: notice.reason, videoId: nil).shortText))")
                }
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if player.notice?.id == notice.id { player.notice = nil }
                }
            }
        }
        .motion(.snappy, value: model.toast)
        .motion(.snappy, value: model.pending?.id)
        .motion(.snappy, value: player.notice)
        // Плашка держится секунды — VoiceOver её не найдёт: объявляем текст сами
        .onChange(of: model.toast) { _, toast in
            if let toast { AccessibilityNotification.Announcement(toast.text).post() }
        }
        .onChange(of: model.pending?.id) {
            if let pending = model.pending { AccessibilityNotification.Announcement(pending.text).post() }
        }
        .onChange(of: player.notice) { _, notice in
            if let notice {
                AccessibilityNotification.Announcement(String(localized: "player.skipped \(notice.skippedTitle) \(String(localized: PlaybackFailure(kind: notice.reason, videoId: nil).shortText))")).post()
            }
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .lineLimit(2)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, 10)
            .controlGlass(Capsule())
            .padding(.horizontal, Design.Space.m)
            .padding(.bottom, Design.Space.xs)
            .slideUpTransition()
            .accessibilityAddTraits(.isStaticText)
    }
}
