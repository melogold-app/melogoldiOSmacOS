#if DEBUG && os(macOS)
import AppKit
import SwiftUI

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
            case "fullscreen":
                window(nil)?.toggleFullScreen(nil)
            case "quit":
                NSApp.terminate(nil)
            default:
                log("неизвестная команда: \(line)")
            }
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
                + "поиск=\"\(model.searchQuery)\" ввод=\(model.textInputActive)")
        }
    }
}
#endif
