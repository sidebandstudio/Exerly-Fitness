import SwiftUI

struct LoginView: View {
    let onBack: () -> Void
    var onSwitchToSignup: (() -> Void)?
    /// Opens Forgot password with the email typed so far.
    var onForgotPassword: ((String) -> Void)?
    var initialEmail = ""
    /// Shown above the form, such as after a password reset.
    var notice: String?
    @EnvironmentObject private var authVM: AuthViewModel

    @State private var email = ""
    @State private var password = ""
    @State private var shakeAttempts: CGFloat = 0
    @FocusState private var focus: Field?
    @AccessibilityFocusState private var errorFocused: Bool

    enum Field { case email, password }

    private var canSubmit: Bool { !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !authVM.isSubmitting }

    var body: some View {
        AuthPage(title: "Welcome back", detail: "Sign in to pick up where you left off.", onBack: onBack) {
            VStack(spacing: ExSpacing.small) {
                AuthField(title: "Email", kind: .email, text: $email, field: Field.email, focus: $focus) { focus = .password }
                AuthField(title: "Password", kind: .password, text: $password, field: Field.password, focus: $focus,
                          submitLabel: .go) { if canSubmit { submit() } }
            }
            .modifier(ShakeEffect(animatableData: shakeAttempts))
            if let onForgotPassword {
                Button("Forgot password?") {
                    authVM.error = nil
                    onForgotPassword(email.trimmingCharacters(in: .whitespaces))
                }
                .font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                .accessibilityIdentifier("login.forgotPassword")
            }
            if let notice, authVM.error == nil {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.exLabel).foregroundStyle(Color.exSuccess)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("login.notice")
            }
            if let error = authVM.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.exLabel).foregroundStyle(Color.exError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($errorFocused)
            }
            Button(action: submit) {
                HStack(spacing: ExSpacing.small) {
                    if authVM.isSubmitting { ProgressView().tint(.white) }
                    Text("Log In")
                }
            }
            .buttonStyle(ExActionStyle())
            .disabled(!canSubmit)
            if Bundle.main.object(forInfoDictionaryKey: "EXERLY_BUILD_ENVIRONMENT") as? String == "staging" {
                Text("Internal testing. Enable Tailscale to connect.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            AuthDivider().padding(.vertical, ExSpacing.tight)
            AppleAuthorizationButton { payload in
                await authVM.signInWithApple(identityToken: payload.identityToken, rawNonce: payload.rawNonce, name: payload.name)
                if authVM.error != nil { errorFocused = true }
            }
            .disabled(authVM.isSubmitting)
            if let onSwitchToSignup {
                AuthSwitchLink(question: "New to Exerly?", action: "Create an account") {
                    authVM.error = nil
                    onSwitchToSignup()
                }
                .padding(.top, ExSpacing.small)
            }
        }
        .onAppear {
            authVM.error = nil
            if email.isEmpty { email = initialEmail }
            if notice != nil { focus = .password }
        }
    }

    private func submit() {
        focus = nil
        Task {
            await authVM.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            if authVM.error != nil {
                errorFocused = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.spring(response: 0.3)) { shakeAttempts += 1 }
            }
        }
    }
}
