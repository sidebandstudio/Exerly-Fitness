import ExerlyCore
import SwiftUI
import UIKit

/// Presentation values and injected account-service operations. The shared
/// Core session owner supplies these actions when its bridge is available.
struct AccountSignInMethods: Equatable {
    let appleConnected: Bool
    let hasPassword: Bool
}

struct AccountManagementActions {
    var signInMethods: @MainActor () async throws -> AccountSignInMethods
    /// Connecting another way in needs the password, like deleting.
    var connectApple: @MainActor (AppleAuthorizationResult, AccountConfirmation) async throws -> AccountSignInMethods
    var disconnectApple: @MainActor (_ password: String) async throws -> AccountSignInMethods
    var exportAccount: @MainActor () async throws -> Data
    var deleteAccount: @MainActor (AccountConfirmation) async throws -> Void
    var exportDeviceData: (@MainActor () throws -> Data)?
}

struct AccountManagementView: View {
    let accountID: String
    let email: String
    let actions: AccountManagementActions
    @State private var methods: AccountSignInMethods?
    @State private var busy: String?
    @State private var error: String?
    @State private var disconnecting = false
    @State private var linkPassword = ""
    @State private var disconnectPassword = ""
    @State private var task: Task<Void, Never>?
    @AccessibilityFocusState private var errorFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExList {
            Section {
                ExCard(accent: true) {
                    HStack(alignment: .top, spacing: ExSpacing.item) {
                        if !typeSize.isAccessibilitySize {
                        Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 28, weight: .light))
                            .foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: ExSpacing.small) {
                            ExEyebrow("Signed in", color: .exPrimaryText)
                            Text(email).font(typeSize.isAccessibilitySize ? .exCaption : .exBodyMedium).textSelection(.enabled)
                                .accessibilityIdentifier("account.email").fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section("Sign-in methods") {
                if let methods {
                    Label(methods.hasPassword ? "Email and password" : "No password set",
                          systemImage: methods.hasPassword ? "lock" : "lock.slash")
                    if methods.appleConnected {
                        Label("Apple connected", systemImage: "checkmark.circle")
                        Button("Disconnect Apple", role: .destructive) { disconnecting = true }
                            .disabled(!methods.hasPassword || busy != nil)
                            .accessibilityIdentifier("account.disconnectApple")
                        if !methods.hasPassword {
                            Text("Keep Apple connected so you can sign in to this account.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Connect Apple to sign in to this same account. Enter your password first.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("Password", text: $linkPassword)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("account.linkPassword")
                        AppleAuthorizationButton { payload in
                            guard busy == nil else { return }
                            busy = "Connecting Apple…"
                            defer { busy = nil }
                            do {
                                let updated = try await actions.connectApple(payload, .password(linkPassword))
                                try Task.checkCancellation()
                                self.methods = updated
                                linkPassword = ""
                            } catch {
                                if case ExerlyCore.APIError.wrongPassword = error { linkPassword = "" }
                                throw error
                            }
                        }
                        .disabled(busy != nil || linkPassword.isEmpty)
                    }
                } else if busy == nil {
                    Button("Load sign-in methods") { start { try await loadMethods() } }
                }
            }
            Section("Your data") {
                NavigationLink {
                    AccountExportView(actions: actions)
                } label: {
                    Label("Export data", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("account.export")
            }
            Section {
                if let methods {
                    NavigationLink {
                        DeleteAccountView(email: email, hasPassword: methods.hasPassword,
                                          export: actions.exportAccount, delete: actions.deleteAccount)
                    } label: {
                        Label("Delete account", systemImage: "trash")
                            .foregroundStyle(Color.exError)
                    }
                    .disabled(busy != nil)
                    .accessibilityIdentifier("account.delete")
                }
            }
            if let busy { Section { ProgressView(busy) } }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($errorFocused)
                        .accessibilityIdentifier("account.error")
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .exListStyle()
        .task(id: accountID) {
            do { try await loadMethods() } catch is CancellationError { } catch { showError(error) }
        }
        .alert("Disconnect Apple?", isPresented: $disconnecting) {
            SecureField("Password", text: $disconnectPassword)
                .textContentType(.password)
                .accessibilityIdentifier("account.disconnectPassword")
            Button("Cancel", role: .cancel) { disconnectPassword = "" }
            Button("Disconnect Apple", role: .destructive) {
                let password = disconnectPassword
                disconnectPassword = ""
                start {
                    busy = "Disconnecting Apple…"
                    let updated = try await actions.disconnectApple(password)
                    try Task.checkCancellation()
                    methods = updated
                }
            }
        } message: {
            Text("Enter your password. You will use your email and password to sign in.")
        }
        .onDisappear { task?.cancel() }
    }

    private func loadMethods() async throws {
        busy = "Loading account…"
        defer { busy = nil }
        let loaded = try await actions.signInMethods()
        try Task.checkCancellation()
        methods = loaded
    }

    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        error = nil
        busy = "Working…"
        task = Task { @MainActor in
            defer { busy = nil }
            do { try await operation() } catch is CancellationError { } catch {
                guard !Task.isCancelled else { return }
                showError(error)
            }
        }
    }

    private func showError(_ failure: Error) {
        error = AccountScreenError.message(failure)
        errorFocused = true
    }
}

private struct AccountExportView: View {
    let actions: AccountManagementActions
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var exportFile: AccountExportFile?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @AccessibilityFocusState private var errorFocused: Bool

    private var deviceOnly: Bool { sync.isOffline && actions.exportDeviceData != nil }

    var body: some View {
        ExScreen {
            ExCard(accent: true) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: deviceOnly ? "iphone.and.arrow.forward" : "square.and.arrow.up")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
                }
                Text(deviceOnly ? "Saved on this device" : "Account export").font(.exH2)
                Button(deviceOnly ? "Share device export" : "Share account export", systemImage: "square.and.arrow.up") {
                    prepare(deviceOnly: deviceOnly)
                }
                .buttonStyle(ExActionStyle()).disabled(busy).accessibilityIdentifier("account.shareExport")
                Text(deviceOnly
                     ? "You're offline. Share the records saved here as JSON."
                     : "A JSON file with account records and this device's latest changes.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if busy { ProgressView("Preparing export…") }
                if let error {
                    Text(error).foregroundStyle(Color.exError).accessibilityFocused($errorFocused)
                        .accessibilityIdentifier("account.exportError")
                }
            }
            ExCard {
                ExSectionHeading(deviceOnly ? "What's included" : "Complete account export")
                Text(deviceOnly
                     ? "Training, foods, suggestions and entries saved on this device. Account details and records kept only on the server are left out."
                     : "Your account information, food, workouts, body measurements and suggestions. Changes waiting to sync are included.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary)
                Text("Progress photos stay on this device and are not included.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if !deviceOnly, actions.exportDeviceData != nil {
                    Button("Export only this device") { prepare(deviceOnly: true) }
                        .disabled(busy).accessibilityIdentifier("account.exportDevice")
                    Text("Leaves out account details and records kept only on the server.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
        }
        .navigationTitle("Export data").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportFile) { file in
            AccountShareSheet(url: file.url).onDisappear { file.remove() }
        }
        .onDisappear { task?.cancel() }
    }

    private func prepare(deviceOnly: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let data: Data
                if deviceOnly, let exportDeviceData = actions.exportDeviceData { data = try exportDeviceData() } else {
                    data = try await actions.exportAccount()
                }
                try Task.checkCancellation()
                exportFile = try AccountExportFile(data: data, deviceOnly: deviceOnly)
            } catch is CancellationError { } catch {
                guard !Task.isCancelled else { return }
                self.error = AccountScreenError.message(error)
                errorFocused = true
            }
        }
    }
}

private struct DeleteAccountView: View {
    /// A confirmation waiting for the person to say delete, once more.
    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let confirmation: AccountConfirmation
    }

    let email: String
    let hasPassword: Bool
    let export: @MainActor () async throws -> Data
    let delete: @MainActor (AccountConfirmation) async throws -> Void
    @State private var password = ""
    @State private var needsApple = false
    /// A password account connected to Apple, when the server also revokes
    /// Apple's authorization: it sends its password and a fresh Sign in with
    /// Apple's code together.
    @State private var needsAppleToo = false
    @State private var pending: PendingDeletion?
    @State private var deleting = false
    @State private var exporting = false
    @State private var exportFile: AccountExportFile?
    @State private var exported = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var passwordFocused: Bool
    @AccessibilityFocusState private var errorFocused: Bool

    // A password account confirms with its password even with Apple connected.
    private var confirmsWithApple: Bool { !hasPassword || needsApple }
    private var busy: Bool { deleting || exporting }

    var body: some View {
        ExList {
            Section {
                Text(email).font(.exBodyMedium).textSelection(.enabled)
                Text("Deleting your account can’t be undone.")
            }
            Section("Before you delete") {
                Text("Save a copy of your data first: a file with your account, training, food and body records that you can keep or import into another account.")
                    .fixedSize(horizontal: false, vertical: true)
                Button { prepareExport() } label: {
                    Label(exported ? "Export again" : "Export my data",
                          systemImage: exported ? "checkmark.circle" : "square.and.arrow.up")
                }
                .disabled(busy)
                .accessibilityIdentifier("account.deleteExport")
                if exporting { ProgressView("Preparing export…") }
            }
            Section("What deleting does") {
                consequence("trash", "Removes your workouts, food log, body measurements, programs, recipes and settings from Exerly.")
                consequence("iphone.slash", "Signs out every device on this account, and ends access for agents you connected.")
                consequence("photo.on.rectangle", "Removes what this iPhone saved for the account, progress photos included.")
                consequence("heart", "Leaves records already in Apple Health, and exports you saved, where they are.")
            }
            Section {
                if confirmsWithApple {
                    AppleAuthorizationButton { payload in
                        guard !busy else { return }
                        ask(.apple(identityToken: payload.identityToken, rawNonce: payload.rawNonce,
                                   authorizationCode: payload.authorizationCode))
                    }
                    .disabled(busy)
                } else {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($passwordFocused)
                        .submitLabel(.done)
                        .onSubmit { if !password.isEmpty && !needsAppleToo { ask(.password(password)) } }
                        .accessibilityIdentifier("account.deletePassword")
                    if needsAppleToo {
                        AppleAuthorizationButton { payload in
                            guard !busy else { return }
                            ask(.password(password, authorizationCode: payload.authorizationCode))
                        }
                        .disabled(busy || password.isEmpty)
                    } else {
                        Button("Delete my account", role: .destructive) { ask(.password(password)) }
                            .disabled(password.isEmpty || busy)
                            .accessibilityIdentifier("account.confirmDelete")
                    }
                }
            } header: {
                Text("Confirm it’s you")
            } footer: {
                Text(confirmsWithApple ? "Sign in with Apple again to delete this account."
                     : needsAppleToo ? "This account is connected to Apple. With your password entered, sign in with Apple to finish, so Exerly can end its access to your Apple ID."
                     : "Enter the password you sign in with.")
                    .accessibilityIdentifier("account.deleteFooter")
            }
            if deleting { Section { ProgressView("Deleting account…") } }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($errorFocused)
                        .accessibilityIdentifier("account.deleteError")
                }
            }
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .exListStyle()
        .interactiveDismissDisabled(deleting)
        .navigationBarBackButtonHidden(deleting)
        // A sheet rather than an alert: at the largest text sizes an alert cuts
        // the warning off, and this one has to be read in full.
        .sheet(item: $pending) { pending in
            ExConfirmation(title: "Delete this account?",
                           message: exported ? "Your Exerly records will be permanently removed."
                                             : "You haven’t exported your data. Your Exerly records will be permanently removed.",
                           confirm: "Delete account", destructive: true, screenTitle: "Delete account",
                           identifier: "account.deleteConfirmation",
                           perform: { perform(pending.confirmation) },
                           cancel: { self.pending = nil })
        }
        .sheet(item: $exportFile) { file in
            AccountShareSheet(url: file.url) { completed in if completed { exported = true } }
                .onDisappear { file.remove() }
        }
        .onDisappear { task?.cancel() }
    }

    private func consequence(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(Color.exTextSecondary)
        }
    }

    private func ask(_ confirmation: AccountConfirmation) {
        passwordFocused = false
        pending = PendingDeletion(confirmation: confirmation)
    }

    private func prepareExport() {
        guard !busy else { return }
        error = nil
        exporting = true
        task = Task { @MainActor in
            defer { exporting = false }
            do {
                let data = try await export()
                try Task.checkCancellation()
                // Counted as exported only once it's shared or saved.
                exportFile = try AccountExportFile(data: data)
            } catch is CancellationError { } catch {
                guard !Task.isCancelled else { return }
                show(error)
            }
        }
    }

    private func perform(_ confirmation: AccountConfirmation) {
        guard !busy else { return }
        error = nil
        deleting = true
        pending = nil
        task = Task { @MainActor in
            defer { deleting = false }
            do { try await delete(confirmation) } catch is CancellationError { } catch {
                guard !Task.isCancelled else { return }
                switch error {
                case ExerlyCore.APIError.appleReauthorizationRequired where hasPassword:
                    // Keep the password; the footer says what else is needed.
                    needsAppleToo = true
                    return
                case ExerlyCore.APIError.appleReauthorizationRequired: needsApple = true
                case ExerlyCore.APIError.wrongPassword: password = ""
                default: break
                }
                show(error)
            }
        }
    }

    private func show(_ failure: Error) {
        error = AccountScreenError.message(failure)
        errorFocused = true
    }
}

struct AccountExportFile: Identifiable {
    let id = UUID()
    let url: URL

    init(data: Data, directory: URL = FileManager.default.temporaryDirectory, deviceOnly: Bool = false) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        let folder = directory.appendingPathComponent("ExerlyExport-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(deviceOnly ? "exerly-device.json" : "exerly-account.json")
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]) } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private struct AccountShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// Whether the file was shared or saved; false when the sheet was cancelled.
    var finished: (Bool) -> Void = { _ in }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in finished(completed) }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
