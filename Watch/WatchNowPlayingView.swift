import SwiftUI
import WatchKit
import MelogoldCore
import MelogoldPlayback

/// «Сейчас играет» на часах (docs/PROMPT.md §5.6): системный `NowPlayingView` — название, обложка, управление,
/// громкость колесиком Digital Crown и выбор наушников — и кнопка «Ещё» в панели окна.
/// Длинное аудио watchOS выводит только в Bluetooth: без наушников — понятная причина и «Повторить».
struct WatchNowPlayingView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let player = model.services.player
        if player.phase == .failed, let failure = player.failure {
            VStack(spacing: 8) {
                Image(systemName: failure.kind == .noAudioRoute ? "headphones" : "exclamationmark.triangle")
                    .font(.title2)
                Text(GeoText.short(failure) ?? String(localized: failure.watchText))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("common.retry") { player.retryCurrent() }
            }
            .padding()
        } else {
            // Системный «Сейчас играет» целиком (название, обложка, ⏮ ⏯ ⏭, громкость колесиком, наушники): у него своя нижняя
            // строка, и панель с ♡, «Текстом» и «Очередью» закрывала кнопки управления. В панели окна — одна кнопка «Ещё»:
            // ♡, текст, очередь, таймер сна и устройство — на своём экране (`WatchPlayerMoreView`)
            NowPlayingView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: WatchRoute.playerMore) {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel(Text("menu.more"))
                    }
                }
        }
    }
}

extension PlaybackFailure {
    /// Часы — коротко: у проверки на бота полный текст карточки (два предложения) слишком длинный для экрана часов.
    var watchText: LocalizedStringResource {
        switch kind {
        case .noAudioRoute: "player.error.noRoute"
        case .network: "player.error.network"
        case .botCheck: "player.skip.botCheck"
        case .geo: "player.error.geo"
        case .unavailable: "player.error.unavailable"
        case .age: "player.error.age"
        case .timeout: "player.error.timeout"
        case .extractor: "player.error.extractor"
        case .manySkips: "player.error.manySkips"
        }
    }
}

/// Таймер сна на часах: 15 · 30 · 45 · 60 мин, «До конца трека», «Выключить таймер».
struct WatchSleepTimerView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let player = model.services.player
        List {
            // Включённый таймер — сверху: сколько осталось и «Выключить таймер».
            if player.sleepTimerEnd != nil || player.sleepAtTrackEnd {
                Section {
                    Button("sleep.off", role: .destructive) {
                        player.cancelSleepTimer()
                        dismiss()
                    }
                } header: {
                    if let end = player.sleepTimerEnd {
                        Text(verbatim: SleepFormat.remaining(end))
                    } else {
                        Text("sleep.chip.endOfTrack")
                    }
                }
            }
            Section {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("sleep.minutes \(minutes)") {
                        player.setSleepTimer(minutes: minutes)
                        dismiss()
                    }
                }
                Button("sleep.endOfTrack") {
                    player.setSleepAtTrackEnd()
                    dismiss()
                }
            }
        }
        .navigationTitle(Text("sleep.title"))
    }
}
