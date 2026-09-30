#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Меню Mac (docs/PROMPT.md §5.4, HIG «The menu bar»): порядок и названия как в Music.app.
///
/// - **Melogold:** «О программе», «Проверить обновления…», «Настройки…» (⌘,).
/// - **Файл:** «Новый плейлист…» (⌘N), импорт и «Сохранить копию библиотеки…».
/// - **Правка:** системные пункты (⌘A «Выбрать все» у списков), «Поиск» (⌘F) — Поиск с курсором в поле.
/// - **Вид:** разделы ⌘1…⌘5, «Назад» (⌘[), «Сейчас играет» (⌥⌘N), текст (⌥⌘L) и очередь (⌥⌘U).
/// - **Трек:** «Сведения о треке…» (⌘I), «К текущему треку» (⌘L), ♡, плейлист, альбом и исполнитель.
/// - **Управление:** воспроизведение (пробел), ⌘→ и ⌘←, ±10 секунд (⌥⌘→ и ⌥⌘←), громкость, режимы, таймер сна.
/// - **Окно:** «Мини-плеер» (⌥⌘M).
/// - **Справка:** страница проекта, «Сообщить о проблеме…», «Что нового», «Лицензии».
///
/// Пункты — те же действия, что у кнопок окна (`AppModel+Shell`); название пункта говорит, что он сделает сейчас
/// («Показать текст» и «Скрыть текст»).
struct MelogoldCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private static let keys: [KeyEquivalent] = ["1", "2", "3", "4", "5"]

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
            Button("menu.saveBackup") { model.saveBackup() }
        }

        CommandGroup(after: .textEditing) {
            Button("menu.find") { showMain { model.focusSearch() } }
                .keyboardShortcut("f", modifiers: .command)
        }

        // «Вид»: разделы, «Назад», «Сейчас играет», текст и очередь
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { showMain { model.section = section } }
                    .keyboardShortcut(Self.keys[index], modifiers: .command)
            }
            Divider()
            Button("menu.back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
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
                    .disabled(model.library == nil)
                Button("menu.addToPlaylist") { showMain { model.playlistPicker = PlaylistPickerRequest(tracks: [track]) } }
                    .disabled(model.library == nil)
                Divider()
                Button("menu.goToAlbum") { showMain { model.showNowPlaying = false; model.openAlbum(of: track) } }
                    .disabled(track.albumId == nil)
                Button(track.isVideo && track.videoType != VideoType.video ? "menu.goToChannel" : "menu.goToArtist") {
                    showMain { model.showNowPlaying = false; model.openArtist(of: track) }
                }
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
