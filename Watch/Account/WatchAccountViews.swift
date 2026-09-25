import SwiftUI
import MelogoldCore
import MelogoldServer

/// Аккаунт на часах (docs/PROMPT.md §5.6): часы входят сами и в аккаунте — отдельное устройство. Вход по коду —
/// первым: набирать пароль на часах неудобно.
struct WatchAccountSection: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        switch model.account.state {
        case .signedOut:
            Text("settings.account.noAccount")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink("account.signIn.code") { WatchLinkRequestView() }
            NavigationLink("account.signIn") { WatchSignInView(initialLogin: "") }
            NavigationLink("account.register") { WatchRegisterView() }
        case .signedIn(let login):
            NavigationLink {
                WatchAccountView()
            } label: {
                Label(login, systemImage: "person.crop.circle.fill")
            }
        case .authRequired(let login):
            NavigationLink {
                WatchSignInView(initialLogin: login)
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(verbatim: login)
                        Text(AccountText.sessionEnded(model.account.endedReason))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Вход логином и паролем: клавиатура часов, рукописный ввод, диктовка или клавиатура iPhone.
struct WatchSignInView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var login: String
    @State private var password = ""
    @State private var busy = false
    @State private var error: (any Error)?

    init(initialLogin: String) {
        _login = State(initialValue: initialLogin)
    }

    var body: some View {
        Form {
            TextField("account.login", text: $login)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("account.password", text: $password)
                .textContentType(.password)
            Button {
                busy = true
                error = nil
                Task {
                    defer { busy = false }
                    do {
                        try await model.account.signIn(login: login, password: password)
                        dismiss()
                    } catch {
                        self.error = error
                    }
                }
            } label: {
                if busy { ProgressView() } else { Text("account.signIn") }
            }
            .disabled(login.isEmpty || password.isEmpty || busy)
            if let error {
                Text(AccountText.message(for: error))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(Text("account.signIn"))
    }
}

/// Регистрация на часах; после неё — код восстановления.
struct WatchRegisterView: View {
    @Environment(WatchModel.self) private var model

    @State private var login = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: (any Error)?
    @State private var recovery: (code: String, createdAt: String)?

    var body: some View {
        Group {
            if let recovery {
                WatchRecoveryCodeView(code: recovery.code, createdAt: recovery.createdAt)
            } else {
                Form {
                    TextField("account.login", text: $login)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("account.password", text: $password)
                        .textContentType(.newPassword)
                    Button {
                        busy = true
                        error = nil
                        Task {
                            defer { busy = false }
                            do {
                                let session = try await model.account.register(login: login, password: password)
                                recovery = (session.recoveryCode ?? "", session.user.recoveryCodeStatus.createdAt)
                            } catch {
                                self.error = error
                            }
                        }
                    } label: {
                        if busy { ProgressView() } else { Text("account.register") }
                    }
                    .disabled(login.isEmpty || password.isEmpty || busy)
                    if model.account.solvingProofOfWork {
                        Text("account.register.pow")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(AccountText.message(for: error))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("account.register.rules")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle(Text("account.register"))
            }
        }
    }
}

/// Код восстановления на часах: буфера обмена нет, поэтому «Поделиться» (`ShareLink`).
struct WatchRecoveryCodeView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let code: String
    let createdAt: String
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("account.recoveryCode.explain")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(verbatim: LinkCode.grouped(LinkCode.recoveryCode(code) ?? code))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .multilineTextAlignment(.center)
                ShareLink(item: code) {
                    Label("account.share", systemImage: "square.and.arrow.up")
                }
                Toggle("account.recoveryCode.saved", isOn: $saved)
                Button("account.done") {
                    let createdAt = createdAt
                    Task { try? await model.account.confirmRecoveryCode(createdAt: createdAt) }
                    dismiss()
                }
                .disabled(!saved)
            }
        }
        .navigationTitle(Text("account.recoveryCode"))
        .navigationBarBackButtonHidden(true)
    }
}

/// Вход по коду (API §4.6, режим `request`): часы показывают код, на вошедшем iPhone, iPad, Mac или Vision его
/// вводят в «Аккаунт › Добавить устройство» и выбирают число, которое часы показывают следом.
struct WatchLinkRequestView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var created: LinkCreated?
    @State private var verifyCode: String?
    @State private var approverName: String?
    @State private var error: (any Error)?
    @State private var completed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if completed {
                    Label("account.link.completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("account.done") { dismiss() }
                } else if let verifyCode {
                    Text("account.link.pick")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Text(verbatim: verifyCode)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .accessibilityLabel(Text(verbatim: verifyCode))
                    if let approverName {
                        Text("account.link.on \(approverName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let created {
                    Text("account.link.explain")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Text(verbatim: LinkCode.grouped(LinkCode.userCode(created.userCode) ?? created.userCode))
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                } else if error == nil {
                    ProgressView()
                }
                if let error {
                    Text(AccountText.message(for: error))
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("account.link.retry") { Task { await start() } }
                }
            }
        }
        .navigationTitle(Text("account.signIn.code"))
        .task { await start() }
        .onDisappear {
            if !completed, let secret = created?.pollSecret {
                Task { await model.account.cancelLinkRequest(pollSecret: secret) }
            }
        }
    }

    private func start() async {
        error = nil
        verifyCode = nil
        do {
            let request = try await model.account.startLinkRequest()
            created = request
            guard let secret = request.pollSecret else { return }
            var known = "pending"
            while !Task.isCancelled {
                let response = try await model.account.pollLink(pollSecret: secret, knownStatus: known)
                switch response.status {
                case "claimed":
                    verifyCode = response.verifyCode
                    approverName = response.approverDevice?.name
                    known = "claimed"
                case "completed":
                    completed = true
                    return
                default:
                    continue
                }
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error
            created = nil
        }
    }
}

/// Аккаунт на часах: логин, устройства аккаунта и «Выйти».
struct WatchAccountView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [DeviceDto] = []
    @State private var confirmingSignOut = false

    var body: some View {
        List {
            Section {
                Text(verbatim: model.account.session?.login ?? "")
                    .font(.headline)
            }
            Section("account.devices") {
                ForEach(devices) { device in
                    Label {
                        VStack(alignment: .leading) {
                            Text(verbatim: device.name)
                            if device.isCurrent {
                                Text("account.device.current")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: DeviceSymbol.name(for: device.platform))
                    }
                }
            }
            Section {
                Button("account.signOut", role: .destructive) { confirmingSignOut = true }
            } footer: {
                Text("account.signOut.footer")
            }
        }
        .navigationTitle(Text("account.title"))
        .task { devices = (try? await model.account.devices().devices) ?? [] }
        .confirmationDialog("account.signOut.confirm", isPresented: $confirmingSignOut) {
            Button("account.signOut", role: .destructive) {
                Task {
                    await model.account.signOut()
                    dismiss()
                }
            }
        }
    }
}
