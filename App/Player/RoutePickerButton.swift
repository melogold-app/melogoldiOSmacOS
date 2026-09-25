import AVKit
import SwiftUI

/// AirPlay и выбор устройства вывода — системный `AVRoutePickerView` (docs/PROMPT.md §4 «Система»).
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
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
