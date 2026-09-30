import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldInnerTube
import MelogoldServer
#if os(macOS)
import AppKit
#endif

/// Поделиться и открыть ссылку (задание 0019).
extension AppModel {
    /// «Скопировать ссылку»: буфер и плашка «Ссылка скопирована».
    func copyLink(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #elseif !os(watchOS)
        UIPasteboard.general.string = url.absoluteString
        #endif
        toast = Toast(text: String(localized: "share.linkCopied"))
    }

    // MARK: - Открыть

    /// Ссылка Melogold на плейлист (`melogold://share…`, `https://<сервер>/s/<код>`): экран «Плейлист по ссылке».
    func openSharedPlaylist(_ share: MelogoldCore.ShareLink) {
        Log.info("links", "Плейлист по ссылке")
        open(.sharedPlaylist(server: share.server, id: share.shareId), in: section == .settings ? .library : section)
    }

    /// Ссылка Spotify, Apple Music, Яндекса, Deezer, Tidal или SoundCloud: то же на YouTube Music — открывается как ссылка
    /// YouTube; не нашлось — поиск по названию и исполнителю из ссылки. Плейлисты других сервисов не переносятся.
    func openOtherService(_ link: MusicServiceLink) {
        Log.info("links", "Ссылка \\(link.service.displayName)")
        if link.kind == .playlist {
            toast = Toast(text: String(localized: "link.importLater"))
            return
        }
        toast = Toast(text: String(localized: "link.finding"))
        Task {
            switch await ExternalLinks.resolve(link) {
            case .onYouTube(let url):
                openLink(url.absoluteString)
            case .search(let query):
                section = .search
                routes[.search] = []
                searchQuery = query
                search.submit(query)
                toast = nil
            case .notFound:
                toast = Toast(text: String(localized: "link.external.notFound"))
            }
        }
    }

    // MARK: - Поделиться своим плейлистом

    /// Ссылка на свой плейлист: снимок на сервере (`POST /shares`, если сервер его делает) или список первых 50 видео на
    /// YouTube. Лист показывает ход, ссылку и «Скопировать».
    func share(_ playlist: LibraryPlaylist) {
        playlistShare = PlaylistShareRequest(playlist: playlist)
    }
}

/// Запрос «Поделиться» плейлистом: лист сам делает ссылку и показывает итог.
struct PlaylistShareRequest: Identifiable {
    let id = UUID()
    let playlist: LibraryPlaylist
}

extension AppLink {
    /// «Открыть ссылку: …» в подсказках Поиска; `nil` — не ссылка, а слова для поиска.
    var openTitle: LocalizedStringResource? {
        switch self {
        case .youTube(let target): target.openTitle
        case .melogold: "link.open.other"
        case .sharedPlaylist: "link.open.shared"
        case .otherService(let link): "link.open.service \(link.service.displayName)"
        }
    }
}
