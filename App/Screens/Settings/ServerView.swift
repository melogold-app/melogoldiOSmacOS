import SwiftUI
import MelogoldCore
import MelogoldData

/// «Сервер Melogold» (REWRITE §3.5.12, API §7.1): адрес проверяется `ServerAddressPolicy`, для `http` —
/// предупреждение «Незащищённое соединение». Проверка `/server/info` и вход — срез 5.
struct ServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let prefill: String?
    let expectedServerId: String?

    @State private var address = ""
    @State private var didPrefill = false

    private var result: ServerAddress { ServerAddressPolicy.normalize(address) }

    var body: some View {
        Form {
            Section {
                TextField("server.address", text: $address, prompt: Text(verbatim: ServerDefaults.baseURL))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(save)
            } footer: {
                footer
            }

            Section {
                Button("server.connect", action: save)
                    .disabled(result.url == nil || result.url == model.settings.serverURL)
                if model.settings.serverURL != ServerDefaults.baseURL {
                    Button("server.resetDefault") {
                        model.settings.serverURL = ServerDefaults.baseURL
                        address = ServerDefaults.baseURL
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("settings.server"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            address = prefill ?? model.settings.serverURL
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch result {
        case .valid(_, let insecure):
            if insecure {
                Label("server.insecure", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .invalid(.empty):
            EmptyView()
        case .invalid(let error):
            Text(ServerAddressText.message(for: error))
                .foregroundStyle(.red)
        }
    }

    private func save() {
        guard let url = result.url else { return }
        model.settings.serverURL = url
        Log.info("server", "Адрес сервера изменён")
        dismiss()
    }
}
