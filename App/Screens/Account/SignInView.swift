import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Вход»: логин и пароль (API §4.3). Сервер — тот, что выбран в «Настройки › Сервер Melogold».
struct SignInView: View {
    @Environment(AppModel.self) private var model

    @State private var login: String
    @State private var password = UITestHooks.password
    @State private var busy = false
    @State private var error: (any Error)?

    init(initialLogin: String) {
        _login = State(initialValue: initialLogin)
    }

    var body: some View {
        Form {
            Section {
                LoginField(text: $login)
                SecureField("account.password", text: $password)
                    .textContentType(.password)
                    .onSubmit(submit)
            } footer: {
                AccountErrorFooter(error: error)
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Text("account.signIn")
                        if busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(login.isEmpty || password.isEmpty || busy)
                .accessibilityIdentifier("account.signIn.submit")
                NavigationLink(value: Route.account(.recover(login: login))) {
                    Text("account.forgotPassword")
                }
            } footer: {
                Text("account.server.footer \(ServerHost.display(model.settings.serverURL))")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.signIn"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func submit() {
        guard !busy, !login.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await model.account.signIn(login: login, password: password)
                model.closeAccountScreens()
            } catch {
                self.error = error
            }
        }
    }
}

/// «Создать аккаунт»: логин и пароль, proof-of-work, затем код восстановления (API §4.3).
struct RegisterView: View {
    @Environment(AppModel.self) private var model

    @State private var login = ""
    @State private var password = UITestHooks.password
    @State private var busy = false
    @State private var error: (any Error)?

    var body: some View {
        let account = model.account
        Form {
            Section {
                LoginField(text: $login)
                SecureField("account.password", text: $password)
                    .textContentType(.newPassword)
                    .onSubmit(submit)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("account.register.rules")
                    AccountErrorFooter(error: error)
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Text("account.register")
                        if busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(login.isEmpty || password.isEmpty || busy)
                .accessibilityIdentifier("account.register.submit")
                if account.solvingProofOfWork {
                    Text("account.register.pow")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("account.server.footer \(ServerHost.display(model.settings.serverURL))")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.register"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func submit() {
        guard !busy, !login.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let session = try await model.account.register(login: login, password: password)
                model.routes[.settings] = [
                    .account(.recoveryCode(code: session.recoveryCode ?? "", createdAt: session.user.recoveryCodeStatus.createdAt)),
                ]
            } catch {
                self.error = error
            }
        }
    }
}

/// «Забыли пароль?»: код восстановления и новый пароль (API §4.5). Прежние устройства выходят.
struct RecoverView: View {
    @Environment(AppModel.self) private var model

    @State private var login: String
    @State private var code = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: (any Error)?

    init(initialLogin: String) {
        _login = State(initialValue: initialLogin)
    }

    private var normalizedCode: String? { LinkCode.recoveryCode(code) }

    var body: some View {
        Form {
            Section {
                LoginField(text: $login)
                TextField("account.recoveryCode", text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX-XXXX-XXXX"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                SecureField("account.newPassword", text: $password)
                    .textContentType(.newPassword)
            } header: {
                Text("account.recover.explain")
                    .textCase(nil)
            } footer: {
                AccountErrorFooter(error: error)
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Text("account.recover.submit")
                        if busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(login.isEmpty || normalizedCode == nil || password.isEmpty || busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.recover"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func submit() {
        guard let normalizedCode, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let session = try await model.account.recover(login: login, recoveryCode: normalizedCode, newPassword: password)
                model.routes[.settings] = [
                    .account(.recoveryCode(code: session.recoveryCode ?? "", createdAt: session.user.recoveryCodeStatus.createdAt)),
                ]
            } catch {
                self.error = error
            }
        }
    }
}

/// Код восстановления — один раз: крупно, моноширинным шрифтом, «Скопировать», «Поделиться» и «Код сохранён»
/// (docs/PROMPT.md §5.9). Назад не уйти, пока код не сохранён.
struct RecoveryCodeView: View {
    @Environment(AppModel.self) private var model

    let code: String
    let createdAt: String

    @State private var saved = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(verbatim: LinkCode.grouped(LinkCode.recoveryCode(code) ?? code))
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("account.recoveryCode.value")
                HStack {
                    Button {
                        copy()
                    } label: {
                        Label(copied ? "account.copied" : "account.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Spacer()
                    ShareLink(item: code) {
                        Label("account.share", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("account.recoveryCode.explain")
                    .textCase(nil)
            }

            Section {
                Toggle("account.recoveryCode.saved", isOn: $saved)
                    .accessibilityIdentifier("account.recoveryCode.saved")
                Button("account.done", action: finish)
                    .disabled(!saved)
                    .accessibilityIdentifier("account.recoveryCode.done")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.recoveryCode"))
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        copied = true
    }

    private func finish() {
        let createdAt = createdAt
        Task {
            // Сервер перестаёт напоминать о коде; не вышло — напомнит, это не мешает
            try? await model.account.confirmRecoveryCode(createdAt: createdAt)
        }
        model.closeAccountScreens()
    }
}

/// Хост сервера для подписей: `178-250-187-202.sslip.io`, `music.example.com:8080`.
enum ServerHost {
    static func display(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        return components.port.map { "\(host):\($0)" } ?? host
    }
}
