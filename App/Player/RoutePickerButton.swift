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
        view.tintColor = .secondaryLabel
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
