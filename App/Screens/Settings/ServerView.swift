import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldServer

/// «Сервер Melogold» (REWRITE §3.5.12, API §7.1): адрес проверяется `ServerAddressPolicy`, для `http` —
/// предупреждение «Незащищённое соединение». Перед переключением — `/server/info`: это Melogold, версия API
/// подходит, `serverId` совпадает со ссылкой. Смена сервера завершает вход на прежнем.
struct ServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let prefill: String?
    let expectedServerId: String?

    @State private var address = ""
    @State private var didPrefill = false
    @State private var checking = false
    @State private var error: (any Error)?
    @State private var mismatch = false

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
                Button(action: save) {
                    HStack {
                        Text("server.connect")
                        if checking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(result.url == nil || result.url == model.settings.serverURL || checking)
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
        if mismatch {
            Text("server.error.otherServer")
                .foregroundStyle(.red)
        } else if let error {
            Text(AccountText.message(for: error))
                .foregroundStyle(.red)
        }
        if model.account.isSignedIn {
            Text("server.switchSignsOut")
        }
    }

    private func save() {
        guard let url = result.url, !checking else { return }
        checking = true
        error = nil
        mismatch = false
        Task {
            defer { checking = false }
            do {
                let info = try await model.account.check(url)
                if let expectedServerId, info.serverId != expectedServerId {
                    mismatch = true
                    return
                }
                model.settings.serverURL = url
                model.account.serverChanged()
                Log.info("server", "Адрес сервера изменён: \(info.instanceName) \(info.version)")
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}
