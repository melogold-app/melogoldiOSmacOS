import SwiftUI
import MelogoldCore
import MelogoldData

/// «Скачать» или состояние загрузки в меню трека (REWRITE §4.7.5a, Android `DownloadEntry`):
/// «Скачать» → «Отменить загрузку · 42 %» → «Удалить загрузку»; после сбоя — «Скачать снова»; у трансляции — неактивное
/// «Трансляцию нельзя скачать». Меню строится в момент открытия, доля в нём не дёргается.
struct DownloadMenuItem: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let videoId = track.videoId
        switch model.library?.downloadStates[videoId] {
        case .completed?:
            Button(role: .destructive) { model.removeDownload(track) } label: {
                Label("menu.removeDownload", systemImage: "trash")
            }
        case .failed?:
            Button { model.services.downloads?.retry(videoId) } label: {
                Label("menu.downloadAgain", systemImage: "arrow.clockwise")
            }
        case let state?:
            Button { model.services.downloads?.remove(videoId) } label: {
                Label { Text(verbatim: cancelTitle(state)) } icon: { Image(systemName: "xmark.circle") }
            }
        case nil:
            if model.services.downloads != nil {
                if track.videoType == VideoType.live {
                    Button {} label: { Label("menu.download.live", systemImage: "arrow.down.circle") }
                        .disabled(true)
                } else {
                    Button { model.download(track) } label: { Label("menu.download", systemImage: "arrow.down.circle") }
                }
            }
        }
    }

    /// «Отменить загрузку · 42 %», «… · В очереди», «… · Ждём Wi‑Fi», «… · Пауза».
    private func cancelTitle(_ state: DownloadState) -> String {
        let title = String(localized: "menu.cancelDownload")
        let status: String? = switch state {
        case .downloading:
            (model.library?.downloadProgress[track.videoId]).map { Int($0 * 100) }.flatMap { $0 > 0 ? $0 : nil }
                .map { String(localized: "downloads.downloading \($0)") }
        case .waiting:
            switch model.services.downloads?.store.entry(track.videoId)?.wait {
            case .wifi?: String(localized: "downloads.wait.wifi")
            case .storage?: String(localized: "downloads.wait.storage")
            case .botCheck?: String(localized: "player.skip.botCheck")
            default: String(localized: "downloads.wait.network")
            }
        case .paused: String(localized: "downloads.paused")
        case .queued: String(localized: "downloads.queued")
        default: nil
        }
        // Неразрывные пробелы: в узком меню «· 42 %» переносится вместе, а не повисает на второй строке
        return status.map { "\(title)\u{00A0}·\u{00A0}\($0)" } ?? title
    }
}
