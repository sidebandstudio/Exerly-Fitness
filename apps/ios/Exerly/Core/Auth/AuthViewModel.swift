import Foundation
import SwiftUI
import CryptoKit
import ExerlyCore

enum AuthState: Equatable {
    case loading, unauthenticated, onboarding, authenticated, connectionFailed
}

enum AccountDeletionOutcome: Equatable {
    case deleted
    /// The account uses Sign in with Apple: ask Apple for a fresh authorization
    /// and call `deleteAccount` again with it. Nothing was deleted.
    case appleReauthorizationRequired
}

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var authState: AuthState = .loading
    @Published var currentUser: UserDTO? {
        didSet {
            if let unitSystem = currentUser?.unitSystem {
                defaults.set(unitSystem, forKey: "unitSystem")
            }
        }
    }
    @Published var error: String?
    @Published var isSubmitting = false
    @Published var isOffline = false
    @Published private(set) var setupStatus: SetupStatus?
    /// From the last bootstrap; nil until the server has been reached.
    @Published private(set) var signInMethods: SignInMethods?
    /// Accounts deleted on the server whose data is still on this device. The
    /// app removes it (see `deleteAccount`) and then calls `finishLocalCleanup`.
    /// Kept across launches, so an interrupted cleanup resumes.
    @Published private(set) var accountsAwaitingLocalCleanup: [String] = []
    private static let cleanupKey = "exerly.accounts.awaitingLocalCleanup"

    private let api: APIClient
    private let keychain: any SessionCredentials
    private let defaults: UserDefaults
    private let onSessionInvalidated: @MainActor () -> Void
    private var expiryObserver: NSObjectProtocol?
    private var deletionObserver: NSObjectProtocol?
    private var sessionGeneration = UUID()
    var sessionID: UUID { sessionGeneration }

    init(api: APIClient = .shared, keychain: any SessionCredentials = KeychainService.shared,
         defaults: UserDefaults = .standard, automaticallyCheck: Bool = true,
         onSessionInvalidated: @escaping @MainActor () -> Void = { NotificationService.shared.configure(accountID: nil) }) {
        self.api = api
        self.keychain = keychain
        self.defaults = defaults
        self.onSessionInvalidated = onSessionInvalidated
        expiryObserver = NotificationCenter.default.addObserver(
            forName: .exerlySessionExpired, object: nil, queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor in
                guard let self, self.keychain.getToken() == token else { return }
                self.invalidateSession()
            }
        }
        accountsAwaitingLocalCleanup = defaults.stringArray(forKey: Self.cleanupKey) ?? []
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .exerlyAccountDeleted, object: nil, queue: .main
        ) { [weak self] notification in
            guard let accountID = notification.object as? String else { return }
            Task { @MainActor in
                guard let self, APIClient.accountID(in: self.keychain.getToken()) == accountID else { return }
                self.accountRemoved(accountID)
            }
        }
        if automaticallyCheck { Task { await checkAuth() } }
    }

    deinit {
        if let expiryObserver { NotificationCenter.default.removeObserver(expiryObserver) }
        if let deletionObserver { NotificationCenter.default.removeObserver(deletionObserver) }
    }

    /// The account is gone on the server: sign out and queue its local data for removal.
    private func accountRemoved(_ accountID: String) {
        if !accountsAwaitingLocalCleanup.contains(accountID) {
            accountsAwaitingLocalCleanup.append(accountID)
            defaults.set(accountsAwaitingLocalCleanup, forKey: Self.cleanupKey)
        }
        if APIClient.accountID(in: keychain.getToken()) == accountID { invalidateSession() }
    }

    /// Call once the account's local training database and legacy data are removed.
    func finishLocalCleanup(for accountID: String) {
        accountsAwaitingLocalCleanup.removeAll { $0 == accountID }
        defaults.set(accountsAwaitingLocalCleanup, forKey: Self.cleanupKey)
    }

    private func cacheKey(_ token: String) -> String {
        APIClient.accountCacheKey(token)
    }

    private func accept(_ user: UserDTO, setupComplete: Bool? = nil) {
        currentUser = user
        authState = (setupComplete ?? (user.onboardingCompleted == true)) ? .authenticated : .onboarding
        isOffline = false
        error = nil
        if let token = keychain.getToken(), let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: cacheKey(token))
            defaults.set(authState == .authenticated, forKey: cacheKey(token) + ".complete")
        }
    }

    private func invalidateSession() {
        sessionGeneration = UUID()
        onSessionInvalidated()
        if let token = keychain.getToken() {
            defaults.removeObject(forKey: cacheKey(token))
            defaults.removeObject(forKey: cacheKey(token) + ".complete")
        }
        keychain.deleteToken()
        currentUser = nil
        setupStatus = nil
        signInMethods = nil
        authState = .unauthenticated
        isOffline = false
    }

    private func finalizeAuthenticatedSession(_ response: AuthResponse) throws {
        try APIClient.validateSession(response)
        guard let user = response.user else { throw APIError.invalidSessionResponse }
        guard keychain.saveSession(token: response.token, refreshToken: response.refreshToken) else { throw APIError.sessionStorage }
        sessionGeneration = UUID()
        currentUser = user
        authState = .loading
        isOffline = false
    }

    func checkAuth(useCached: Bool = true) async {
        guard let token = keychain.getToken() else {
            authState = .unauthenticated
            return
        }
        let generation = sessionGeneration
        if useCached, let data = defaults.data(forKey: cacheKey(token)),
           let cached = try? JSONDecoder().decode(UserDTO.self, from: data),
           cached.id != nil, APIClient.accountID(in: token).map({ $0 == cached.id }) ?? true {
            currentUser = cached
            let completeKey = cacheKey(token) + ".complete"
            let complete = defaults.object(forKey: completeKey) == nil ? cached.onboardingCompleted == true : defaults.bool(forKey: completeKey)
            authState = complete ? .authenticated : .onboarding
        }
        do {
            let bootstrap: BootstrapResponse = try await api.get("/api/bootstrap")
            guard generation == sessionGeneration else { return }
            guard let owner = APIClient.accountID(in: keychain.getToken()),
                  bootstrap.account_id == owner, bootstrap.account.id == owner,
                  bootstrap.onboarding.user.id == owner else { throw APIError.invalidSessionResponse }
            setupStatus = bootstrap.onboarding
            signInMethods = bootstrap.sign_in_methods
            accept(bootstrap.account, setupComplete: bootstrap.onboarding.complete)
        } catch is CancellationError {
            if generation == sessionGeneration && authState == .loading {
                authState = .connectionFailed
                self.error = "Your session changed while connecting. Try again."
            }
            return
        } catch APIError.unauthorized {
            guard generation == sessionGeneration else { return }
            invalidateSession()
        } catch APIError.accountDeleted {
            guard generation == sessionGeneration, let owner = APIClient.accountID(in: token) else { return }
            accountRemoved(owner)
        } catch {
            guard generation == sessionGeneration else { return }
            self.error = error.localizedDescription
            isOffline = true
            if currentUser == nil || authState == .loading { authState = .connectionFailed }
        }
    }

    func login(email: String, password: String) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        let generation = sessionGeneration
        defer { isSubmitting = false }
        do {
            let response = try await api.login(email: email, password: password)
            guard generation == sessionGeneration else { return }
            try finalizeAuthenticatedSession(response)
            await checkAuth(useCached: false)
        } catch { if generation == sessionGeneration { self.error = error.localizedDescription } }
    }

    func signup(email: String, password: String, name: String) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        let generation = sessionGeneration
        defer { isSubmitting = false }
        do {
            let response = try await api.signup(email: email, password: password, name: name)
            guard generation == sessionGeneration else { return }
            try finalizeAuthenticatedSession(response)
            if let user = currentUser { accept(user, setupComplete: false) }
        } catch { if generation == sessionGeneration { self.error = error.localizedDescription } }
    }

    /// Signs in with a native Apple credential, then bootstraps exactly as `login` does.
    /// Give Apple the nonce's SHA-256 and pass the raw nonce here. When a password
    /// account already owns the email, `error` asks the person to sign in with the
    /// password and connect Apple in Settings.
    func signInWithApple(identityToken: String, rawNonce: String, name: String?) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        let generation = sessionGeneration
        defer { isSubmitting = false }
        do {
            let response = try await api.signInWithApple(AppleSignInRequest(
                identityToken: identityToken, nonce: rawNonce, name: name,
                timezone: TimeZone.current.identifier, unitSystem: defaults.string(forKey: "unitSystem")))
            guard generation == sessionGeneration else { return }
            try finalizeAuthenticatedSession(response)
            await checkAuth(useCached: false)
        } catch { if generation == sessionGeneration { self.error = error.localizedDescription } }
    }

    // MARK: Account

    /// The signed-in account's documents and account actions, for ExerlyCore's
    /// `SyncEngine` and Settings. Every request is bound to this account and
    /// fails with `ExerlyCore.APIError.accountChanged` if the session changes.
    var accountAPI: AccountAPI? {
        guard let id = currentUser?.id, APIClient.accountID(in: keychain.getToken()) == id else { return nil }
        return AccountAPI(accountID: id, transport: api)
    }

    private func signedInAccount() throws -> AccountAPI {
        guard let account = accountAPI else { throw ExerlyCore.APIError.notSignedIn }
        return account
    }

    /// Connects Sign in with Apple. Throws `ExerlyCore.APIError.linkConflict` when
    /// the Apple ID belongs to another account.
    func linkApple(identityToken: String, rawNonce: String) async throws {
        let account = try signedInAccount()
        try await account.connectApple(identityToken: identityToken, rawNonce: rawNonce)
        if currentUser?.id == account.accountID { signInMethods?.apple = true }
    }

    /// Disconnects Sign in with Apple. The server refuses when the account has no
    /// password; `signInMethods` says so in advance.
    func unlinkApple() async throws {
        let account = try signedInAccount()
        try await account.disconnectApple()
        if currentUser?.id == account.accountID { signInMethods?.apple = false }
    }

    /// The full JSON export, for the share sheet.
    func exportAccount() async throws -> Data {
        try await signedInAccount().exportAccount()
    }

    /// Deletes the account and all of its data on the server, then signs out,
    /// forgets this account's session and cached account data, and adds it to
    /// `accountsAwaitingLocalCleanup`.
    ///
    /// If the response is lost, the server is asked whether the account still
    /// exists, so a deletion that happened is reported as one. If that can't be
    /// told either, the original error is thrown and a retry settles it.
    ///
    /// Shut down the account's ExerlyCore `SyncEngine` first. For each account
    /// awaiting cleanup, the app deletes the training database with
    /// `SQLiteTrainingPersistence.deleteDatabase(accountID:)`, calls
    /// `SyncEngine.shared.purge(accountID:)`, then `finishLocalCleanup(for:)`.
    func deleteAccount(confirmation: AccountConfirmation) async throws -> AccountDeletionOutcome {
        let account = try signedInAccount()
        do {
            try await account.deleteAccount(confirmation: confirmation)
        } catch ExerlyCore.APIError.appleReauthorizationRequired {
            return .appleReauthorizationRequired
        } catch ExerlyCore.APIError.accountDeleted {
            // Already gone: a lost response, or deleted on another device.
        } catch let error as URLError where error.code != .cancelled {
            do {
                let _: BootstrapResponse = try await api.get("/api/bootstrap")
            } catch APIError.accountDeleted {
                accountRemoved(account.accountID)
                return .deleted
            } catch {}
            throw error
        }
        accountRemoved(account.accountID)
        return .deleted
    }

    @discardableResult
    func completeOnboarding(_ data: OnboardingRequest, operationID: String) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        error = nil
        let generation = sessionGeneration
        defer { isSubmitting = false }
        do {
            let result = try await api.completeOnboarding(data, operationID: operationID)
            guard generation == sessionGeneration, result.complete, result.targets != nil else { return false }
            guard result.user.id == APIClient.accountID(in: keychain.getToken()) else { throw APIError.invalidSessionResponse }
            accept(result.user, setupComplete: true)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == sessionGeneration else { return false }
            // A committed setup with a lost or malformed acknowledgement is
            // resolved by status. A second completion request is unnecessary.
            if let status: SetupStatus = try? await api.get("/api/onboarding/status"),
               generation == sessionGeneration, status.complete, status.targets != nil,
               status.user.id == APIClient.accountID(in: keychain.getToken()) {
                accept(status.user, setupComplete: true)
                return true
            }
            self.error = error.localizedDescription
            return false
        }
    }

    func logout() {
        let api = self.api
        let token = keychain.getToken()
        invalidateSession()
        if let token { Task { await api.revokeSession(accessToken: token) } }
    }
    func refreshUser() async { await checkAuth() }

    func updateSettings(timezone: String, unitSystem: String) async throws {
        let generation = sessionGeneration
        let accountID = currentUser?.id
        let response = try await api.updateSettings(SettingsRequest(timezone: timezone, unitSystem: unitSystem))
        guard generation == sessionGeneration, response.user.id == accountID else { throw CancellationError() }
        acceptPreferences(response.user, accountID: accountID, sessionID: generation)
    }

    func acceptPreferences(_ user: UserDTO, accountID: String?, sessionID: UUID) {
        guard sessionID == sessionGeneration, let accountID,
              currentUser?.id == accountID, user.id == accountID,
              APIClient.accountID(in: keychain.getToken()) == accountID,
              (user.preferencesRevision ?? 0) >= (currentUser?.preferencesRevision ?? 0) else { return }
        accept(user)
    }
}
