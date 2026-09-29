import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Вход по коду» на новом устройстве (API §4.6, задание 0017). Сразу показывает код этого устройства (режим
/// `request`): его вводят на устройстве, где уже вошли, в «Аккаунт › Добавить устройство». «У меня есть код с
/// другого устройства» — поле для кода, который показывает вошедшее устройство (режим `invite`). В обоих режимах
/// дальше крупно число, которое выбирают на том устройстве, и сеанс — как после входа по паролю.
struct SignInByCodeView: View {
    @Environment(AppModel.self) private var model

    @State private var linker: NewDeviceLinker?
    @State private var entering: Bool
    @State private var code = ""

    init(enterCode: Bool) {
        _entering = State(initialValue: enterCode)
    }

    private var state: NewDeviceLinkState { linker?.state ?? .idle }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .navigationTitle(Text("account.link.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard linker == nil else { return }
            let linker = NewDeviceLinker(port: model.account)
            self.linker = linker
            if !entering { linker.showCode() }
        }
        .onChange(of: state) { _, new in
            if new == .signedIn { model.closeAccountScreens() }
        }
        .onDisappear {
            if state != .signedIn { linker?.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .starting:
            if entering { enterCodeSections } else { waitingSection("account.link.gettingCode") }
        case .showingCode(let userCode, let expiresAt, let reconnecting):
            Section {
                LinkCodeBlock(code: userCode)
                LinkStatusRow(expiresAt: expiresAt, reconnecting: reconnecting)
            } header: {
                Text("account.link.request.explain")
                    .textCase(nil)
            }
            Section {
                Button("account.link.haveCode") {
                    linker?.cancel()
                    entering = true
                }
                cancelButton
            }
        case .verify(let number, let login, let approverName, let approverPlatform, let expiresAt, let reconnecting):
            Section {
                Label {
                    Text("account.link.pickOn \(approverName)")
                } icon: {
                    Image(systemName: DeviceSymbol.name(for: approverPlatform))
                        .accessibilityLabel(Text(DeviceSymbol.kind(for: approverPlatform)))
                }
                LinkNumberBlock(number: number)
                Text("account.link.account \(login)")
                    .foregroundStyle(.secondary)
                LinkStatusRow(expiresAt: expiresAt, reconnecting: reconnecting)
            }
            Section {
                cancelButton
            }
        case .signedIn:
            Section {
                Label("account.link.completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(_, started: false) where entering:
            // Введённый код отвергнут: поле остаётся с причиной под ним, ввод не стирается
            enterCodeSections
        case .failed(let failure, let started):
            Section {
                Text(AccountText.link(failure, invite: entering))
                    .foregroundStyle(.red)
            }
            Section {
                if entering {
                    Button("account.link.otherCode") {
                        linker?.cancel()
                        code = ""
                    }
                } else {
                    Button(started ? "account.link.newCode" : "account.link.retry") { linker?.showCode() }
                }
                Button("account.link.password") { model.goBack() }
            }
        }
    }

    @ViewBuilder
    private var enterCodeSections: some View {
        Section {
            TextField("account.addDevice.code", text: $code, prompt: Text(verbatim: "XXXX-XXXX"))
                .font(.title2.monospaced())
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.characters)
                #endif
                .onSubmit(claim)
                .accessibilityIdentifier("account.link.code")
            Button(action: claim) {
                HStack {
                    Text("account.continue")
                    if state == .starting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(LinkCode.userCode(code) == nil || state == .starting)
        } header: {
            Text("account.link.enter.explain")
                .textCase(nil)
        } footer: {
            if case .failed(let failure, started: false) = state {
                Text(AccountText.link(failure, invite: true))
                    .foregroundStyle(.red)
            }
        }
        Section {
            Button("account.link.showMine") {
                entering = false
                linker?.showCode()
            }
        }
    }

    private func waitingSection(_ title: LocalizedStringKey) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cancelButton: some View {
        Button("account.cancel", role: .cancel) {
            linker?.cancel()
            model.goBack()
        }
    }

    private func claim() {
        guard let normalized = LinkCode.userCode(code), state != .starting else { return }
        linker?.claim(userCode: LinkCode.grouped(normalized))
    }
}

/// Код входа крупно: `K7QX-M2PD`, моноширинный, в одну строку (уменьшается, но не рвётся посередине);
/// VoiceOver читает его по знакам.
struct LinkCodeBlock: View {
    let code: String

    private var display: String { LinkCode.grouped(LinkCode.userCode(code) ?? code) }

    var body: some View {
        Text(verbatim: display)
            .font(.system(size: 45, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityLabel(Text("account.link.spokenCode \(LinkTiming.spokenCode(display))"))
            .accessibilityIdentifier("account.link.userCode")
    }
}

/// Число, которое выбирают на другом устройстве: огромное, жирное.
struct LinkNumberBlock: View {
    let number: String

    var body: some View {
        Text(verbatim: number)
            .font(.system(size: 120, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("account.link.spokenNumber \(number)"))
            .accessibilityIdentifier("account.link.verifyCode")
    }
}

/// «Действует 4:32» (обратный отсчёт системы — не объявляется каждую секунду), индикатор ожидания и «Нет связи…».
struct LinkStatusRow: View {
    let expiresAt: Date
    let reconnecting: Bool
    var waiting: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                let now = Date.now
                Text("account.link.validFor \(Text(timerInterval: now ... max(now, expiresAt), countsDown: true))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let waiting {
                    Text(waiting)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            if reconnecting {
                Text("account.link.reconnecting")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
