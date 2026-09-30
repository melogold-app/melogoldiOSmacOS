#if os(macOS)
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Мини-плеер Mac (docs/PROMPT.md §5.4): маленькое окно поверх остальных на стекле Liquid Glass, как «Мини-плеер» в
/// Music.app. Обложка, название, исполнитель, ⏮ ⏯ ⏭, ♡ и полоса перемотки со временем. Окно без рамки: его двигают за любое
/// место, под указателем появляются «Закрыть» и «Открыть Melogold» (обложка делает то же — открывает «Сейчас играет»).
/// Открывается из меню «Окно» (⌥⌘M) и с панели воспроизведения (`MiniPlayerPanel`); положение помнится.
struct MacMiniPlayer: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private enum Metrics {
        static let width: CGFloat = 380
        static let cover: CGFloat = 88
        static let padding: CGFloat = 12
        static let corner: CGFloat = 26
    }

    var body: some View {
        let player = model.services.player
        let track = player.currentTrack
        HStack(spacing: Design.Space.s) {
            cover(track)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: track?.title ?? String(localized: "player.nothingPlaying"))
                        .font(.headline)
                        .lineLimit(1)
                    if track != nil { PlayerStatusLine(font: .subheadline) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, hovering ? 56 : 0)
                Spacer(minLength: 0)
                HStack(spacing: Design.Space.xs) {
                    PreviousButton(glass: GlassSpec(diameter: 32, glass: false))
                    PlayPauseButton(glass: GlassSpec(diameter: 36, glass: false))
                    NextButton(glass: GlassSpec(diameter: 32, glass: false))
                    Spacer(minLength: 0)
                    LikeButton(size: .callout, tap: 30)
                }
                .disabled(track == nil)
                SeekBar(style: .compact)
                    .frame(height: 12)
            }
            .frame(height: Metrics.cover)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(alignment: .topTrailing) { windowButtons }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("window.miniPlayer"))
    }

    private func cover(_ track: Track?) -> some View {
        Button { showMain() } label: {
            ArtworkView(url: track?.artworkURL, size: Metrics.cover, cornerRadius: Design.Radius.medium)
        }
        .buttonStyle(.plain)
        .disabled(track == nil)
        .help(Text("mini.openMain"))
        .accessibilityLabel(Text("mini.openMain"))
    }

    /// «Открыть Melogold» и «Закрыть», только пока указатель над окном.
    private var windowButtons: some View {
        HStack(spacing: 2) {
            MiniButton(symbol: "arrow.up.left.and.arrow.down.right", label: "mini.openMain") { showMain() }
            MiniButton(symbol: "xmark", label: "mini.close") { MiniPlayerPanel.shared.close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Design.Space.xs)
        .opacity(hovering ? 1 : 0)
    }

    /// Главное окно с «Сейчас играет»: окно могло быть закрыто (музыка при этом играет).
    private func showMain() {
        model.openMainWindow?()
        model.showNowPlaying = model.services.player.currentTrack != nil
        NSApp.activate()
    }
}

/// Кнопка в углу мини-плеера: 24 pt, значок приглушён, под указателем подсвечивается.
private struct MiniButton: View {
    let symbol: String
    let label: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .hoverHighlight(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// Окно мини-плеера: панель без рамки на прозрачном фоне (стекло рисует сам вид), всегда поверх остальных, над
/// полноэкранным главным окном, не прячется вместе с приложением. Нажатия по кнопкам не делают приложение активным —
/// мини-плеером управляют, не выходя из другой программы. Это AppKit-панель, а не сцена SwiftUI: сцена `Window`
/// открывалась при каждом запуске рядом с главным окном. Положение помнится (автосохранение рамки).
@MainActor
final class MiniPlayerPanel {
    static let shared = MiniPlayerPanel()
    private var panel: NSPanel?
    private static let frameName = "MelogoldMiniPlayer"

    var isVisible: Bool { panel?.isVisible == true }

    /// Пункт «Мини-плеер» меню «Окно» и кнопка панели: открыть, а если открыт — закрыть.
    func toggle(model: AppModel) {
        if isVisible { close() } else { show(model: model) }
    }

    func show(model: AppModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let host = NSHostingView(rootView: MacMiniPlayer().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        let panel = MiniPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.title = String(localized: "window.miniPlayer")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.setContentSize(host.fittingSize)
        if !panel.setFrameUsingName(Self.frameName) {
            // Первый раз — правый верхний угол экрана под строкой меню
            if let area = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 16))
            }
        }
        panel.setContentSize(host.fittingSize)
        panel.setFrameAutosaveName(Self.frameName)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    #if DEBUG
    /// Снимки: поставить панель в точку экрана (от левого нижнего угла, как `NSWindow`) и снова поднять над всем.
    func debugPlace(at point: NSPoint) {
        panel?.setFrameOrigin(point)
        panel?.orderFrontRegardless()
    }
    #endif

    /// Панель без рамки по умолчанию не становится главной и ключевой: нужно, чтобы работали Esc и фокус с клавиатуры.
    private final class MiniPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
#endif
