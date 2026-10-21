import AuthenticationServices
import ExerlyCore
import SwiftUI

/// Values from Apple's native authorization sheet. The account service verifies
/// the token; this view never creates or persists an Exerly session.
struct AppleAuthorizationResult {
    let identityToken: String
    let rawNonce: String
    let authorizationCode: String?
    let name: String?
}

struct AppleAuthorizationButton: View {
    var label: SignInWithAppleButton.Label = .continue
    let authorize: @MainActor (AppleAuthorizationResult) async throws -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var pending: AppleAuthorizationAttempt?
    @State private var submitting = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            appleButton
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(pending != nil || submitting)
                .accessibilityIdentifier("account.appleAuthorization")
            if submitting {
                ProgressView("Connecting to your account…")
                    .font(.footnote)
                    .accessibilityIdentifier("account.appleProgress")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.exError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($errorFocused)
                    .accessibilityIdentifier("account.appleError")
            }
        }
        .onDisappear {
            task?.cancel()
            pending = nil
        }
    }

    @ViewBuilder private var appleButton: some View {
        #if DEBUG
        // UI tests can't complete Apple's sheet in the simulator. With
        // EXERLY_TEST_APPLE_AUTHORIZATION set to "identityToken rawNonce
        // authorizationCode", this button stands in for it. Never compiled
        // into a release build.
        if let simulated = Self.simulatedResult {
            Button("Continue with Apple") { submit(simulated) }
                .buttonStyle(ExActionStyle())
        } else {
            signInWithApple
        }
        #else
        signInWithApple
        #endif
    }

    private var signInWithApple: some View {
        SignInWithAppleButton(label, onRequest: prepare, onCompletion: complete)
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
    }

    #if DEBUG
    private static var simulatedResult: AppleAuthorizationResult? {
        guard let value = ProcessInfo.processInfo.environment["EXERLY_TEST_APPLE_AUTHORIZATION"] else { return nil }
        let parts = value.split(separator: " ").map(String.init)
        guard parts.count == 3 else { return nil }
        return AppleAuthorizationResult(identityToken: parts[0], rawNonce: parts[1], authorizationCode: parts[2], name: nil)
    }
    #endif

    private func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let attempt = AppleAuthorizationAttempt()
        pending = attempt
        error = nil
        request.requestedScopes = [.fullName, .email]
        request.nonce = attempt.nonce.sha256
        request.state = attempt.state
    }

    private func complete(_ result: Result<ASAuthorization, Error>) {
        let attempt = pending
        pending = nil
        switch result {
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code == .canceled { return }
            showError("Apple sign-in could not finish. Try again, or use your email and password.")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let attempt else {
                showError("The sign-in request expired. Try again.")
                return
            }
            do {
                let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
                let payload = try attempt.result(identityToken: credential.identityToken,
                                                 authorizationCode: credential.authorizationCode,
                                                 state: credential.state, name: name)
                submit(payload)
            } catch { showError("Apple did not return a valid sign-in response. Try again.") }
        }
    }

    private func submit(_ payload: AppleAuthorizationResult) {
        error = nil
        submitting = true
        task = Task { @MainActor in
            defer { submitting = false }
            do { try await authorize(payload) }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                showError(AccountScreenError.message(error))
            }
        }
    }

    private func showError(_ message: String) {
        error = message
        errorFocused = true
    }
}

/// Ties a callback to one authorization sheet, including its raw nonce.
struct AppleAuthorizationAttempt {
    let nonce = AppleSignInNonce()
    let state = UUID().uuidString

    enum InvalidResponse: Error { case unmatchedRequest, missingToken }

    func result(identityToken: Data?, authorizationCode: Data?, state returnedState: String?,
                name: String?) throws -> AppleAuthorizationResult {
        guard returnedState == state else { throw InvalidResponse.unmatchedRequest }
        guard let identityToken, let token = String(data: identityToken, encoding: .utf8), !token.isEmpty else {
            throw InvalidResponse.missingToken
        }
        return AppleAuthorizationResult(identityToken: token, rawNonce: nonce.raw,
                                        authorizationCode: authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                                        name: name?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum AccountScreenError {
    static func message(_ error: Error) -> String {
        switch error {
        case ExerlyCore.APIError.linkRequired:
            "An account already uses this email. Sign in with your password, then connect Apple in Account settings."
        case ExerlyCore.APIError.linkConflict:
            "This Apple Account is connected to another Exerly account."
        case ExerlyCore.APIError.sessionExpired, ExerlyCore.APIError.notSignedIn:
            "Your session ended. Sign in again to continue."
        case ExerlyCore.APIError.server(_, let message): message
        case let error as URLError where error.code == .notConnectedToInternet || error.code == .cannotConnectToHost:
            "Could not reach Exerly. Check your connection and try again."
        default: (error as? LocalizedError)?.errorDescription ?? "This action could not finish. Try again."
        }
    }
}
