import Foundation
import MelogoldCore

/// Экраны, которые открываются в стеке текущего раздела (docs/PROMPT.md §5.2).
/// Экраны библиотеки добавляются в своём срезе.
enum Route: Hashable {
    /// «Сервер Melogold»: адрес можно заполнить из ссылки `melogold://server` (API §7.2).
    case server(prefill: String?, serverId: String?)
    /// Вход, регистрация, аккаунт и устройства (срез 5).
    case account(AccountRoute)
    /// Альбом (`MPREb_…`).
    case album(String)
    /// Исполнитель YouTube Music или канал YouTube (`UC…`) — что именно, решает страница (REWRITE §3.7).
    case artist(String)
    /// Плейлист YouTube без префикса `VL`.
    case playlist(String)
    /// Настроение или жанр.
    case mood(MoodItem)
    /// «Все настроения».
    case moods
    /// «Все новые релизы».
    case newReleases
    /// Полный список полки («Все ›» у альбомов и синглов исполнителя).
    case browse(title: String?, browseId: String, params: String?)
}

extension Route {
    /// Куда ведёт элемент полки или выдачи. Трек никуда не ведёт — он играет; микс `RD…` — тоже (это радио).
    static func of(_ item: MusicItem) -> Route? {
        switch item {
        case .track: nil
        case .album(let album): .album(album.browseId)
        case .artist(let artist): .artist(artist.browseId)
        case .playlist(let playlist): playlist.isMix ? nil : .playlist(playlist.playlistId)
        case .mood(let mood): .mood(mood)
        }
    }

    /// «Все ›» полки: плейлист (`VL…`) или полный список.
    static func more(_ shelf: Shelf) -> Route? {
        guard let browseId = shelf.moreBrowseId else { return nil }
        if browseId.hasPrefix("VL") { return .playlist(String(browseId.dropFirst(2))) }
        if browseId.hasPrefix("UC") { return .artist(browseId) }
        return .browse(title: shelf.title, browseId: browseId, params: shelf.moreParams)
    }
}
