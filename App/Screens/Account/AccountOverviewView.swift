import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Аккаунт» (docs/PROMPT.md §5.9): синхронизация, устройства со значком по платформе, текущее отмечено;
/// «Отозвать», «Выйти на других устройствах», «Добавить устройство», пароль, новый код восстановления и «Выйти».
/// Если сервер требует пароль для недавно добавленного устройства (`recent_device_restricted`), спрашивает его и
/// повторяет. Смена пароля без старого на другом устройстве — карточка с «Отозвать устройство» (API §4.3).
struct AccountOverviewView: View {
    @Environment(AppModel.self) private var model

    @State private var devices: [DeviceDto] = []
    @State private var maxDevices: Int?
    @State private var loading = true
    @State private var error: (any Error)?

    @State private var revoking: DeviceDto?
    @State private var confirmingRevokeOthers = false
    @State private var confirmingSignOut = false
    @State private var passwordRequest: PasswordRequest?
    @State private var password = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var message: LocalizedStringResource?

    /// Действие, для которого сервер попросил пароль.
    struct PasswordRequest: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        let action: (String) async throws -> Void
    }

    var body: some View {
        Form {
            if let warning = model.sync.accountWarning, warning.reason == "password_changed_without_old" {
                warningSection(warning)
            }

            Section {
                LabeledContent("account.login") {
                    Text(verbatim: model.account.session?.login ?? "")
                        .textSelection(.enabled)
                }
                LabeledContent("settings.server") {
                    Text(verbatim: ServerHost.display(model.account.session?.serverURL ?? model.settings.serverURL))
                }
            }

            Section {
                HStack {
                    SyncStatusLine(status: model.sync.status)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.sync.status == .syncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Button {
                    Task { await model.sync.sync() }
                } label: {
                    Label("sync.now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.sync.status == .syncing)
                .accessibilityIdentifier("sync.now")
            } header: {
                Text("sync.title")
            } footer: {
                Text("sync.what")
            }

            Section {
                if loading && devices.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                ForEach(devices) { device in
                    deviceRow(device)
                }
            } header: {
                if let maxDevices {
                    Text("account.devices.count \(devices.count) \(maxDevices)")
                } else {
                    Text("account.devices")
                }
            } footer: {
                AccountErrorFooter(error: error)
            }

            Section {
                NavigationLink(value: Route.account(.addDevice)) {
                    Label("account.addDevice", systemImage: "plus.circle")
                }
                if devices.count > 1 {
                    Button {
                        confirmingRevokeOthers = true
                    } label: {
                        Label("account.revokeOthers", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }

            Section {
                NavigationLink(value: Route.account(.changePassword)) {
                    Label("account.changePassword", systemImage: "key")
                }
                Button {
                    ask("account.newRecoveryCode") { password in
                        let response = try await model.account.rotateRecoveryCode(password: password)
                        model.routes[.settings, default: []].append(.account(.recoveryCode(code: response.recoveryCode, createdAt: response.createdAt)))
                    }
                } label: {
                    Label("account.newRecoveryCode", systemImage: "lifepreserver")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    Label("account.signOut", systemImage: "person.crop.circle.badge.xmark")
                }
                .accessibilityIdentifier("account.signOut")
            } footer: {
                Text("account.signOut.footer")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Список перечитывается и на `devices.updated` с сервера
        .task(id: model.sync.devicesRevision) { await load() }
        .refreshable { await load() }
        .confirmationDialog("account.signOut.confirm", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("account.signOut", role: .destructive) {
                Task {
                    await model.account.signOut()
                    model.closeAccountScreens()
                }
            }
        } message: {
            Text("account.signOut.footer")
        }
        .confirmationDialog(
            revoking.map { Text("account.revoke.confirm \($0.name)") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible,
            presenting: revoking
        ) { device in
            Button("account.revoke", role: .destructive) {
                perform("account.revoke") { password in
                    try await model.account.revokeDevice(device.id, password: password)
                    if model.sync.accountWarning?.byDeviceId == device.id { model.sync.dismissAccountWarning() }
                }
            }
        } message: { _ in
            Text("account.revoke.explain")
        }
        .confirmationDialog("account.revokeOthers.confirm", isPresented: $confirmingRevokeOthers, titleVisibility: .visible) {
            Button("account.revokeOthers", role: .destructive) {
                perform("account.revokeOthers") { password in
                    let count = try await model.account.revokeOtherDevices(password: password)
                    message = "account.revokeOthers.done \(count)"
                }
            }
        }
        .alert(
            passwordRequest.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { passwordRequest != nil }, set: { if !$0 { passwordRequest = nil } }),
            presenting: passwordRequest
        ) { request in
            SecureField("account.password", text: $password)
            Button("account.confirm") {
                let entered = password
                password = ""
                Task { await run { try await request.action(entered) } }
            }
            Button("account.cancel", role: .cancel) { password = "" }
        } message: { _ in
            Text("account.password.required")
        }
        .alert("account.rename", isPresented: $renaming) {
            TextField("account.deviceName", text: $newName)
            Button("account.save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let current = devices.first(where: \.isCurrent) else { return }
                perform("account.rename") { password in
                    _ = try await model.account.renameDevice(current.id, name: name.isEmpty ? nil : name, password: password)
                }
            }
            Button("account.cancel", role: .cancel) {}
        }
        .alert(
            message.map { Text($0) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("account.done") {}
        }
    }

    /// «Пароль изменён на „MacBook Air“ без старого пароля. Это не вы?» (API §4.3, SSE `account.updated`).
    @ViewBuilder
    private func warningSection(_ warning: AccountWarning) -> some View {
        Section {
            Label {
                Text("account.warning.passwordWithoutOld \(warning.byDeviceName ?? "—")")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
            if let device = devices.first(where: { $0.id == warning.byDeviceId && !$0.isCurrent }) {
                Button("account.warning.revoke", role: .destructive) { revoking = device }
            }
            Button("account.warning.itWasMe") { model.sync.dismissAccountWarning() }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: DeviceDto) -> some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceSymbol.name(for: device.platform))
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.name)
                Group {
                    if device.isCurrent {
                        Text("account.device.current")
                    } else if let seen = IsoTime.date(device.lastSeenAt) {
                        Text("account.device.seen \(seen.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            if device.isCurrent {
                Button("account.rename", systemImage: "pencil") {
                    newName = device.customName ?? device.name
                    renaming = true
                }
            } else {
                Button("account.revoke", systemImage: "xmark.circle", role: .destructive) { revoking = device }
            }
        }
        #if !os(macOS)
        .swipeActions {
            if !device.isCurrent {
                Button("account.revoke", role: .destructive) { revoking = device }
            }
        }
        #endif
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await model.account.devices()
            devices = list.devices
            maxDevices = list.maxDevices
            error = nil
        } catch {
            self.error = error
            if !model.account.isSignedIn { model.closeAccountScreens() }
        }
    }

    /// Действие с устройствами: без пароля, а если сервер его попросил (`recent_device_restricted`) — с паролем.
    private func perform(_ title: LocalizedStringResource, _ action: @escaping (String?) async throws -> Void) {
        Task {
            await run {
                do {
                    try await action(nil)
                } catch let error as APIError where error.code == "recent_device_restricted" {
                    passwordRequest = PasswordRequest(title: title) { password in try await action(password) }
                }
            }
        }
    }

    /// Действие, для которого пароль нужен всегда.
    private func ask(_ title: LocalizedStringResource, _ action: @escaping (String) async throws -> Void) {
        passwordRequest = PasswordRequest(title: title, action: action)
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            error = nil
            await load()
        } catch {
            self.error = error
        }
    }
}

/// «Добавить устройство»: вход нового устройства по коду (API §4.6, режим `request`) — часы, телевизор, чужой
/// компьютер. Код с нового устройства → карточка устройства → число, которое видно на нём.
struct AddDeviceView: View {
    @Environment(AppModel.self) private var model

    @State private var code = ""
    @State private var details: LinkDetails?
    @State private var busy = false
    @State private var error: (any Error)?
    @State private var approved: String?

    var body: some View {
        Form {
            if let approved {
                Section {
                    Label("account.addDevice.done \(approved)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("account.done") { model.routes[.settings]?.removeLast() }
                }
            } else if let details, let device = details.device {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: DeviceSymbol.name(for: device.platform))
                            .font(.title)
                            .foregroundStyle(.tint)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: device.name).font(.headline)
                            Text(verbatim: [device.model, device.osVersion].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let sameNetwork = details.sameNetwork {
                        Text(sameNetwork ? "account.addDevice.sameNetwork" : "account.addDevice.otherNetwork")
                            .foregroundStyle(sameNetwork ? Color.secondary : Color.orange)
                    }
                } header: {
                    Text("account.addDevice.device")
                }

                Section {
                    HStack(spacing: 12) {
                        ForEach(details.verifyChoices, id: \.self) { choice in
                            Button {
                                approve(details.linkId, choice, name: device.name)
                            } label: {
                                Text(verbatim: choice)
                                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                    .frame(maxWidth: .infinity, minHeight: 64)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .disabled(busy)
                    Button("account.addDevice.deny", role: .destructive) { deny(details.linkId) }
                        .disabled(busy)
                } header: {
                    Text("account.addDevice.pick")
                        .textCase(nil)
                } footer: {
                    AccountErrorFooter(error: error)
                }
            } else {
                Section {
                    TextField("account.addDevice.code", text: $code, prompt: Text(verbatim: "XXXX-XXXX"))
                        .font(.title2.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .onSubmit(resolve)
                    Button(action: resolve) {
                        HStack {
                            Text("account.continue")
                            if busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(LinkCode.userCode(code) == nil || busy)
                } header: {
                    Text("account.addDevice.explain")
                        .textCase(nil)
                } footer: {
                    AccountErrorFooter(error: error)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.addDevice"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func resolve() {
        guard let userCode = LinkCode.userCode(code), !busy else { return }
        work { details = try await model.account.resolveLink(userCode: userCode) }
    }

    private func approve(_ linkId: String, _ choice: String, name: String) {
        work {
            _ = try await model.account.approveLink(linkId, verifyCode: choice)
            approved = name
        }
    }

    private func deny(_ linkId: String) {
        work {
            _ = try await model.account.denyLink(linkId)
            details = nil
            code = ""
        }
    }

    private func work(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                self.error = error
                if let apiError = error as? APIError, ["link_expired", "link_verify_mismatch", "link_cancelled"].contains(apiError.code) {
                    details = nil
                }
            }
        }
    }
}

/// «Сменить пароль»: старый пароль можно не вводить — сервер разрешает смену с любого вошедшего устройства
/// (API §4.5), остальные устройства получат предупреждение.
struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var signOutOthers = false
    @State private var busy = false
    @State private var error: (any Error)?
    @State private var signedOut: Int?

    var body: some View {
        Form {
            Section {
                SecureField("account.currentPassword", text: $current)
                    .textContentType(.password)
                SecureField("account.newPassword", text: $new)
                    .textContentType(.newPassword)
                Toggle("account.changePassword.signOutOthers", isOn: $signOutOthers)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("account.changePassword.footer")
                    AccountErrorFooter(error: error)
                }
            }
            Section {
                Button(action: submit) {
                    HStack {
                        Text("account.changePassword")
                        if busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(new.isEmpty || busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.changePassword"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            signedOut.map { Text("account.changePassword.done \($0)") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { signedOut != nil }, set: { if !$0 { signedOut = nil; dismiss() } })
        ) {
            Button("account.done") {}
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                signedOut = try await model.account.changePassword(
                    currentPassword: current.isEmpty ? nil : current,
                    newPassword: new,
                    signOutOtherDevices: signOutOthers
                )
            } catch {
                self.error = error
            }
        }
    }
}
