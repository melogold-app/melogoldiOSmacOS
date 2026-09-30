import Foundation
import MelogoldCore

/// Что такое ссылка или вставленный текст для приложения (задание 0019, как `classifyLink` Android).
public enum AppLink: Equatable, Sendable {
    /// Ссылки YouTube и YouTube Music и слова для поиска (`LinkTarget.search`); то, что не ссылка.
    case youTube(LinkTarget)
    /// `melogold://server` и `melogold://link` — их разбирает `MelogoldLink`.
    case melogold(URL)
    /// Плейлист, которым поделились ссылкой Melogold: `melogold://share` или `https://<сервер>/s/<код>`.
    case sharedPlaylist(ShareLink)
    /// Ссылка Spotify, Apple Music, Яндекс Музыки, Deezer, Tidal или SoundCloud.
    case otherService(MusicServiceLink)

    /// Своя схема — ничья другая (первой); затем YouTube; затем чужие сервисы и страница снимка, которая бывает на любом
    /// сервере, — последней. Текст без ссылки остаётся тем, что из него сделал `YouTubeLinkParser`: словами для поиска.
    public static func classify(_ text: String) -> AppLink {
        if text.range(of: "melogold://", options: .caseInsensitive) != nil {
            if let share = ShareLink.parse(text: text) { return .sharedPlaylist(share) }
            if let match = text.firstMatch(of: /(?i)melogold:\/\/\S+/), let url = URL(string: String(match.output)) { return .melogold(url) }
            return .youTube(.unsupported(.unknownPath))
        }
        let target = YouTubeLinkParser.parse(text)
        let foreign: Bool
        switch target {
        case .external, .unsupported(.unknownHost), .unsupported(.unsupportedExternal): foreign = true
        default: foreign = false
        }
        guard foreign else { return .youTube(target) }
        if let service = MusicServiceLink.parse(text) { return .otherService(service) }
        if let share = ShareLink.parse(text: text) { return .sharedPlaylist(share) }
        return .youTube(target)
    }
}
