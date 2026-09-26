#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Меню Mac (docs/PROMPT.md §5.4): разделы по ⌘1…⌘5, ⌘F — Поиск с курсором в поле, «Настройки…» (⌘,) открывает
/// раздел «Настройки», ⌘[ — шаг назад в стеке раздела. Меню «Управление» появляется вместе с плеером (срез 2).
struct MelogoldCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

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

        // «Управление»: воспроизведение и пауза (пробел, если курсор не в поле ввода), следующий и предыдущий,
        // громче и тише. Перемешивание, повтор и таймер сна — вместе с очередью (срезы 4 и 7).
        CommandMenu("menu.controls") {
            let player = model.services.player
            Button(player.isPlaying ? "player.pause" : "player.play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.textInputActive || player.currentTrack == nil)
            Button("player.next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.hasNext)
            Button("player.previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.currentTrack == nil)
            Divider()
            Button("menu.volumeUp") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("menu.volumeDown") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Toggle("player.shuffle", isOn: Binding(get: { player.shuffled }, set: { player.setShuffled($0) }))
                .keyboardShortcut("s", modifiers: [.command, .control])
            Picker(selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text("player.repeat.off").tag(RepeatMode.off)
                Text("player.repeat.all").tag(RepeatMode.all)
                Text("player.repeat.one").tag(RepeatMode.one)
            } label: {
                Text("player.repeat")
            }
            SleepTimerMenu().environment(model)
            Divider()
            Button("player.queue") { model.queueVisible.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Button("player.lyrics") {
                model.lyricsVisible = true
                model.showNowPlaying = true
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }

        CommandGroup(after: .windowList) {
            Button("window.miniPlayer") { openWindow(id: "mini") }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}
#endif
