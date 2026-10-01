#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Меню Mac (docs/PROMPT.md §5.4, HIG «The menu bar»): порядок и названия как в Music.app.
///
/// - **Melogold:** «О программе», «Проверить обновления…», «Настройки…» (⌘,).
/// - **Файл:** «Новый плейлист…» (⌘N), импорт и «Сохранить копию библиотеки…».
/// - **Правка:** системные пункты (⌘A «Выбрать все» у списков), «Поиск» (⌘F) — Поиск с курсором в поле.
/// - **Вид:** разделы ⌘1…⌘5, части Библиотеки ⌥⌘1…⌥⌘6, «Назад» (⌘[), боковая панель (⌃⌘S), фильтр списка (⌥⌘F),
///   «Сейчас играет» (⌥⌘N), текст (⌥⌘L) и очередь (⌥⌘U).
/// - **Трек:** «Сведения о треке…» (⌘I), «К текущему треку» (⌘L), ♡ (⇧⌘L), плейлист (⇧⌘P), альбом (⌥⌘A), исполнитель (⇧⌘A).
/// - **Управление:** воспроизведение (пробел), ⌘→ и ⌘←, ±10 секунд (⌥⌘→ и ⌥⌘←), громкость (⌘↑, ⌘↓, без звука ⌥⌘↓), перемешать
///   (⌥⌘S), повтор (⌥⌘R), «Перемешать Избранное» (⇧⌘F), устройство (⇧⌘D), таймер сна.
///
/// У каждой кнопки окна есть пункт меню, а у пункта — сочетание: мышь для действия не нужна.
/// - **Окно:** «Мини-плеер» (⌥⌘M).
/// - **Справка:** страница проекта, «Сообщить о проблеме…», «Что нового», «Лицензии».
///
/// Пункты — те же действия, что у кнопок окна (`AppModel+Shell`); название пункта говорит, что он сделает сейчас
/// («Показать текст» и «Скрыть текст»).
struct MelogoldCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private static let keys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6"]

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("menu.about") { MacAbout.show() }
            CheckForUpdatesButton()
        }

        CommandGroup(replacing: .appSettings) {
            Button("menu.settings") { showMain { model.select(.settings) } }
                .keyboardShortcut(",", modifiers: .command)
        }

        // «Файл»: ⌘N — новый плейлист; импорт копии и «Сохранить копию библиотеки…» (задание 0006)
        CommandGroup(replacing: .newItem) {
            Button("menu.newPlaylist") { showMain { model.newPlaylistPrompt = true } }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.library == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("menu.importViTune") { model.chooseBackupToImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("menu.saveBackup") { model.saveBackup() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("menu.find") { showMain { model.focusSearch() } }
                .keyboardShortcut("f", modifiers: .command)
            Button("menu.filter") { model.filterFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }

        // «Вид»: разделы, «Назад», «Сейчас играет», текст и очередь
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { showMain { model.section = section } }
                    .keyboardShortcut(Self.keys[index], modifiers: .command)
            }
            Divider()
            ForEach(Array(LibraryShortcut.allCases.enumerated()), id: \.element) { index, shortcut in
                Button(shortcut.title) { showMain { model.selectSidebar(.shortcut(shortcut)) } }
                    .keyboardShortcut(Self.keys[index], modifiers: [.command, .option])
            }
            Divider()
            Button("menu.back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("menu.toggleSidebar") { MainSplit.toggleSidebar() }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            let hasTrack = model.services.player.currentTrack != nil
            Button(model.showNowPlaying ? "menu.hideNowPlaying" : "menu.showNowPlaying") { showMain { model.toggleNowPlaying() } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!hasTrack)
            Button(model.lyricsShown ? "menu.hideLyrics" : "menu.showLyrics") { showMain { model.toggleLyrics() } }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!hasTrack)
            Button(model.queueVisible ? "menu.hideQueue" : "menu.showQueue") { showMain { model.toggleQueue() } }
                .keyboardShortcut("u", modifiers: [.command, .option])
        }

        // «Трек»: действия с играющим треком
        CommandMenu("menu.track") {
            let track = model.services.player.currentTrack
            Button("menu.trackInfo") { showMain { model.showCurrentTrackDetails() } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(track == nil)
            Button("menu.goToCurrentTrack") { showMain { model.goToCurrentTrack() } }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(track == nil)
            Divider()
            if let track {
                let liked = model.isLiked(track)
                Button(liked ? "menu.unlike" : "menu.like") { model.toggleLike(track) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.library == nil)
                Button("menu.addToPlaylist") { showMain { model.playlistPicker = PlaylistPickerRequest(tracks: [track]) } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.library == nil)
                Divider()
                Button("menu.goToAlbum") { showMain { model.showNowPlaying = false; model.openAlbum(of: track) } }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(track.albumId == nil)
                Button(track.isVideo && track.videoType != VideoType.video ? "menu.goToChannel" : "menu.goToArtist") {
                    showMain { model.showNowPlaying = false; model.openArtist(of: track) }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(track.primaryArtistId == nil)
            } else {
                Button("menu.like") {}.disabled(true)
                Button("menu.addToPlaylist") {}.disabled(true)
                Divider()
                Button("menu.goToAlbum") {}.disabled(true)
                Button("menu.goToArtist") {}.disabled(true)
            }
        }

        // «Управление»: воспроизведение и пауза (пробел, если курсор не в поле ввода), следующий и предыдущий,
        // перемотка на 10 секунд, громкость, режимы, таймер сна.
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
            Button("menu.skipForward") { model.seek(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(player.currentTrack == nil)
            Button("menu.skipBack") { model.seek(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(player.currentTrack == nil)
            Divider()
            Button("menu.volumeUp") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("menu.volumeDown") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button(player.volume == 0 ? "menu.unmute" : "menu.mute") { model.toggleMute() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Toggle("player.shuffle", isOn: Binding(get: { player.shuffled }, set: { player.setShuffled($0) }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("menu.repeatCycle") { model.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Picker(selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text("player.repeat.off").tag(RepeatMode.off)
                Text("player.repeat.all").tag(RepeatMode.all)
                Text("player.repeat.one").tag(RepeatMode.one)
            } label: {
                Text("player.repeat")
            }
            SleepTimerMenu().environment(model)
            Divider()
            Button("shortcut.shuffleFavorites") { model.perform(.shuffleFavorites) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.library == nil)
            Button("remote.device.menu") { model.remoteSheet = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        // «Окно»: главное окно (⌘0) и мини-плеер (⌥⌘M) — вместо пунктов, которые система добавляет сама без сочетаний
        CommandGroup(replacing: .singleWindowList) {
            Button { openWindow(id: "main") } label: { Text(verbatim: "Melogold") }
                .keyboardShortcut("0", modifiers: .command)
            Button("window.miniPlayer") { MiniPlayerPanel.shared.toggle(model: model) }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }

        // «Справка»: у приложения нет справочной книги — вместо неё страница проекта и сообщение о проблеме
        CommandGroup(replacing: .help) {
            Link("menu.help.github", destination: MacAbout.repository)
            Link("menu.help.releases", destination: MacAbout.repository.appendingPathComponent("releases"))
            Link("menu.help.report", destination: MacAbout.repository.appendingPathComponent("issues/new"))
            Divider()
            Button("settings.licenses") { showMain { model.open(.licenses, in: .settings) } }
        }
    }

    /// Главное окно могло быть закрыто (музыка при этом играет): действие меню открывает его и выполняется.
    private func showMain(_ action: () -> Void) {
        openWindow(id: "main")
        action()
    }
}

/// Боковая панель главного окна. Системное `toggleSidebar:` по цепочке ответчиков сюда не доходит (первым отвечает
/// список панели, а контроллер разделённого вида SwiftUI в цепочку не входит), поэтому контроллер берётся у `NSSplitView`
/// окна — его делегат.
@MainActor
enum MainSplit {
    static func controller() -> NSSplitViewController? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
              let root = window.contentView else { return nil }
        func find(_ view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController { return controller }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(root)
    }

    static func toggleSidebar() {
        controller()?.toggleSidebar(nil)
    }
}

/// «О программе Melogold»: стандартная панель системы с описанием, ссылкой на исходный код и лицензией.
@MainActor
enum MacAbout {
    static let repository = URL(string: "https://github.com/melogold-app/melogoldiOSmacOS")!

    static func show() {
        let credits = NSMutableAttributedString(
            string: String(localized: "menu.about.credits") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: String(localized: "menu.about.source"),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: repository]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): String(localized: "menu.about.copyright"),
        ])
    }
}
#endif
