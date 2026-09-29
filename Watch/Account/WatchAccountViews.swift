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
                Label {
                    VStack(alignment: .leading) {
                        Text(verbatim: login)
                        SyncStatusLine(status: model.sync.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.crop.circle.fill")
                }
            }
            .accessibilityIdentifier("account.overview")
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
/// вводят в «Аккаунт › Добавить устройство» и выбирают число, которое часы показывают следом. Ожидание, повтор без
/// связи и отказы — общий `NewDeviceLinker`, как в приложении.
struct WatchLinkRequestView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var linker: NewDeviceLinker?

    private var state: NewDeviceLinkState { linker?.state ?? .idle }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch state {
                case .idle, .starting:
                    ProgressView()
                case .showingCode(let userCode, _, let reconnecting):
                    Text("account.link.explain")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Text(verbatim: LinkCode.grouped(LinkCode.userCode(userCode) ?? userCode))
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .accessibilityLabel(Text("account.link.spokenCode \(LinkTiming.spokenCode(userCode))"))
                    if reconnecting { reconnectingText }
                case .verify(let number, _, let approverName, _, _, let reconnecting):
                    Text("account.link.pick")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Text(verbatim: number)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .accessibilityLabel(Text("account.link.spokenNumber \(number)"))
                    Text("account.link.on \(approverName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if reconnecting { reconnectingText }
                case .signedIn:
                    Label("account.link.completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("account.done") { dismiss() }
                case .failed(let failure, _):
                    Text(AccountText.link(failure, invite: false))
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("account.link.retry") { linker?.showCode() }
                }
            }
        }
        .navigationTitle(Text("account.signIn.code"))
        .task {
            guard linker == nil else { return }
            let linker = NewDeviceLinker(port: model.account)
            self.linker = linker
            linker.showCode()
        }
        .onDisappear {
            if state != .signedIn { linker?.cancel() }
        }
    }

    private var reconnectingText: some View {
        Text("account.link.reconnecting")
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
    }
}

/// Аккаунт на часах: логин, синхронизация (при открытии — сразу), устройства аккаунта и «Выйти».
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
            Section {
                SyncStatusLine(status: model.sync.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("sync.now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.sync.sync() }
                }
                .disabled(model.sync.status == .syncing)
            } header: {
                Text("sync.title")
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
                    .accessibilityIdentifier("account.signOut")
            } footer: {
                Text("account.signOut.footer")
            }
        }
        .navigationTitle(Text("account.title"))
        .task(id: model.sync.devicesRevision) { devices = (try? await model.account.devices().devices) ?? [] }
        .task { await model.sync.sync() }
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
