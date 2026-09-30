import SwiftUI

extension View {
    /// Фильтр списка в панели инструментов. На Mac — свой `TextField` в панели, а не `.searchable`: системное поле поиска —
    /// элемент панели окна с одним и тем же идентификатором, и когда при переходе (строка боковой панели, другой раздел)
    /// два экрана с `.searchable` оказываются в панели одновременно, AppKit бросает исключение «такой элемент уже есть»
    /// и приложение падает (0.2.0, 30.09.2026: щелчок по «Новое» в «Трендах»). Единственный `.searchable` на Mac — в
    /// «Поиске» (`SearchView`): он один, двойнику взяться неоткуда. На iPhone и iPad — обычный `.searchable`.
    @ViewBuilder
    func filterable(text: Binding<String>, prompt: Text) -> some View {
        #if os(macOS)
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                FilterField(text: text, prompt: prompt)
            }
        }
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }
}

#if os(macOS)
/// Поле фильтра в панели инструментов Mac: лупа, текст, крестик, пока что-то набрано.
struct FilterField: View {
    @Binding var text: String
    let prompt: Text

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("library.filter.clear"))
            }
        }
        .frame(width: 210)
    }
}

/// Поле поиска справа в панели инструментов корня раздела — кнопка, а не `.searchable` (см. `filterable`): щелчок
/// открывает раздел «Поиск» с курсором в поле, как ⌘F.
struct SearchLauncher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.focusSearch()
        } label: {
            Label("search.prompt", systemImage: "magnifyingglass")
                .labelStyle(.titleAndIcon)
        }
        .help(Text("search.prompt"))
        .accessibilityIdentifier("toolbar.search")
    }
}
#endif
