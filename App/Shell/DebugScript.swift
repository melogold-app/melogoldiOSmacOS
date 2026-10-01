#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldServer

/// Только отладочная сборка Mac: сценарий проверки окна без доступа к вводу системы (у терминала нет права «Универсальный
/// доступ»). События — настоящие `NSEvent`, отправленные в `NSApp.sendEvent`, то есть тем же путём, что и нажатия
/// пользователя: меню, сочетания клавиш, щелчки по строкам и кнопкам. Окно остаётся в фоне, фокус не перехватывается.
///
///     -MelogoldScript <файл>          сценарий: одна команда в строке, результат — в <файл>.out
///
/// Команды (координаты — точки от левого верхнего угла окна):
///
///     wait <с>                        пауза
///     key <сочетание>                 `cmd+n`, `space`, `opt+cmd+right`, `escape`, `cmd+a`, `return`, `tab`
///     click <x> <y> [main|mini]       щелчок; `rclick` — правый; `dblclick` — двойной
///     move <x> <y> [main|mini]        курсор над точкой (наведение)
///     cgclick <x> <y> [main|mini]     то же настоящими событиями мыши (`cgmove`, `cgdrag x y x2 y2`)
///     warp <x> <y> [main|mini]        настоящий указатель над точкой окна — наведение (только если человек отошёл)
///     menu                            дерево главного меню (названия, сочетания, доступность) — в файл результата
///     menuitem <Меню/Пункт>           выбрать пункт меню по названиям
///     state                           раздел, стек, «Сейчас играет», очередь, текст — в файл результата
///     mark <имя> [main|mini]          сигнал для снимка: оболочка видит `MARK` в файле результата и снимает окно
///     activate                        сделать окно активным и ключевым — только если человек не вводил ничего 4 минуты
///     type <текст>                    набрать буквы и пробелы
///     about                           «О программе»
///     frame                           рамки окон
///     fullscreen                      переключить полноэкранный режим главного окна
///     quit                            завершить
enum DebugScript {
    @MainActor
    static func runIfRequested(model: AppModel) {
        guard let path = UserDefaults.standard.string(forKey: "MelogoldScript"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let out = URL(fileURLWithPath: path + ".out")
        try? "".write(to: out, atomically: true, encoding: .utf8)
        Task { @MainActor in
            var runner = Runner(model: model, out: out)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                // сторожевой таймер: команда, застрявшая в цикле отслеживания мыши, не даст ни строки результата
                let finished = Finished()
                let watchdogOut = out
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                    guard !finished.value, let handle = try? FileHandle(forWritingTo: watchdogOut) else { return }
                    handle.seekToEndOfFile()
                    handle.write(Data("ЗАВИСЛА команда: \(line)\n".utf8))
                    try? handle.close()
                }
                await runner.run(line)
                finished.value = true
            }
            runner.log("конец сценария")
        }
    }

    private final class Finished: @unchecked Sendable {
        nonisolated(unsafe) var value = false
    }

    @MainActor
    struct Runner {
        let model: AppModel
        let out: URL

        func log(_ text: String) {
            let data = Data((text + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: out) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }

        private func window(_ name: String?) -> NSWindow? {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 100 }
            if name == "about" {
                return NSApp.windows.first { $0.isVisible && $0.title.isEmpty && $0.frame.width < 500 && $0.frame.height > 100 && $0.level == .normal }
            }
            if name == "mini" {
                return windows.first { $0.title == "Мини-плеер" || $0.title == "Mini player" || $0.frame.width < 500 }
            }
            return windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        mutating func run(_ line: String) async {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let command = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            let words = arg.split(separator: " ").map(String.init)
            switch command {
            case "wait":
                try? await Task.sleep(for: .milliseconds(Int((Double(arg) ?? 1) * 1000)))
            case "key":
                key(arg)
            case "click", "rclick", "dblclick", "move":
                guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]),
                      let window = window(words.count > 2 ? words[2] : nil) else { log("\(line): нет окна или координат"); return }
                await mouse(command, x: x, y: y, in: window)
            case "warp":
                // настоящий указатель над точкой окна (наведение): только когда человек отошёл — двигает его курсор
                guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]), let window = window(words.count > 2 ? words[2] : nil) else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                guard idle >= 240 else { log("warp: пользователь занят, пропущено"); return }
                let top = (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY
                let point = CGPoint(x: window.frame.minX + x, y: top + y)
                CGWarpMouseCursorPosition(point)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.postToPid(getpid())
                try? await Task.sleep(for: .milliseconds(400))
                log("warp \(x),\(y)")
            case "cgclick", "cgmove", "cgdrag":
                // настоящие события мыши, отправленные этому процессу (`CGEvent.postToPid`): SwiftUI принимает их, в отличие
                // от собранных руками `NSEvent`. Координаты те же — от левого верхнего угла окна. `cgdrag x y x2 y2`.
                guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]),
                      let window = window(words.count > 4 ? words[4] : (command == "cgdrag" ? nil : (words.count > 2 ? words[2] : nil))) else {
                    log("\(line): нет окна или координат"); return
                }
                await cgMouse(command, x: x, y: y, to: words.count > 3 ? (Double(words[2]), Double(words[3])) : nil, in: window)
            case "hit":
                guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]), let window = window(words.count > 2 ? words[2] : nil),
                      let content = window.contentView else { return }
                let view = content.hitTest(NSPoint(x: x, y: content.frame.height - y))
                var chain: [String] = []
                var current: NSView? = view
                while let v = current, chain.count < 6 { chain.append(String(describing: type(of: v))); current = v.superview }
                log("hit \(x),\(y): \(chain.joined(separator: " < ")) активно=\(NSApp.isActive) ключ=\(window.isKeyWindow) принимаетПервыйЩелчок=\(view?.acceptsFirstMouse(for: nil) ?? false)")
            case "menu":
                log("МЕНЮ:")
                dump(NSApp.mainMenu, indent: 0)
            case "menuitem":
                menuItem(arg)
            case "wheel":
                // wheel <dy> [x y]: колесо мыши (точки, минус — вниз) над точкой окна (по умолчанию — середина колонки детали)
                let numbers = arg.split(separator: " ").compactMap { Double($0) }
                wheel(dy: numbers.first ?? -600, at: numbers.count >= 3 ? CGPoint(x: numbers[1], y: numbers[2]) : nil)
            case "scrolls":
                // Все прокручиваемые представления окна (AppKit): рамка, вставки, высота документа, смещение
                guard let root = window(nil)?.contentView else { log("scrolls: нет окна"); return }
                var lines: [String] = []
                func walk(_ view: NSView, _ depth: Int) {
                    if let scroll = view as? NSScrollView {
                        let f = scroll.convert(scroll.bounds, to: nil)
                        let i = scroll.contentInsets
                        lines.append("NSScrollView \(type(of: scroll)) x=\(Int(f.minX)) w=\(Int(f.width)) h=\(Int(f.height)) вставки(в=\(Int(i.top)) н=\(Int(i.bottom))) документ=\(Int(scroll.documentView?.frame.height ?? 0)) смещение=\(Int(scroll.contentView.bounds.origin.y)) авто=\(scroll.automaticallyAdjustsContentInsets)")
                    }
                    view.subviews.forEach { walk($0, depth + 1) }
                }
                walk(root, 0)
                log("scrolls: \(lines.count)\n" + lines.joined(separator: "\n"))
            case "push":
                // push favorites | allTracks: открыть экран Библиотеки поверх корня раздела — как нажатие в хабе
                // push <section> <экран>: `push library history`, `push trends album`; без раздела — Библиотека
                let parts = arg.split(separator: " ").map(String.init)
                let target = parts.count > 1 ? (AppSection(rawValue: parts[0]) ?? .library) : .library
                let name = parts.last ?? ""
                let library = model.library?.library
                let artistId = library?.favorites().compactMap(\.primaryArtistId).first
                let playlistId = library?.playlists().first?.id
                var routes: [String: Route] = ["favorites": .favorites, "allTracks": .allTracks, "downloads": .downloads, "history": .history,
                                               "album": .album("MPREb_OLmD8O5IYNS"), "moods": .moods, "newReleases": .newReleases,
                                               "playlists": .playlists, "savedAlbums": .savedAlbums, "savedArtists": .savedArtists,
                                               "hidden": .hiddenTracks, "stats": .stats, "streamInfo": .streamInfo, "diagnostics": .diagnostics,
                                               "licenses": .licenses, "server": .server(prefill: nil, serverId: nil),
                                               "signIn": .account(.signIn(login: nil)), "register": .account(.register)]
                if let artistId { routes["artist"] = .artist(artistId) }
                if let playlistId { routes["localPlaylist"] = .localPlaylist(playlistId) }
                if let route = routes[name] { model.open(route, in: target); log("push \(target.rawValue) \(name)") } else { log("push: нет экрана «\(name)»") }
            case "theme":
                // theme light | dark | system — тема приложения, как в Настройках
                if let mode = ThemeMode(rawValue: arg) { model.settings.theme = mode; log("тема \(arg)") }
            case "nowplaying":
                // nowplaying [lyrics|queue|off]: «Сейчас играет», с текстом или очередью
                switch arg {
                case "off": model.showNowPlaying = false
                case "lyrics": model.showNowPlaying = true; model.lyricsVisible = true
                case "queue": model.showNowPlaying = true; model.lyricsVisible = false; model.queueVisible = true
                default: model.showNowPlaying = true; model.lyricsVisible = false
                }
                log("сейчас играет \(arg)")
            case "queuepanel":
                model.queueVisible.toggle()
                log("очередь \(model.queueVisible)")
            case "details":
                if let track = model.services.player.currentTrack { model.trackDetails = track; log("сведения о треке") }
            case "dismiss":
                model.trackDetails = nil
                model.remoteSheet = false
                model.playlistPicker = nil
                log("листы закрыты")
            case "toolbar":
                // Элементы панели окна (AppKit): идентификаторы, названия, видимость — и заголовок окна
                let toolbar = window(nil)?.toolbar
                let items = (toolbar?.items ?? []).map { "\($0.itemIdentifier.rawValue)[\($0.label)]" }.joined(separator: ", ")
                log("toolbar: заголовок=«\(window(nil)?.title ?? "")» подзаголовок=«\(window(nil)?.subtitle ?? "")» видима=\(toolbar?.isVisible ?? false) элементы=\(items)")
            case "updateready":
                AppUpdater.shared.debugShowReady(arg.isEmpty ? "0.2.5" : arg)
                log("обновление готово \(arg)")
            case "scrollbench":
                // scrollbench <шагов> <точек за шаг>: листает самый большой список колонки детали и меряет каждый шаг
                // (прокрутка + раскладка + отрисовка окна), между шагами — кадр 16 мс
                let n = arg.split(separator: " ").compactMap { Double($0) }
                await scrollBench(steps: Int(n.first ?? 120), dy: n.count > 1 ? n[1] : 40)
            case "scroll":
                // scroll top | bottom | <точки вниз>: прокрутка самого широкого списка в колонке детали — края и то, что под панелью
                scrollDetail(arg)
            case "sidebar":
                // Строка боковой панели тем же путём, что щелчок (`selectSidebar`), но без событий мыши и без фокуса:
                // trends new library search settings | favorites downloads history allTracks albums artists | playlist
                selectSidebar(arg)
            case "closewindow":
                // красная кнопка: окно закрывается, музыка и модель остаются
                window(nil)?.close()
                log("окно закрыто")
            case "reopen":
                // как щелчок по значку в Dock после закрытия окна
                model.openMainWindow?()
                log("окно открыто заново")
            case "minimize":
                // minimize: свернуть окно в Dock, restore: развернуть (как жёлтая кнопка и щелчок по значку)
                window(nil)?.miniaturize(nil)
                log("окно свёрнуто")
            case "restore":
                (NSApp.windows.first { $0.isMiniaturized })?.deminiaturize(nil)
                log("окно развёрнуто")
            case "splits":
                // Все NSSplitView окна: делегат, число вкладок, рамки — как устроена боковая панель
                guard let root = window(nil)?.contentView else { log("splits: нет окна"); break }
                func walk(_ view: NSView, _ depth: Int) {
                    if let split = view as? NSSplitView {
                        let frames = split.subviews.map { "\(Int($0.frame.minX)),\(Int($0.frame.width))" }.joined(separator: " | ")
                        log("split \(String(repeating: " ", count: depth))\(type(of: split)) делегат=\(split.delegate.map { String(describing: type(of: $0)) } ?? "нет") вертикальный=\(split.isVertical) \(frames)")
                    }
                    for sub in view.subviews { walk(sub, depth + 1) }
                }
                walk(root, 0)
            case "dock":
                // dock: пункты меню в Dock; dock <часть названия>: нажать пункт (тот же путь, что щелчок по нему)
                guard let delegate = NSApp.delegate as? NSApplicationDelegate, let menu = delegate.applicationDockMenu?(NSApp) else { log("dock: нет меню"); break }
                if arg.isEmpty {
                    log("dock: " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
                } else if let item = menu.items.first(where: { $0.title.localizedCaseInsensitiveContains(arg) }) {
                    log("dock: нажат «\(item.title)»")
                    _ = NSApp.sendAction(item.action!, to: item.target, from: item)
                } else {
                    log("dock: нет пункта «\(arg)»")
                }
            case "remote":
                // remote connect | disconnect: пульт управляет выдуманным «Test Mac» (сервера нет — команды не уйдут, но видно,
                // что нажатие по треку не играет здесь)
                guard let remote = model.remoteBridge?.remote else { log("remote: нет пульта"); break }
                if arg == "connect" {
                    let json = #"{"deviceId":"00000000-0000-4000-8000-000000000001","name":"Test Mac","platform":"macos","online":true,"controllable":true,"playing":null,"volume":null}"#
                    if let device = try? JSONDecoder().decode(RemoteDevice.self, from: Data(json.utf8)) { remote.connect(device); log("remote: подключено к «\(device.name)»") }
                } else {
                    remote.disconnect()
                    log("remote: отключено")
                }
            case "state":
                state()
            case "mark":
                // Снимок делает оболочка снаружи (у самого приложения нет права записи экрана): строка `MARK <имя>` в файле
                // результата — сигнал, затем пауза, чтобы снимок успел
                log("MARK \(arg)")
                try? await Task.sleep(for: .milliseconds(2500))
            case "activate":
                // Щелчки по окну приложения в фоне система съедает (первый щелчок только активирует окно), а активация забирает
                // фокус у человека — поэтому только когда он не трогал клавиатуру и мышь 4 минуты
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                guard idle >= 240 else { log("activate: пользователь занят (\(Int(idle)) с без ввода), пропущено"); return }
                // `NSApp.activate()` у приложения, запущенного в фоне, система не исполняет (согласованная активация) —
                // активирует `open` без `-g`, как щелчок по значку
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [Bundle.main.bundlePath]
                try? open.run()
                try? await Task.sleep(for: .milliseconds(1200))
                window(nil)?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(400))
                log("activate: активно=\(NSApp.isActive) ключ=\(window(nil)?.isKeyWindow ?? false)")
            case "makekey":
                // окно ключевым, не активируя приложение (фокус человека не трогаем) — выйдет ли, зависит от системы
                let target = window(nil)
                target?.makeKey()
                try? await Task.sleep(for: .milliseconds(400))
                log("makekey: активно=\(NSApp.isActive) ключ=\(target?.isKeyWindow ?? false) главное=\(target?.isMainWindow ?? false)")
            case "type":
                for character in arg {
                    key(character == " " ? "space" : String(character).lowercased())
                }
            case "about":
                NSApp.orderFrontStandardAboutPanel(nil)
            case "frame":
                for w in NSApp.windows where w.isVisible { log("окно «\(w.title)» \(w.frame) level=\(w.level.rawValue) key=\(w.isKeyWindow) style=\(w.styleMask.rawValue)") }
            case "resize":
                // resize <ширина> <высота>: размер содержимого окна в точках
                let n = arg.split(separator: " ").compactMap { Double($0) }
                if n.count == 2, let w = window(nil) { w.setContentSize(NSSize(width: n[0], height: n[1])); log("окно \(Int(n[0]))×\(Int(n[1]))") }
            case "fullscreen":
                window(nil)?.toggleFullScreen(nil)
            case "quit":
                NSApp.terminate(nil)
            default:
                log("неизвестная команда: \(line)")
            }
        }

        /// Боковая панель: свёрнута ли (`?` — контроллера нет).
        private static func sidebarWidth(_ window: NSWindow?) -> String {
            guard let item = MainSplit.controller()?.splitViewItems.first else { return "?" }
            return item.isCollapsed ? "свёрнута" : "видна"
        }

        // MARK: - Клавиши

        private static let codes: [String: (UInt16, String)] = [
            "a": (0, "a"), "s": (1, "s"), "d": (2, "d"), "f": (3, "f"), "h": (4, "h"), "g": (5, "g"), "z": (6, "z"), "x": (7, "x"),
            "c": (8, "c"), "v": (9, "v"), "b": (11, "b"), "q": (12, "q"), "w": (13, "w"), "e": (14, "e"), "r": (15, "r"),
            "y": (16, "y"), "t": (17, "t"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "6": (22, "6"),
            "5": (23, "5"), "9": (25, "9"), "7": (26, "7"), "8": (28, "8"), "0": (29, "0"), "]": (30, "]"), "o": (31, "o"),
            "u": (32, "u"), "[": (33, "["), "i": (34, "i"), "p": (35, "p"), "l": (37, "l"), "j": (38, "j"), "k": (40, "k"),
            "n": (45, "n"), "m": (46, "m"), ",": (43, ","),
            "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\u{7F}"), "escape": (53, "\u{1B}"),
            "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
            "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            "home": (115, String(UnicodeScalar(NSHomeFunctionKey)!)),
            "end": (119, String(UnicodeScalar(NSEndFunctionKey)!)),
            "pageup": (116, String(UnicodeScalar(NSPageUpFunctionKey)!)),
            "pagedown": (121, String(UnicodeScalar(NSPageDownFunctionKey)!)),
        ]

        private func key(_ combo: String) {
            var flags: NSEvent.ModifierFlags = []
            var name = combo
            for part in combo.split(separator: "+").map(String.init) {
                switch part {
                case "cmd": flags.insert(.command)
                case "opt", "alt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                case "shift": flags.insert(.shift)
                default: name = part
                }
            }
            guard let (code, chars) = Self.codes[name] else { log("key: неизвестная клавиша \(name)"); return }
            let number = (window(nil) ?? NSApp.keyWindow)?.windowNumber ?? 0
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: number, context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                                                isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(event)
                }
            }
            log("key \(combo)")
        }

        // MARK: - Мышь

        private func mouse(_ kind: String, x: Double, y: Double, in window: NSWindow) async {
            guard let content = window.contentView else { return }
            // Точка от левого верхнего угла содержимого окна → координаты окна (начало — левый нижний угол)
            let point = NSPoint(x: x, y: content.frame.height - y)
            func event(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
            }
            switch kind {
            case "move":
                if let e = event(.mouseMoved) { NSApp.sendEvent(e) }
            case "rclick":
                if let down = event(.rightMouseDown), let up = event(.rightMouseUp) {
                    NSApp.sendEvent(down)
                    NSApp.sendEvent(up)
                }
            case "dblclick":
                for clicks in [1, 2] {
                    if let down = event(.leftMouseDown, clicks: clicks), let up = event(.leftMouseUp, clicks: clicks) {
                        NSApp.sendEvent(down)
                        try? await Task.sleep(for: .milliseconds(30))
                        NSApp.sendEvent(up)
                    }
                }
            default:
                if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                    // Строка списка и поле ввода ждут отпускания в собственном цикле внутри `sendEvent`, не возвращая управление:
                    // отпускание уже лежит в очереди событий, цикл его заберёт
                    NSApp.postEvent(up, atStart: false)
                    NSApp.sendEvent(down)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            log("\(kind) \(x),\(y)")
        }

        /// События мыши уходят из фонового потока: щелчок по строке списка или полю поиска запускает в главном потоке
        /// цикл отслеживания мыши, в котором задачи главного потока не выполняются — отпускание, поставленное из них,
        /// не пришло бы никогда.
        private func cgMouse(_ kind: String, x: Double, y: Double, to end: (Double?, Double?)?, in window: NSWindow) async {
            let screenTop = (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY
            let originX = window.frame.minX
            func point(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: originX + px, y: screenTop + py) }
            var steps: [(delay: Double, type: CGEventType, at: CGPoint)] = []
            let start = point(x, y)
            switch kind {
            case "cgmove":
                steps = [(0, .mouseMoved, start)]
            case "cgdrag":
                steps = [(0, .leftMouseDown, start)]
                if let ex = end?.0, let ey = end?.1 {
                    for step in 1...10 {
                        let t = Double(step) / 10
                        steps.append((0.02, .leftMouseDragged, point(x + (ex - x) * t, y + (ey - y) * t)))
                    }
                    steps.append((0.02, .leftMouseUp, point(ex, ey)))
                } else {
                    steps.append((0.08, .leftMouseUp, start))
                }
            default:
                steps = [(0, .mouseMoved, start), (0.05, .leftMouseDown, start), (0.08, .leftMouseUp, start)]
            }
            let total = steps.reduce(0) { $0 + $1.delay }
            let queued = steps
            DispatchQueue.global().async {
                for step in queued {
                    Thread.sleep(forTimeInterval: step.delay)
                    guard let event = CGEvent(mouseEventSource: nil, mouseType: step.type, mouseCursorPosition: step.at, mouseButton: .left) else { continue }
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                    event.postToPid(getpid())
                }
            }
            try? await Task.sleep(for: .milliseconds(Int(total * 1000) + 300))
            log("\(kind) \(x),\(y)")
        }

        // MARK: - Меню

        private func dump(_ menu: NSMenu?, indent: Int) {
            guard let menu else { return }
            menu.update()
            for item in menu.items {
                let pad = String(repeating: "  ", count: indent)
                if item.isSeparatorItem { log("\(pad)—"); continue }
                var keys = ""
                if !item.keyEquivalent.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    keys = " [" + (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
                        + (m.contains(.command) ? "⌘" : "") + Self.symbol(item.keyEquivalent) + "]"
                }
                let flags = (item.isEnabled ? "" : " (выкл)") + (item.state == .on ? " ✓" : "") + (item.isHidden ? " (скрыт)" : "")
                log("\(pad)\(item.title)\(keys)\(flags)")
                if let sub = item.submenu { dump(sub, indent: indent + 1) }
            }
        }

        private static func symbol(_ key: String) -> String {
            switch key {
            case " ": "Space"
            case String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←"
            case String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"
            case String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑"
            case String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"
            case "\r": "Return"
            case "\u{1B}": "Esc"
            case "\u{7F}": "⌫"
            default: key.uppercased()
            }
        }

        private func find(_ path: [String], in menu: NSMenu?) -> NSMenuItem? {
            guard let menu, let first = path.first else { return nil }
            menu.update()
            guard let item = menu.items.first(where: { $0.title == first }) else { return nil }
            return path.count == 1 ? item : find(Array(path.dropFirst()), in: item.submenu)
        }

        private func wheel(dy: Double, at point: CGPoint?) {
            guard let window = window(nil), let content = window.contentView else { log("wheel: нет окна"); return }
            let local = point ?? CGPoint(x: content.bounds.width * 0.62, y: content.bounds.height * 0.45)
            // точки от левого верхнего угла окна → экран (у AppKit начало снизу, у CGEvent — сверху главного экрана)
            let inWindow = NSPoint(x: local.x, y: content.bounds.height - local.y)
            let onScreen = window.convertPoint(toScreen: inWindow)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
            event.location = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)
            event.postToPid(ProcessInfo.processInfo.processIdentifier)
            log("wheel \(Int(dy)) в \(Int(local.x)),\(Int(local.y))")
        }

        private func scrollBench(steps: Int, dy: Double) async {
            guard let window = window(nil), let root = window.contentView else { log("scrollbench: нет окна"); return }
            var found: [NSScrollView] = []
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.convert(scroll.bounds, to: nil).width > 300 { found.append(scroll) }
                view.subviews.forEach(walk)
            }
            walk(root)
            guard let scroll = found.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { log("scrollbench: нет списка"); return }
            let clip = scroll.contentView
            var times: [Double] = []
            var direction = 1.0
            for _ in 0 ..< steps {
                let start = CACurrentMediaTime()
                let maxY = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height + scroll.contentInsets.bottom
                var y = clip.bounds.origin.y + dy * direction
                if y > maxY || y < -scroll.contentInsets.top { direction = -direction; y = clip.bounds.origin.y + dy * direction }
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(clip)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                times.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(16))
            }
            let sorted = times.sorted()
            let avg = times.reduce(0, +) / Double(max(1, times.count))
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            log("scrollbench \(type(of: scroll)) шагов=\(steps) среднее=\(String(format: "%.1f", avg)) мс p95=\(String(format: "%.1f", p95)) мс макс=\(String(format: "%.1f", sorted.last ?? 0)) мс, список \(Int(scroll.documentView?.frame.height ?? 0)) pt")
        }

        private func scrollDetail(_ how: String) {
            guard let root = window(nil)?.contentView else { log("scroll: нет окна"); return }
            var found: [NSScrollView] = []
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.documentView != nil {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    if frame.width > 300 { found.append(scroll) }
                }
                view.subviews.forEach(walk)
            }
            walk(root)
            guard let scroll = found.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
                  let document = scroll.documentView else { log("scroll: нет списка"); return }
            let clip = scroll.contentView
            let inset = scroll.contentInsets
            let top = -inset.top
            let bottom = max(top, document.frame.height - clip.bounds.height + inset.bottom)
            let y: CGFloat
            switch how {
            case "top": y = top
            case "bottom": y = bottom
            default: y = min(bottom, max(top, clip.bounds.origin.y + (Double(how) ?? 0)))
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            log("scroll \(how): y=\(Int(y)) из \(Int(top))…\(Int(bottom)), вставки сверху \(Int(inset.top)) снизу \(Int(inset.bottom)), список \(Int(document.frame.height))")
        }

        private func selectSidebar(_ name: String) {
            let item: SidebarItem?
            switch name {
            case "favorites": item = .shortcut(.favorites)
            case "downloads": item = .shortcut(.downloads)
            case "history": item = .shortcut(.history)
            case "allTracks": item = .shortcut(.allTracks)
            case "albums": item = .shortcut(.albums)
            case "artists": item = .shortcut(.artists)
            case "playlist":
                item = model.library?.library.playlists().first.map { .playlist($0.id) }
            default:
                item = AppSection(rawValue: name).map { .section($0) }
            }
            guard let item else { log("sidebar: нет строки «\(name)»"); return }
            model.selectSidebar(item)
            log("sidebar \(name)")
        }

        private func menuItem(_ path: String) {
            let names = path.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let item = find(names, in: NSApp.mainMenu) else { log("menuitem: нет пункта \(path)"); return }
            guard item.isEnabled, let action = item.action else { log("menuitem \(path): выключен"); return }
            let ok = NSApp.sendAction(action, to: item.target, from: item)
            log("menuitem \(path) → \(ok)")
        }

        private func state() {
            let player = model.services.player
            log("состояние: раздел=\(model.section.rawValue) стек=\(model.routes[model.section] ?? []) подсветка=\(model.sidebarSelection) "
                + "сейчасИграет=\(model.showNowPlaying) очередь=\(model.queueVisible) текст=\(model.lyricsVisible) "
                + "трек=\(player.currentTrack?.title ?? "нет") позиция=\(Int(player.position)) играет=\(player.isPlaying) "
                + "громкость=\(player.volume) сведения=\(model.trackDetails?.title ?? "нет") новыйПлейлист=\(model.newPlaylistPrompt) "
                + "поиск=\"\(model.searchQuery)\" ввод=\(model.textInputActive) повтор=\(player.repeatMode) перемешано=\(player.shuffled) "
                + "устройство=\(model.remoteSheet) ответчик=\(window(nil)?.firstResponder.map { String(describing: type(of: $0)) } ?? "нет") "
                + "боковая=\(Self.sidebarWidth(window(nil)))")
        }
    }
}
#endif
