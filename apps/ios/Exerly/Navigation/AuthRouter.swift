import SwiftUI

enum AuthRoute: Equatable {
    case welcome, login, signup, resetPassword
}

struct AuthRouter: View {
    @State private var route: AuthRoute = .welcome
    @State private var email = ""
    @State private var notice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch route {
            case .welcome:
                WelcomeView(onLogin: { route = .login }, onSignup: { route = .signup })
                    .transition(.opacity)
            case .login:
                LoginView(onBack: { route = .welcome; notice = nil }, onSwitchToSignup: { route = .signup; notice = nil },
                          onForgotPassword: { typed in email = typed; notice = nil; route = .resetPassword },
                          initialEmail: email, notice: notice)
                    .transition(reduceMotion ? .opacity : .slideFromEdge(.trailing))
            case .resetPassword:
                PasswordResetView(onBack: { route = .login }, onReset: { reset in
                    email = reset
                    notice = "Password changed. Sign in with your new password."
                    route = .login
                }, email: email)
                .transition(reduceMotion ? .opacity : .slideFromEdge(.trailing))
            case .signup:
                SignupView(onBack: { route = .welcome }, onSwitchToLogin: { route = .login })
                    .transition(reduceMotion ? .opacity : .slideFromEdge(.trailing))
            }
        }
        .animation(.snappy(duration: 0.35), value: route)
    }
}
