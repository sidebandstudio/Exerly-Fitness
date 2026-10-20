import Combine
import ExerlyCore
import Foundation

@MainActor
final class AgentConnectionsModel: ObservableObject {
    enum Permission: String, CaseIterable {
        case propose = "Read and propose"
        case read = "Read only"
        case write = "Direct write"

        var scopes: Set<AccessToken.Scope> {
            switch self {
            case .read: [.read]
            case .propose: [.read, .propose]
            case .write: [.read, .propose, .write]
            }
        }
    }

    @Published private(set) var tokens: [AccessToken] = []
    @Published private(set) var created: CreatedAccessToken?
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isLoading = false
    /// Whether the account confirms with Sign in with Apple, having no password.
    @Published private(set) var confirmsWithApple: Bool
    private let api: AccountAPI
    private var secretGeneration = UUID()
    private var refreshGeneration = UUID()

    init(api: AccountAPI, hasPassword: Bool) {
        self.api = api
        confirmsWithApple = !hasPassword
    }

    func refresh() async {
        let request = UUID()
        refreshGeneration = request
        isLoading = true
        defer { if refreshGeneration == request { isLoading = false } }
        do {
            let fresh = try await api.accessTokens()
            guard refreshGeneration == request, !Task.isCancelled else { return }
            tokens = fresh
            error = nil
        } catch {
            guard refreshGeneration == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Creates a token once `confirmation` shows it's the account's owner. A
    /// token outlives this session, so the session alone isn't enough.
    /// Returns whether it was created.
    @discardableResult
    func create(name: String, permission: Permission, expiresInDays: Int,
                confirmation: AccountConfirmation) async -> Bool {
        guard !isBusy else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "Give this agent a name."; return false }
        let request = secretGeneration
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await api.createAccessToken(name: trimmed, scopes: permission.scopes,
                                                         expiresInDays: expiresInDays, confirmation: confirmation)
            if secretGeneration == request, !Task.isCancelled { created = result }
            await refresh()
            return true
        } catch {
            guard secretGeneration == request, !Task.isCancelled else { return false }
            if case ExerlyCore.APIError.appleReauthorizationRequired = error { confirmsWithApple = true }
            self.error = error.localizedDescription
            return false
        }
    }

    func revoke(_ token: AccessToken) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await api.revokeAccessToken(id: token.id)
            // Reflect confirmed revocation even when the subsequent refresh fails.
            tokens.removeAll { $0.id == token.id }
            if created?.token.id == token.id { clearSecret() }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearSecret() {
        secretGeneration = UUID()
        created = nil
    }
}
