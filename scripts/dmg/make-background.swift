// Фон окна DMG (scripts/dmg/make-background.swift): рисует Config/dmg/background.tiff — 660×400 pt, обычный и @2x в одном
// TIFF (Finder берёт нужный для экрана). Запускать руками, когда меняется оформление; готовый файл лежит в репозитории,
// так что выпуск его не пересобирает:
//
//   swift scripts/dmg/make-background.swift Config/dmg
//
// Где стоят значки — в scripts/dmg/settings.py (центры значков 180,200 и 480,200 — стрелка между ними).
import AppKit

let size = NSSize(width: 660, height: 400)
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Config/dmg", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func text(_ string: String, size points: CGFloat, weight: NSFont.Weight, color: NSColor, at y: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: points, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph,
    ]
    let line = NSAttributedString(string: string, attributes: attributes)
    let height = line.boundingRect(with: NSSize(width: size.width - 80, height: 200), options: [.usesLineFragmentOrigin]).height
    line.draw(in: NSRect(x: 40, y: y - height, width: size.width - 80, height: height + 4))
}

func render(scale: Int) throws -> URL {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size   // точки, а не пиксели: у @2x 144 dpi
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(origin: .zero, size: size)

    // Фон: тёплый белый сверху, чуть желтее снизу — к цвету грейпфрута на значке; мягкое свечение за местом значков
    NSGradient(colors: [color(0xFFFCF4), color(0xFFF1CF)])!.draw(in: bounds, angle: -90)
    NSGradient(colors: [color(0xFFFFFF, 0.85), color(0xFFFFFF, 0)])!
        .draw(fromCenter: NSPoint(x: 330, y: 200), radius: 0, toCenter: NSPoint(x: 330, y: 200), radius: 260, options: [])

    // Заголовок и подсказка (у AppKit начало координат снизу: y — от низа окна)
    text("Перетащите Melogold в «Программы»", size: 22, weight: .semibold, color: color(0x2B2118), at: 372)
    text("Drag Melogold to Applications", size: 13, weight: .regular, color: color(0x2B2118, 0.55), at: 338)

    // Стрелка между значками: тонкая линия с наконечником, янтарная
    let amber = color(0xE8A02F, 0.85)
    amber.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 282, y: 200))
    arrow.line(to: NSPoint(x: 378, y: 200))
    arrow.move(to: NSPoint(x: 358, y: 222))
    arrow.line(to: NSPoint(x: 380, y: 200))
    arrow.line(to: NSPoint(x: 358, y: 178))
    arrow.stroke()

    // Первый запуск: приложение подписано своим сертификатом, а не Apple Developer ID — Gatekeeper спросит один раз.
    // Подсказка стоит выше нижних 30 pt: там у многих Finder рисует строку пути (общая настройка, окно её не отключает)
    text("Первый запуск: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»",
         size: 11, weight: .regular, color: color(0x2B2118, 0.5), at: 96)
    text("First launch: System Settings → Privacy & Security → “Open Anyway”",
         size: 11, weight: .regular, color: color(0x2B2118, 0.4), at: 78)

    NSGraphicsContext.restoreGraphicsState()
    let url = out.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

let one = try render(scale: 1)
let two = try render(scale: 2)
let tiff = out.appendingPathComponent("background.tiff")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
task.arguments = ["-cathidpicheck", one.path, two.path, "-out", tiff.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: one)
try? FileManager.default.removeItem(at: two)
print("Фон DMG: \(tiff.path)")
