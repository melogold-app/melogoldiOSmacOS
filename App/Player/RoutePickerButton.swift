import AVKit
import SwiftUI
#if os(iOS)
import MediaPlayer
#endif

/// AirPlay и выбор устройства вывода — системный `AVRoutePickerView` (docs/PROMPT.md §4 «Система»). Цвета — как у
/// остальных значков управления (`Design`): обычный `label`, при выводе на другое устройство — системный акцент.
#if os(macOS)
struct RoutePickerButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        // Как соседние значки панели: приглушённый, акцентом — пока звук идёт на другое устройство
        // Цвет — динамический: `labelColor.withAlphaComponent` считается один раз для оформления при запуске, и после смены
        // темы на светлую белый значок пропадал на светлой капсуле
        view.setRoutePickerButtonColor(NSColor(name: nil) { appearance in
            var label = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance { label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
            return label.withAlphaComponent(0.75)
        }, for: .normal)
        view.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#elseif os(visionOS)
/// На Vision Pro устройство вывода выбирает система (Пункт управления) — своей кнопки нет.
struct RoutePickerButton: View {
    var body: some View { EmptyView() }
}
#else
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        // Как «Текст» и «Очередь» в нижнем ряду: приглушённый, акцентом — пока звук идёт на другое устройство
        // Не `secondaryLabel`: на оттенке обложки он 3,2 к 1 (`Design.secondaryOnTint`); при повышенной контрастности ярче
        view.tintColor = UIColor { trait in
            let alpha: CGFloat = trait.accessibilityContrast == .high ? 0.9 : (trait.userInterfaceStyle == .dark ? 0.85 : 0.66)
            return UIColor.label.resolvedColor(with: trait).withAlphaComponent(alpha)
        }
        view.activeTintColor = .tintColor
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Громкость устройства — системный `MPVolumeView` (HIG «Playing audio», «Sliders»): свой `Slider` для громкости на
/// iOS не годится. iPad; на iPhone есть кнопки громкости.
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .label
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
#endif
