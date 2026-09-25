import SwiftUI
import MelogoldCore
import MelogoldData

/// «Настройки» — стандартная `Form` с группами (docs/PROMPT.md §5.9). Группы наполняются по срезам:
/// каждая настройка множится на все клиенты, поэтому здесь только то, что уже работает.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.account.noAccount")
                        .font(.headline)
                    Text("settings.account.localLibrary")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                NavigationLink(value: Route.server(prefill: nil, serverId: nil)) {
                    LabeledContent {
                        Text(verbatim: URL(string: settings.serverURL)?.host() ?? settings.serverURL)
                    } label: {
                        Text("settings.server")
                    }
                }
                .accessibilityIdentifier("settings.server")
            }

            Section("settings.appearance") {
                Picker("settings.theme", selection: $settings.theme) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                languageRow
            }

            PlaybackSettingsSection()
            StorageSettingsSection()

            Section("settings.about") {
                LabeledContent {
                    Text(verbatim: "\(AppVersion.current) (\(AppVersion.build))")
                        .textSelection(.enabled)
                } label: {
                    Text("settings.version")
                }
                Link(destination: URL(string: "https://github.com/melogold-app/melogoldiOSmacOS")!) {
                    Text("settings.sourceCode")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(AppSection.settings.title))
    }

    /// Язык приложения — системный выбор: на iPhone, iPad и Vision — страница приложения в Настройках,
    /// на Mac — подсказка, где он в Системных настройках.
    @ViewBuilder
    private var languageRow: some View {
        #if os(macOS)
        LabeledContent {
            EmptyView()
        } label: {
            Text("settings.language")
            Text("settings.language.macHint")
        }
        #else
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            LabeledContent {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            } label: {
                Text("settings.language")
                    .foregroundStyle(Color.primary)
            }
        }
        #endif
    }
}
