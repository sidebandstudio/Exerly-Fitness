import ExerlyCore
import SwiftUI

/// Forgot password: email a code, then choose a new password with it. The
/// server ends every session on success, so this returns to sign-in.
struct PasswordResetView: View {
    let onBack: () -> Void
    let onReset: (String) -> Void
    @EnvironmentObject private var authVM: AuthViewModel

    @State var email: String
    @State private var code = ""
    @State private var password = ""
    @State private var sentNotice: String?
    @State private var busy = false
    @State private var error: String?
    @State private var shakeAttempts: CGFloat = 0
    @FocusState private var focus: Field?
    @AccessibilityFocusState private var errorFocused: Bool

    enum Field { case email, code, password }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var canSend: Bool { trimmedEmail.contains("@") && !busy }
    private var canReset: Bool { PasswordResetCode.normalized(code) != nil && password.count >= 8 && !busy }

    var body: some View {
        if let sentNotice {
            AuthPage(title: "Check your email", detail: sentNotice, onBack: changeEmail) {
                VStack(spacing: ExSpacing.small) {
                    AuthField(title: "Code", kind: .code, text: $code, field: Field.code, focus: $focus) { focus = .password }
                        .onChange(of: code) { _, typed in
                            let shown = PasswordResetCode.formatted(typed)
                            if shown != typed { code = shown }
                        }
                    AuthField(title: "New password", kind: .newPassword, text: $password, field: Field.password,
                              focus: $focus, submitLabel: .go) { if canReset { reset() } }
                }
                .modifier(ShakeEffect(animatableData: shakeAttempts))
                Label("At least 8 characters", systemImage: password.count >= 8 ? "checkmark.circle.fill" : "circle")
                    .font(.exCaption)
                    .foregroundStyle(password.count >= 8 ? Color.exSuccess : Color.exTextSecondary)
                    .padding(.horizontal, ExSpacing.tight)
                    .accessibilityLabel(password.count >= 8 ? "Password has at least 8 characters" : "Use at least 8 characters")
                errorLabel
                Button(action: reset) {
                    HStack(spacing: ExSpacing.small) {
                        if busy { ProgressView().tint(.white) }
                        Text("Change Password")
                    }
                }
                .buttonStyle(ExActionStyle())
                .disabled(!canReset)
                .accessibilityIdentifier("reset.submit")
                Text("Changing your password signs you out on every device.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                AuthSwitchLink(question: "No email?", action: "Send a new code") { send() }
                    .disabled(busy)
                    .accessibilityIdentifier("reset.resend")
            }
            .onAppear { focus = .code }
        } else {
            AuthPage(title: "Reset your password", detail: "Enter your account’s email and we’ll send you a code to choose a new password.",
                     onBack: onBack) {
                AuthField(title: "Email", kind: .email, text: $email, field: Field.email, focus: $focus, submitLabel: .send) {
                    if canSend { send() }
                }
                errorLabel
                Button(action: send) {
                    HStack(spacing: ExSpacing.small) {
                        if busy { ProgressView().tint(.white) }
                        Text("Email Me a Code")
                    }
                }
                .buttonStyle(ExActionStyle())
                .disabled(!canSend)
                .accessibilityIdentifier("reset.send")
            }
        }
    }

    @ViewBuilder private var errorLabel: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.exLabel).foregroundStyle(Color.exError)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityFocused($errorFocused)
                .accessibilityIdentifier("reset.error")
        }
    }

    private func changeEmail() {
        sentNotice = nil
        clear()
    }

    private func clear() {
        code = ""
        password = ""
        error = nil
    }

    private func send() {
        guard !busy else { return }
        focus = nil
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let notice = try await authVM.requestPasswordReset(email: trimmedEmail)
                clear()
                sentNotice = "\(notice) Enter it below with a new password."
            } catch { fail(error) }
        }
    }

    private func reset() {
        guard let normalized = PasswordResetCode.normalized(code), !busy else { return }
        focus = nil
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await authVM.resetPassword(email: trimmedEmail, code: normalized, newPassword: password)
                onReset(trimmedEmail)
            } catch {
                fail(error)
                withAnimation(.spring(response: 0.3)) { shakeAttempts += 1 }
            }
        }
    }

    private func fail(_ failure: Error) {
        error = failure.localizedDescription
        errorFocused = true
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
