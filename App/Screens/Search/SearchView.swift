import SwiftUI
import MelogoldCore

/// «Поиск» (REWRITE §3.1): поле, недавние запросы, выдача — срез 2.
/// На iPhone поле встаёт в панель вкладок (вкладка поиска iOS 26), на iPad с боковой панелью и на Mac — вверху
/// раздела; ⌘F и повторное нажатие на «Поиск» ставят в него курсор.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        SectionPlaceholder(section: .search)
            .searchable(text: $model.searchQuery, prompt: Text("search.prompt"))
            .searchFocused($focused)
            .onChange(of: model.searchFocusRequest) { focused = true }
            .onAppear { if model.searchFocusRequest > 0 { focused = true } }
    }
}
