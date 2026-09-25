import SwiftUI

/// Экраны аккаунта в стеке «Настроек» (docs/PROMPT.md §5.9, Android `AccountScreens.kt`).
enum AccountRoute: Hashable {
    case signIn(login: String?)
    case register
    case recover(login: String?)
    /// Код восстановления после регистрации, восстановления или «Новый код»: показывается один раз.
    case recoveryCode(code: String, createdAt: String)
    case overview
    case addDevice
    case changePassword
}

struct AccountRouteView: View {
    let route: AccountRoute

    var body: some View {
        switch route {
        case .signIn(let login): SignInView(initialLogin: login ?? "")
        case .register: RegisterView()
        case .recover(let login): RecoverView(initialLogin: login ?? "")
        case .recoveryCode(let code, let createdAt): RecoveryCodeView(code: code, createdAt: createdAt)
        case .overview: AccountOverviewView()
        case .addDevice: AddDeviceView()
        case .changePassword: ChangePasswordView()
        }
    }
}

extension AppModel {
    /// Назад к корню «Настроек»: после входа, выхода и сохранённого кода.
    func closeAccountScreens() {
        routes[.settings] = []
    }
}
