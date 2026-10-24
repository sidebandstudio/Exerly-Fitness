#if DEBUG
import ExerlyCore
import SwiftUI

/// UI-only synthetic actions. Never compiled into a release build.
struct AccountControlsFixtureView: View {
    let mode: String
    @State private var deleted = false
    @State private var connected = false

    var body: some View {
        NavigationStack {
            if deleted {
                ContentUnavailableView("Account deleted", systemImage: "person.crop.circle.badge.checkmark")
            } else {
                AccountManagementView(accountID: "synthetic-account-controls", email: "morgan@example.test", actions: actions)
            }
        }
    }

    private var methods: AccountSignInMethods {
        AccountSignInMethods(appleConnected: connected || mode == "apple-only", hasPassword: mode != "apple-only")
    }

    private var actions: AccountManagementActions {
        AccountManagementActions(
            signInMethods: { methods },
            connectApple: { _, confirmation in
                guard confirmation == .password("Synthetic-Password-1") else { throw ExerlyCore.APIError.wrongPassword }
                connected = true
                return methods
            },
            disconnectApple: { password in
                guard password == "Synthetic-Password-1" else { throw ExerlyCore.APIError.wrongPassword }
                connected = false
                return methods
            },
            exportAccount: { Data(#"{"account":{"name":"Morgan Example"},"workouts":[]}"#.utf8) },
            deleteAccount: { confirmation in
                if mode == "delete-error" { throw URLError(.cannotConnectToHost) }
                if case .password(let password, _) = confirmation, password != "Synthetic-Password-1" {
                    throw ExerlyCore.APIError.wrongPassword
                }
                deleted = true
            }
        )
    }
}
#endif
