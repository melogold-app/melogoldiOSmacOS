import SwiftUI
import MelogoldServer

/// Верх «Настроек»: «Работает без аккаунта» с «Войти» и «Создать аккаунт», вошедший аккаунт или «Войдите снова».
struct AccountSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

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
                accountRow(icon: "person.crop.circle.fill", tint: nil) {
                    Text(verbatim: login)
                    SyncStatusLine(status: model.sync.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("account.overview")

        case .authRequired(let login):
            NavigationLink(value: Route.account(.signIn(login: login))) {
                accountRow(icon: "exclamationmark.triangle.fill", tint: .orange) {
                    Text(verbatim: login)
                    Text(AccountText.sessionEnded(model.account.endedReason))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("account.signIn")
        }
    }
}

extension AccountSettingsSection {
    /// Строка аккаунта: значок и два текста. Крупный шрифт: текст колонкой рядом со значком — у `Label` он переносился под
    /// значок, и вторая строка начиналась правее первой.
    @ViewBuilder
    fileprivate func accountRow<Lines: View>(icon: String, tint: Color?, @ViewBuilder text: () -> Lines) -> some View {
        if typeSize.isAccessibilitySize {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Image(systemName: icon).foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 2) { text() }
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) { text() }
            } icon: {
                Image(systemName: icon).foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
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
