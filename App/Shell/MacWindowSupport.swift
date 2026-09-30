#if os(macOS)
import AppKit
import SwiftUI

/// Следит, стоит ли курсор окна в поле ввода: тогда пробел вводит пробел, а не ставит паузу, а ⌘A выделяет текст поля
/// (docs/PROMPT.md §5.4). Поле Поиска само ставит `textInputActive`, но остальные поля (фильтры списков, название
/// плейлиста) — нет, и флаг Поиска залипал после ухода из раздела, поэтому значение берётся из AppKit: первый
/// ответчик окна — редактор поля. Проверка — на каждое обновление окна, стоит копейки.
struct TextInputWatcher: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> WatcherView { WatcherView(model: model) }

    func updateNSView(_ view: WatcherView, context: Context) { view.model = model }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) { view.stop() }

    final class WatcherView: NSView {
        var model: AppModel
        private var observer: (any NSObjectProtocol)?

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func refresh() {
            let editing = (window?.firstResponder as? NSTextView)?.isEditable == true
            if model.textInputActive != editing { model.textInputActive = editing }
        }
    }
}
#endif
