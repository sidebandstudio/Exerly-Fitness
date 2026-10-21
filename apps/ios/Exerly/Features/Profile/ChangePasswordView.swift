import SwiftUI

struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @FocusState private var focus: Field?

    enum Field { case current, new, confirm }

    var body: some View {
        NavigationStack {
            ExScreen {
                Text("Use at least 8 characters, and a password you don't use anywhere else. Changing it signs out every device and disconnects agents you connected.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: ExSpacing.small) {
                    AuthField(title: "Current password", kind: .password, text: $currentPassword, field: Field.current,
                              focus: $focus) { focus = .new }
                    AuthField(title: "New password", kind: .newPassword, text: $newPassword, field: Field.new,
                              focus: $focus) { focus = .confirm }
                    AuthField(title: "Confirm new password", kind: .newPassword, text: $confirmPassword, field: Field.confirm,
                              focus: $focus, submitLabel: .done) { focus = nil }
                }
                if !confirmPassword.isEmpty && confirmPassword != newPassword {
                    Label("The new passwords don't match yet.", systemImage: "exclamationmark.circle")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill").font(.exLabel).foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showSuccess {
                    Label("Password changed. Every device is signed out, and agents you connected are disconnected.",
                          systemImage: "checkmark.circle.fill").font(.exLabel).foregroundStyle(Color.exSuccess)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await changePassword() }
                } label: {
                    HStack(spacing: ExSpacing.small) {
                        if isSaving { ProgressView().tint(.white) }
                        Text("Change password")
                    }
                }
                .buttonStyle(ExActionStyle())
                .disabled(isSaving || !isValid)
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var isValid: Bool {
        !currentPassword.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    private func changePassword() async {
        guard isValid else { return }
        focus = nil
        isSaving = true
        errorMessage = nil
        showSuccess = false

        do {
            let _: APIMessageResponse = try await APIClient.shared.post(
                "/api/change-password",
                body: ChangePasswordRequest(
                    currentPassword: currentPassword,
                    newPassword: newPassword
                )
            )
            showSuccess = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct ChangePasswordRequest: Encodable {
    let currentPassword: String
    let newPassword: String
}
