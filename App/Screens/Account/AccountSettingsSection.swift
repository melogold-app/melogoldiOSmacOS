import SwiftUI
import MelogoldServer

/// Верх «Настроек»: «Работает без аккаунта» с «Войти» и «Создать аккаунт», вошедший аккаунт или «Войдите снова».
struct AccountSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.account.state {
        case .signedOut:
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.account.noAccount")
                    .font(.headline)
                Text("settings.account.localLibrary")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            NavigationLink(value: Route.account(.signIn(login: nil))) {
                Text("account.signIn")
            }
            .accessibilityIdentifier("account.signIn")
            NavigationLink(value: Route.account(.register)) {
                Text("account.register")
            }
            .accessibilityIdentifier("account.register")

        case .signedIn(let login):
            NavigationLink(value: Route.account(.overview)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: login)
                        SyncStatusLine(status: model.sync.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.crop.circle.fill")
                }
            }
            .accessibilityIdentifier("account.overview")

        case .authRequired(let login):
            NavigationLink(value: Route.account(.signIn(login: login))) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: login)
                        Text(AccountText.sessionEnded(model.account.endedReason))
                            .font(.subheadline)
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

/// Поле логина: без автозамены и заглавных.
struct LoginField: View {
    @Binding var text: String

    var body: some View {
        TextField("account.login", text: $text)
            .textContentType(.username)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}

/// Отказ под полями формы.
struct AccountErrorFooter: View {
    let error: (any Error)?

    var body: some View {
        if let error {
            Text(AccountText.message(for: error))
                .foregroundStyle(.red)
        }
    }
}
