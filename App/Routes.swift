import Foundation

/// Экраны, которые открываются в стеке текущего раздела (docs/PROMPT.md §5.2).
/// Детальные экраны каталога и библиотеки добавляются в своих срезах.
enum Route: Hashable {
    /// «Сервер Melogold»: адрес можно заполнить из ссылки `melogold://server` (API §7.2).
    case server(prefill: String?, serverId: String?)
}
