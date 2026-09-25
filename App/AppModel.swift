import SwiftUI
import MelogoldCore
import MelogoldData

/// Состояние окна: раздел, стеки разделов, сообщения. Настройки — в `AppSettings`.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let paths: AppPaths?

    /// Текущий раздел. Запоминается в `shell.lastTab`.
    var section: AppSection {
        didSet {
            if oldValue != section { settings.lastTab = section }
        }
    }

    /// Стек каждого раздела: при переключении разделов стеки сохраняются.
    var routes: [AppSection: [Route]] = [:]

    /// Растёт при повторном нажатии на активный раздел в корне — экран прокручивается наверх.
    private(set) var scrollToTopRequests: [AppSection: Int] = [:]

    /// Растёт, когда нужно поставить курсор в поле Поиска (⌘F, повторное нажатие на «Поиск»).
    private(set) var searchFocusRequest = 0

    /// Текст в поле Поиска. На iPhone поле живёт в панели вкладок (`Tab(role: .search)`), на iPad с боковой
    /// панелью и на Mac — в разделе «Поиск»; запрос общий.
    var searchQuery = ""

    /// Сообщение поверх окна (разбор ссылки и т. п.).
    var notice: Notice?

    struct Notice: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        let message: LocalizedStringResource?
    }

    init(settings: AppSettings, paths: AppPaths?) {
        self.settings = settings
        self.paths = paths
        self.section = settings.lastTab
    }

    func path(for section: AppSection) -> Binding<[Route]> {
        Binding(
            get: { self.routes[section] ?? [] },
            set: { self.routes[section] = $0 }
        )
    }

    /// Нажатие на раздел. Повторное нажатие на активный: во вложенном экране — к корню, в корне — наверх;
    /// в корне Поиска — ещё и курсор в поле (REWRITE §2.3).
    func select(_ section: AppSection) {
        guard section == self.section else {
            self.section = section
            return
        }
        if let stack = routes[section], !stack.isEmpty {
            routes[section] = []
        } else {
            scrollToTopRequests[section, default: 0] += 1
            if section == .search { searchFocusRequest += 1 }
        }
    }

    func scrollToTopRequest(for section: AppSection) -> Int {
        scrollToTopRequests[section, default: 0]
    }

    /// ⌘F: раздел «Поиск» и курсор в поле.
    func focusSearch() {
        section = .search
        routes[.search] = []
        searchFocusRequest += 1
    }

    /// Шаг «Назад» в стеке текущего раздела (Esc и ⌘[ на Mac). `false` — стек уже пуст.
    @discardableResult
    func goBack() -> Bool {
        guard var stack = routes[section], !stack.isEmpty else { return false }
        stack.removeLast()
        routes[section] = stack
        return true
    }

    func open(_ route: Route, in section: AppSection) {
        self.section = section
        routes[section, default: []].append(route)
    }

    /// Ссылка, которую отдала система (`onOpenURL`): `melogold://` (API §7.2). Ссылки YouTube система приложению
    /// не отдаёт — они приходят вставкой в Поиске (срез 3).
    func handle(url: URL) {
        Log.info("links", "Открыта ссылка \(url.scheme ?? "?")://\(url.host() ?? "")")
        switch MelogoldLink.parse(url) {
        case .success(.server(let address, _, let serverId)):
            section = .settings
            routes[.settings] = [.server(prefill: address, serverId: serverId)]
        case .success(.link(.request, _, _, _)):
            notice = Notice(title: "link.request.title", message: "link.request.message")
        case .success(.link(.invite, _, _, _)):
            notice = Notice(title: "link.invite.title", message: "link.invite.message")
        case .failure(.badServer(let error)):
            notice = Notice(title: "link.invalid", message: ServerAddressText.message(for: error))
        case .failure:
            notice = Notice(title: "link.invalid", message: nil)
        }
    }
}

/// Тексты отказов `ServerAddressPolicy` (GLOSSARY §4.5 «Сервер»).
enum ServerAddressText {
    static func message(for error: ServerAddressError) -> LocalizedStringResource {
        switch error {
        case .empty: "server.error.empty"
        case .malformed: "server.error.malformed"
        case .unsupportedScheme: "server.error.scheme"
        case .credentialsOrParams: "server.error.credentials"
        case .httpsRequired: "server.error.https"
        }
    }
}
