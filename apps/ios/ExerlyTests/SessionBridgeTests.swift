import XCTest
import SwiftData
import ExerlyCore
@testable import Exerly

/// The app's one session owner (`APIClient` with `AuthViewModel`) carrying
/// ExerlyCore's requests, Apple sign-in and the account actions. Uses
/// `StubURLProtocol` and `MemoryCredentials` from ProductionTests.swift.
@MainActor
final class SessionBridgeTests: XCTestCase {
    var defaults: UserDefaults!
    var keychain: MemoryCredentials!
    var api: APIClient!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "exerly.bridge.\(UUID().uuidString)")!
        keychain = MemoryCredentials()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        api = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: config), keychain: keychain, defaults: defaults)
    }

    override func tearDown() async throws {
        keychain.deleteToken()
        StubURLProtocol.handler = nil
        StubURLProtocol.responseDelay = nil
    }

    nonisolated static func token(_ account: String, session: String = "bridge-session") -> String {
        let claims = try! JSONSerialization.data(withJSONObject: ["sub": account, "sid": session, "email": "\(account)@example.test"],
                                                 options: [.sortedKeys])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).fixture"
    }

    nonisolated static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    nonisolated static func user(_ account: String) -> [String: Any] {
        ["_id": account, "email": "\(account)@example.test", "onboardingCompleted": true]
    }

    nonisolated static func bootstrap(_ account: String, password: Bool, apple: Bool) -> Data {
        json(["account": user(account), "account_id": account, "sign_in_methods": ["password": password, "apple": apple],
              "onboarding": ["complete": true, "needs_repair": false, "user": user(account)]])
    }

    func signedIn(_ account: String = "a", password: Bool = true, apple: Bool = false) async throws -> AuthViewModel {
        keychain.saveSession(token: Self.token(account), refreshToken: "refresh-1")
        StubURLProtocol.handler = { _ in (200, Self.bootstrap(account, password: password, apple: apple)) }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.checkAuth(useCached: false)
        XCTAssertEqual(auth.authState, .authenticated)
        return auth
    }

    // MARK: Password sign-in and recovery

    func testAWrongPasswordSaysSoInsteadOfSessionExpired() async throws {
        StubURLProtocol.handler = { _ in (401, Self.json(["message": "Invalid credentials"])) }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.login(email: "a@example.test", password: "wrong-password")
        XCTAssertEqual(auth.error, "That email and password don’t match. Try again, or reset your password.")
        XCTAssertNil(keychain.getToken())
        StubURLProtocol.handler = { _ in (429, Self.json(["message": "Too many sign-in attempts. Wait a few minutes and try again."])) }
        await auth.login(email: "a@example.test", password: "wrong-password")
        XCTAssertEqual(auth.error, "Too many sign-in attempts. Wait a few minutes and try again.")
    }

    func testPasswordResetSendsTheCodeWithoutASessionAndKeepsNone() async throws {
        var bodies: [String: [String: Any]] = [:]
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            bodies[request.url!.path] = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
            if request.url!.path == "/auth/password/forgot" {
                return (202, Self.json(["message": "If an Exerly account uses that email, we sent it a code."]))
            }
            return (400, Self.json(["message": "That code is wrong or has expired.", "details": ["code": "reset_code_invalid"]]))
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        let notice = try await auth.requestPasswordReset(email: "a@example.test")
        XCTAssertEqual(notice, "If an Exerly account uses that email, we sent it a code.")
        do {
            try await auth.resetPassword(email: "a@example.test", code: "ABCDEFGH", newPassword: "a-new-passphrase")
            XCTFail("Expected the wrong code")
        } catch { XCTAssertEqual(error.localizedDescription, "That code is wrong or has expired.") }
        XCTAssertEqual(bodies["/auth/password/forgot"]?["email"] as? String, "a@example.test")
        XCTAssertEqual(bodies["/auth/password/reset"]?["code"] as? String, "ABCDEFGH")
        XCTAssertEqual(bodies["/auth/password/reset"]?["newPassword"] as? String, "a-new-passphrase")
        XCTAssertNil(keychain.getToken())
        XCTAssertEqual(auth.authState, .loading)
    }

    // MARK: Apple sign-in

    func testAppleSignInBootstrapsLikeLoginAndReportsSignInMethods() async throws {
        var appleBody: [String: Any]?
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/auth/apple":
                appleBody = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (201, Self.json(["created": true, "token": Self.token("a"), "refreshToken": "apple-refresh", "user": Self.user("a")]))
            case "/api/bootstrap":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token("a"))")
                return (200, Self.bootstrap("a", password: false, apple: true))
            default:
                XCTFail("Unexpected \(request.url!.path)")
                return (404, Data())
            }
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.signInWithApple(identityToken: "apple-jwt", rawNonce: "raw-nonce-0123456789", name: "Synthetic Person")
        XCTAssertEqual(appleBody?["identityToken"] as? String, "apple-jwt")
        XCTAssertEqual(appleBody?["nonce"] as? String, "raw-nonce-0123456789")
        XCTAssertEqual(appleBody?["name"] as? String, "Synthetic Person")
        XCTAssertEqual(appleBody?["timezone"] as? String, TimeZone.current.identifier)
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertEqual(auth.currentUser?.id, "a")
        XCTAssertEqual(auth.signInMethods, SignInMethods(password: false, apple: true))
        XCTAssertEqual(keychain.getRefreshToken(), "apple-refresh")
        XCTAssertEqual(auth.accountAPI?.accountID, "a")
    }

    func testAppleSignInIntoAPasswordAccountExplainsHowToLink() async throws {
        let message = "An Exerly account already uses this email. Sign in with your password, then connect Apple in Settings."
        StubURLProtocol.handler = { _ in (409, Self.json(["message": message, "details": ["code": "link_required"]])) }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        auth.authState = .unauthenticated
        await auth.signInWithApple(identityToken: "apple-jwt", rawNonce: "raw-nonce-0123456789", name: nil)
        XCTAssertEqual(auth.error, message)
        XCTAssertEqual(auth.authState, .unauthenticated)
        XCTAssertNil(keychain.getToken())
    }

    // MARK: ExerlyCore through the session owner

    func testExerlyCoreRequestsRefreshOnceAndShareTheRotatedSession() async throws {
        keychain.saveSession(token: Self.token("a", session: "one"), refreshToken: "refresh-1")
        var authorizations: [String] = []
        StubURLProtocol.handler = { request in
            if request.url!.path == "/auth/token" {
                return (200, Self.json(["token": Self.token("a", session: "two"), "refreshToken": "refresh-2", "user": Self.user("a")]))
            }
            authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return authorizations.count == 1
                ? (401, Self.json(["message": "Expired"]))
                : (200, Self.json(["changes": [], "cursor": 7, "has_more": false]))
        }
        let page = try await AccountAPI(accountID: "a", transport: api).changes(after: 0, limit: 500)
        XCTAssertEqual(page.cursor, 7)
        XCTAssertEqual(authorizations, ["Bearer \(Self.token("a", session: "one"))", "Bearer \(Self.token("a", session: "two"))"])
        XCTAssertEqual(keychain.getToken(), Self.token("a", session: "two"))
        XCTAssertEqual(keychain.getRefreshToken(), "refresh-2")
    }

    func testAConflictReachesExerlyCoreWithTheServersVersion() async throws {
        keychain.saveSession(token: Self.token("a"), refreshToken: "refresh-1")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "push-key-1")
            return (409, Self.json(["message": "Changed", "details": ["document": [
                "kind": "workout_session", "id": "S1", "revision": 3, "deleted": false, "payload": ["id": "S1", "notes": "remote"],
            ]]]))
        }
        let result = try await AccountAPI(accountID: "a", transport: api)
            .putDocument(kind: "workout_session", id: "S1", payload: Data(#"{"id":"S1"}"#.utf8), baseRevision: 2, idempotencyKey: "push-key-1")
        guard case .conflict(let remote?) = result else { return XCTFail("Expected a conflict, got \(result)") }
        XCTAssertEqual(remote.revision, 3)
    }

    func testAnotherAccountsSessionIsRefusedBeforeAndDuringARequest() async throws {
        keychain.saveSession(token: Self.token("a"), refreshToken: "refresh-1")
        var requests = 0
        StubURLProtocol.handler = { _ in
            requests += 1
            return (200, Self.json(["changes": [], "cursor": 0, "has_more": false]))
        }
        do {
            _ = try await AccountAPI(accountID: "b", transport: api).changes(after: 0, limit: 500)
            XCTFail("Expected accountChanged")
        } catch ExerlyCore.APIError.accountChanged {}
        XCTAssertEqual(requests, 0)

        StubURLProtocol.responseDelay = { _ in 0.3 }
        let inFlight = Task { try await AccountAPI(accountID: "a", transport: self.api).changes(after: 0, limit: 500) }
        try await Task.sleep(for: .milliseconds(100))
        keychain.saveSession(token: Self.token("b"), refreshToken: "refresh-b")
        do {
            _ = try await inFlight.value
            XCTFail("Expected accountChanged")
        } catch ExerlyCore.APIError.accountChanged {}
    }

    func testARefusedRefreshBecomesSessionExpired() async throws {
        keychain.saveSession(token: Self.token("a"), refreshToken: "refresh-1")
        StubURLProtocol.handler = { _ in (401, Self.json(["message": "Session has been revoked"])) }
        do {
            _ = try await AccountAPI(accountID: "a", transport: api).changes(after: 0, limit: 500)
            XCTFail("Expected sessionExpired")
        } catch ExerlyCore.APIError.sessionExpired {}
    }

    // MARK: Account actions

    func testLinkingAndUnlinkingAppleUpdatesSignInMethods() async throws {
        let auth = try await signedIn(password: true, apple: false)
        XCTAssertEqual(auth.signInMethods, SignInMethods(password: true, apple: false))
        var calls: [String] = []
        StubURLProtocol.handler = { request in
            calls.append("\(request.httpMethod!) \(request.url!.path)")
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
                XCTAssertEqual(body?["identityToken"] as? String, "apple-jwt")
                XCTAssertEqual(body?["nonce"] as? String, "raw-nonce")
                return (201, Self.json(["provider": "apple", "connected": true]))
            }
            return (200, Self.json(["provider": "apple", "connected": false]))
        }
        try await auth.linkApple(identityToken: "apple-jwt", rawNonce: "raw-nonce")
        XCTAssertEqual(auth.signInMethods?.apple, true)
        try await auth.unlinkApple()
        XCTAssertEqual(auth.signInMethods?.apple, false)
        XCTAssertEqual(calls, ["POST /api/account/identities/apple", "DELETE /api/account/identities/apple"])
    }

    func testAnAppleIDOnAnotherAccountIsATypedError() async throws {
        let auth = try await signedIn()
        StubURLProtocol.handler = { _ in (409, Self.json(["message": "This Apple ID is connected to another Exerly account"])) }
        do {
            try await auth.linkApple(identityToken: "apple-jwt", rawNonce: "raw-nonce")
            XCTFail("Expected linkConflict")
        } catch ExerlyCore.APIError.linkConflict {}
        XCTAssertEqual(auth.signInMethods?.apple, false)
    }

    func testExportReturnsTheServersJSON() async throws {
        let auth = try await signedIn()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/api/export")
            return (200, Self.json(["version": 3, "documents": []]))
        }
        let export = try JSONSerialization.jsonObject(with: try await auth.exportAccount()) as? [String: Any]
        XCTAssertEqual(export?["version"] as? Int, 3)
    }

    func testAWrongPasswordKeepsTheAccountAndTheSession() async throws {
        let auth = try await signedIn()
        StubURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any] ?? [:]
            XCTAssertEqual(body["password"] as? String, "typed-wrong")
            return (403, Self.json(["message": "That password is incorrect.", "details": ["code": "wrong_password"]]))
        }
        do {
            _ = try await auth.deleteAccount(confirmation: .password("typed-wrong"))
            XCTFail("Expected the wrong password")
        } catch ExerlyCore.APIError.wrongPassword {}
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertNotNil(keychain.getToken())
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, [])
    }

    func testDeletionAsksForAppleThenSignsOutAndForgetsTheAccount() async throws {
        let auth = try await signedIn(apple: true)
        let token = try XCTUnwrap(keychain.getToken())
        XCTAssertNotNil(defaults.data(forKey: APIClient.accountCacheKey(token)))
        var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url!.path, "/api/account")
            let body = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any] ?? [:]
            bodies.append(body)
            return body["appleAuthorizationCode"] == nil
                ? (400, Self.json(["message": "Sign in with Apple again to confirm deletion",
                                   "details": ["code": "apple_reauthorization_required"]]))
                : (200, Self.json(["deleted": true, "apple_revoked": true, "removed": [:]]))
        }
        let first = try await auth.deleteAccount(confirmation: .password("synthetic-password"))
        XCTAssertEqual(first, .appleReauthorizationRequired)
        XCTAssertEqual(auth.authState, .authenticated)
        let second = try await auth.deleteAccount(confirmation: .apple(identityToken: "apple-jwt", rawNonce: "raw-nonce",
                                                                        authorizationCode: "apple-code"))
        XCTAssertEqual(second, .deleted)
        XCTAssertEqual(bodies.map { $0["confirm"] as? Bool }, [true, true])
        XCTAssertEqual(bodies.first?["password"] as? String, "synthetic-password")
        XCTAssertEqual(bodies.last?["identityToken"] as? String, "apple-jwt")
        XCTAssertEqual(bodies.last?["nonce"] as? String, "raw-nonce")
        XCTAssertEqual(bodies.last?["appleAuthorizationCode"] as? String, "apple-code")
        XCTAssertEqual(auth.authState, .unauthenticated)
        XCTAssertNil(auth.currentUser)
        XCTAssertNil(auth.signInMethods)
        XCTAssertNil(auth.accountAPI)
        XCTAssertNil(keychain.getToken())
        XCTAssertNil(defaults.data(forKey: APIClient.accountCacheKey(token)))
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, ["a"])
        auth.finishLocalCleanup(for: "a")
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, [])
    }

    nonisolated static let deletedBody = json(["message": "This account was deleted.", "details": ["code": "account_deleted"]])

    func testADeletionWhoseResponseWasLostIsConfirmedByTheServer() async throws {
        let auth = try await signedIn()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { throw URLError(.networkConnectionLost) }
            XCTAssertEqual(request.url!.path, "/api/bootstrap")
            return (401, Self.deletedBody)
        }
        let outcome = try await auth.deleteAccount(confirmation: .password("synthetic-password"))
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(auth.authState, .unauthenticated)
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, ["a"])
    }

    func testADeletionThatDidNotHappenStaysAnError() async throws {
        let auth = try await signedIn()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { throw URLError(.networkConnectionLost) }
            return (200, Self.bootstrap("a", password: true, apple: false))
        }
        do {
            _ = try await auth.deleteAccount(confirmation: .password("synthetic-password"))
            XCTFail("Expected the network error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, [])
    }

    func testAnAccountDeletedElsewhereIsSignedOutAndQueuedForCleanup() async throws {
        let auth = try await signedIn()
        StubURLProtocol.handler = { _ in (401, Self.deletedBody) }
        await auth.checkAuth(useCached: false)
        XCTAssertEqual(auth.authState, .unauthenticated)
        XCTAssertNil(keychain.getToken())
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, ["a"])
        // A relaunch before the cleanup finished still knows.
        let relaunched = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        XCTAssertEqual(relaunched.accountsAwaitingLocalCleanup, ["a"])
    }

    func testExerlyCoreHearsThatTheAccountWasDeleted() async throws {
        keychain.saveSession(token: Self.token("a"), refreshToken: "refresh-1")
        var refreshes = 0
        StubURLProtocol.handler = { request in
            if request.url!.path == "/auth/token" { refreshes += 1 }
            return (401, Self.deletedBody)
        }
        do {
            _ = try await AccountAPI(accountID: "a", transport: api).changes(after: 0, limit: 500)
            XCTFail("Expected accountDeleted")
        } catch ExerlyCore.APIError.accountDeleted {}
        XCTAssertEqual(refreshes, 0, "No refresh can bring a deleted account back")
    }

    func testPurgeRemovesOnlyTheDeletedAccountsOfflineData() throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = Exerly.SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false)
        engine.configure(container: container, accountID: "a")
        let context = ModelContext(container)
        for account in ["a", "b"] {
            let owner = "\(api.storageNamespace):\(account)"
            context.insert(SyncedResource(accountID: owner, kind: "food", entityID: "f-\(account)", payload: Data("{}".utf8)))
            context.insert(PendingMutation(accountID: owner, entityID: "f-\(account)", kind: "food", method: "POST",
                                           endpoint: "/api/food", payload: Data("{}".utf8), baseRevision: nil))
            context.insert(CachedAPIResponse(accountID: owner, path: "/api/diary", payload: Data("{}".utf8)))
            context.insert(SyncCheckpoint(accountID: owner))
        }
        try context.save()
        engine.refreshCounts()
        XCTAssertEqual(engine.pendingCount, 1)

        try engine.purge(accountID: "a")
        XCTAssertFalse(engine.isConfigured(for: "a"))
        XCTAssertEqual(engine.pendingCount, 0)
        let check = ModelContext(container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<SyncedResource>()).map(\.entityID), ["f-b"])
        XCTAssertEqual(try check.fetch(FetchDescriptor<PendingMutation>()).map(\.entityID), ["f-b"])
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<CachedAPIResponse>()), 1)
        XCTAssertEqual(try check.fetch(FetchDescriptor<SyncCheckpoint>()).map(\.accountID), ["\(api.storageNamespace):b"])
    }

    /// URLProtocol sees uploads as a stream.
    nonisolated static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
