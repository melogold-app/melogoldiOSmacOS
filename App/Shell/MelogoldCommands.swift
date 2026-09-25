#if os(macOS)
import SwiftUI
import MelogoldCore

/// Меню Mac (docs/PROMPT.md §5.4): разделы по ⌘1…⌘5, ⌘F — Поиск с курсором в поле, «Настройки…» (⌘,) открывает
/// раздел «Настройки», ⌘[ — шаг назад в стеке раздела. Меню «Управление» появляется вместе с плеером (срез 2).
struct MelogoldCommands: Commands {
    let model: AppModel

    private static let keys: [KeyEquivalent] = ["1", "2", "3", "4", "5"]

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("menu.settings") { model.select(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model.section = section }
                    .keyboardShortcut(Self.keys[index], modifiers: .command)
            }
            Divider()
            Button("menu.back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("menu.find") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}
#endif
