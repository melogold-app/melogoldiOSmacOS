import SwiftUI
import MelogoldCore

/// Корень раздела, который наполняется в следующих срезах: название раздела и его значок, без текста-заглушки.
struct SectionPlaceholder: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
        }
        .navigationTitle(Text(section.title))
    }
}
