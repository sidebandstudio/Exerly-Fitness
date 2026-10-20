import ExerlyCore
import SwiftUI

/// App composition only: Core owns sessions, persistence, sync and server calls.
/// This owner outlives the signed-in screens so confirmed deletion cleanup can
/// finish after AuthViewModel returns the app to sign-in.
@MainActor
final class AppAccountWorkspace: ObservableObject {
    @Published private(set) var training: TrainingWorkspace?
    @Published private(set) var openingError: String?
    @Published private(set) var isChangingAccount = false
    @Published private(set) var cleanupError: String?
    private let open: @MainActor (AccountAPI) throws -> TrainingWorkspace
    private let deleteTraining: @MainActor (String) throws -> Void
    private let purgeLegacy: @MainActor (String) throws -> Void
    private let pendingLegacy: @MainActor (String) throws -> [AccountExport.PendingRow]
    private var generation = UUID()
    private var closing: (id: UUID, task: Task<Void, Never>)?
    private var isCleaning = false

    init(open: @escaping @MainActor (AccountAPI) throws -> TrainingWorkspace = {
             try TrainingWorkspace(accountID: $0.accountID, api: $0)
         },
         deleteTraining: @escaping @MainActor (String) throws -> Void = {
             try TrainingWorkspace.deleteStorage(accountID: $0)
         },
         purgeLegacy: @escaping @MainActor (String) throws -> Void = {
             try SyncEngine.shared.purge(accountID: $0)
         },
         pendingLegacy: @escaping @MainActor (String) throws -> [AccountExport.PendingRow] = { accountID in
             guard SyncEngine.shared.isConfigured(for: accountID) else { throw ExerlyCore.APIError.accountChanged }
             return try SyncEngine.shared.pendingExportRows()
         }) {
        self.open = open
        self.deleteTraining = deleteTraining
        self.purgeLegacy = purgeLegacy
        self.pendingLegacy = pendingLegacy
    }

    func configure(_ account: AccountAPI?) async {
        guard !isChangingAccount else { return }
        if let account, training?.accountID == account.accountID { return }
        let request = UUID()
        generation = request
        openingError = nil
        await closeTraining()
        guard generation == request, !Task.isCancelled else { return }
        guard let account else { return }
        do { training = try open(account) }
        catch { openingError = "Your saved training could not open. Keep Exerly installed and try again." }
    }

    func signOut(auth: AuthViewModel) async {
        guard !isChangingAccount else { return }
        isChangingAccount = true
        generation = UUID()
        await closeTraining()
        auth.logout()
        isChangingAccount = false
    }

    func deleteAccount(auth: AuthViewModel, confirmation: AccountConfirmation) async throws {
        guard !isChangingAccount, let account = auth.accountAPI else { throw ExerlyCore.APIError.notSignedIn }
        isChangingAccount = true
        generation = UUID()
        defer { isChangingAccount = false }
        await training?.sync?.shutdown()
        do {
            try Task.checkCancellation()
            let result = try await auth.deleteAccount(confirmation: confirmation)
            if result == .appleReauthorizationRequired { throw ExerlyCore.APIError.appleReauthorizationRequired }
            // Core persists confirmed deletions before clearing the session.
            await closeTraining()
            finishCleanup(auth: auth)
        } catch {
            if auth.accountAPI?.accountID == account.accountID {
                training?.resumeSync(api: account)
            } else {
                await closeTraining()
            }
            throw error
        }
    }

    func retryCleanup(auth: AuthViewModel) async {
        guard !isChangingAccount, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        if let training, auth.accountsAwaitingLocalCleanup.contains(training.accountID) {
            generation = UUID()
            await closeTraining()
        }
        finishCleanup(auth: auth)
    }

    private func closeTraining() async {
        // Detach before suspension. A cancelled transition must not leave a
        // closed workspace looking reusable to the next account request.
        let previous = training
        training = nil
        let previousClose = closing?.task
        let id = UUID()
        let task = Task { @MainActor in
            await previousClose?.value
            await previous?.close()
        }
        closing = (id, task)
        await task.value
        if closing?.id == id { closing = nil }
    }

    private func finishCleanup(auth: AuthViewModel) {
        for accountID in auth.accountsAwaitingLocalCleanup {
            do {
                try deleteTraining(accountID)
                try purgeLegacy(accountID)
                try ProgressPhotoStore.removeAll(accountID: accountID)
                auth.finishLocalCleanup(for: accountID)
            } catch { /* Core retains this confirmed deletion for the next retry. */ }
        }
        cleanupError = auth.accountsAwaitingLocalCleanup.isEmpty ? nil :
            "Your account was deleted. Some saved data on this device still needs to be removed. Retry cleanup."
    }

    /// The account's time zone and units, written into an export.
    static func exportContext(_ auth: AuthViewModel) -> AccountExport.Context {
        AccountExport.Context(timeZone: TimeZone(identifier: auth.currentUser?.timezone ?? "") ?? .current,
                              unit: auth.currentUser?.unitSystem == "metric" ? .kilograms : .pounds)
    }

    func actions(auth: AuthViewModel, accountID: String) -> AccountManagementActions {
        func checkAccount() throws {
            guard auth.accountAPI?.accountID == accountID else { throw ExerlyCore.APIError.accountChanged }
        }
        func methods() async throws -> AccountSignInMethods {
            try checkAccount()
            if auth.signInMethods == nil { await auth.checkAuth() }
            try checkAccount()
            guard let values = auth.signInMethods else {
                throw ExerlyCore.APIError.server(status: 0, message: "Connect to Exerly to load your sign-in methods.")
            }
            return AccountSignInMethods(appleConnected: values.apple, hasPassword: values.password)
        }
        func savedTraining() throws -> TrainingWorkspace {
            try checkAccount()
            guard let training = self.training, training.accountID == accountID else {
                throw ExerlyCore.APIError.server(status: 0, message: "Open your saved training before exporting. Try again from the Train tab.")
            }
            return training
        }
        var actions = AccountManagementActions(signInMethods: { try await methods() }, connectApple: { payload, confirmation in
            try checkAccount()
            try await auth.linkApple(identityToken: payload.identityToken, rawNonce: payload.rawNonce,
                                     confirmation: confirmation)
            return try await methods()
        }, disconnectApple: { password in
            try checkAccount()
            try await auth.unlinkApple(password: password)
            return try await methods()
        }, exportAccount: {
            try checkAccount()
            let server = try await auth.exportAccount()
            return try savedTraining().export(server: server, pending: self.pendingLegacy(accountID), context: Self.exportContext(auth))
        }, deleteAccount: { code in
            try checkAccount()
            try await self.deleteAccount(auth: auth, confirmation: code)
        })
        actions.exportDeviceData = {
            try savedTraining().export(server: nil, pending: self.pendingLegacy(accountID), context: Self.exportContext(auth))
        }
        return actions
    }
}
