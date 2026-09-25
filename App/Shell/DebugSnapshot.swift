#if DEBUG && os(macOS)
import AppKit

/// Только отладочная сборка Mac: снимок главного окна в PNG самим приложением — для скриншотов срезов, когда
/// экран Mac заблокирован и системный снимок экрана недоступен.
///
///     Melogold.app/Contents/MacOS/Melogold -MelogoldSnapshotPath /tmp/shot.png [-MelogoldSnapshotDelay 3] \
///         [-MelogoldSnapshotQuit YES] [-shell.lastTab settings]
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "MelogoldSnapshotPath") else { return }
        let delay = defaults.double(forKey: "MelogoldSnapshotDelay")
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 2)) {
            capture(to: URL(fileURLWithPath: path))
            if defaults.bool(forKey: "MelogoldSnapshotQuit") { NSApp.terminate(nil) }
        }
    }

    /// Дерево слоёв окна рисуется в картинку: так видны и SwiftUI, и боковая панель на стекле (размытие фона
    /// в снимке не передаётся). `cacheDisplay` боковую панель не рисует.
    @MainActor
    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
