import SwiftUI
import MelogoldData

/// Метка загрузки в строке трека (задание 0009, Android `DownloadBadge`):
/// - скачан — закрашенный значок акцентного цвета;
/// - скачивается — кольцо с долей;
/// - в очереди или ждёт — точечный значок, на паузе — пауза, сбой — значок ошибки;
/// - без загрузки, но целиком в кэше — тот же значок контуром: он уступит место новым трекам.
/// Доля читается только у треков в состоянии «скачивается»: строки остальных не перерисовываются при каждом куске.
struct DownloadBadge: View {
    @Environment(AppModel.self) private var model
    let videoId: String

    var body: some View {
        switch model.library?.downloadStates[videoId] {
        case .completed?:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel(Text("badge.downloaded"))
        case .downloading?:
            let percent = Int(((model.library?.downloadProgress[videoId] ?? 0) * 100).rounded(.down))
            DownloadRing(fraction: model.library?.downloadProgress[videoId] ?? 0)
                .accessibilityLabel(Text("download.state.percent \(percent)"))
        case .queued?, .waiting?:
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("downloads.queued"))
        case .paused?:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("downloads.paused"))
        case .failed?:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(Text("badge.downloadFailed"))
        case nil:
            if model.cachedIds.contains(videoId) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("badge.cached"))
            }
        }
    }
}

/// Кольцо с долей: 14 pt, как у значков строки. У только что начатой загрузки видна короткая дуга.
struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1, max(fraction, 0.04)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .padding(1)
    }
}
