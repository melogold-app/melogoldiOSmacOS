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
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Binding var text: String
    let prompt: Text

    /// Курсор в поле фильтра окна. Поле — элемент панели инструментов (AppKit), идентификатор SwiftUI до `NSTextField` не
    /// доходит, поэтому оно ищется в виде панели: единственное редактируемое поле, кроме заголовка окна.
    @MainActor
    private static func focusInToolbar() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
              let root = window.contentView?.superview else { return }
        func toolbar(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "NSToolbarView" { return view }
            for sub in view.subviews { if let found = toolbar(sub) { return found } }
            return nil
        }
        func field(_ view: NSView) -> NSTextField? {
            if let text = view as? NSTextField, text.isEditable, !String(describing: type(of: text)).contains("Title") { return text }
            for sub in view.subviews { if let found = field(sub) { return found } }
            return nil
        }
        if let bar = toolbar(root), let text = field(bar) { window.makeFirstResponder(text) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: model.filterFocusRequest) {
                    focused = true
                    // Поле — элемент панели окна (AppKit): `FocusState` до него не всегда доходит, курсор ставим и напрямую
                    DispatchQueue.main.async { Self.focusInToolbar() }
                }
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
