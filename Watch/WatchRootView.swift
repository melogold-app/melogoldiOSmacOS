import SwiftUI
import MelogoldCore

/// Корень часов — список (HIG watchOS): разделы в общем порядке Тренды · Новое · Библиотека · Поиск · Настройки.
/// Строка «Сейчас играет» появится над разделами вместе с плеером (срез 2).
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            List(AppSection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
            .navigationTitle(Text(verbatim: "Melogold"))
            .navigationDestination(for: AppSection.self) { section in
                WatchSectionView(section: section)
            }
        }
    }
}

struct WatchSectionView: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .settings:
            WatchSettingsView()
        default:
            ContentUnavailableView {
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationTitle(Text(section.title))
        }
    }
}

struct WatchSettingsView: View {
    var body: some View {
        List {
            Section {
                Text("settings.account.noAccount")
            }
            Section("settings.about") {
                LabeledContent {
                    Text(verbatim: AppVersion.current)
                } label: {
                    Text("settings.version")
                }
            }
        }
        .navigationTitle(Text(AppSection.settings.title))
    }
}
