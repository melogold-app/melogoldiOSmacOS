import SwiftUI
import WatchKit
import MelogoldCore
import MelogoldPlayback

/// «Сейчас играет» на часах (docs/PROMPT.md §5.6): системный `NowPlayingView` — название, обложка, управление,
/// громкость колесиком Digital Crown и выбор наушников — и нижняя панель: ♡, «Текст» и «Очередь».
/// Длинное аудио watchOS выводит только в Bluetooth: без наушников — понятная причина и «Повторить».
struct WatchNowPlayingView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let player = model.services.player
        if player.phase == .failed, let failure = player.failure {
            VStack(spacing: 8) {
                Image(systemName: failure.kind == .noAudioRoute ? "headphones" : "exclamationmark.triangle")
                    .font(.title2)
                Text(failure.watchText)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("common.retry") { player.retryCurrent() }
            }
            .padding()
        } else {
            NowPlayingView()
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if let track = player.currentTrack, let library = model.services.library {
                            let liked = library.isLiked(track.videoId)
                            Button { library.library.setLiked(track, !liked) } label: {
                                Image(systemName: liked ? "heart.fill" : "heart")
                            }
                            .accessibilityLabel(Text(liked ? "menu.unlike" : "menu.like"))
                        }
                        Spacer()
                        NavigationLink(value: WatchRoute.lyrics) {
                            Image(systemName: "quote.bubble")
                        }
                        .accessibilityLabel(Text("player.lyrics"))
                        Spacer()
                        NavigationLink(value: WatchRoute.queue) {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel(Text("player.queue"))
                    }
                }
        }
    }
}

extension PlaybackFailure {
    var watchText: LocalizedStringResource {
        switch kind {
        case .noAudioRoute: "player.error.noRoute"
        case .network: "player.error.network"
        case .botCheck: "player.error.botCheck"
        case .geo: "player.error.geo"
        case .unavailable: "player.error.unavailable"
        case .age: "player.error.age"
        case .timeout: "player.error.timeout"
        case .extractor: "player.error.extractor"
        case .manySkips: "player.error.manySkips"
        }
    }
}
