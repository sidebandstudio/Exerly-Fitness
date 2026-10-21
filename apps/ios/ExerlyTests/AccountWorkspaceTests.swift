import XCTest
import ExerlyCore
@testable import Exerly

@MainActor
final class AccountWorkspaceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var namespace: String!
    private var credentials: MemoryCredentials!
    private var api: APIClient!
    private var auth: AuthViewModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        namespace = "exerly.workspace.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: namespace)!
        credentials = MemoryCredentials()
        credentials.saveSession(token: SessionBridgeTests.token("account-a"), refreshToken: "fixture-refresh")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        api = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: configuration),
                            keychain: credentials, defaults: defaults)
        auth = AuthViewModel(api: api, keychain: credentials, defaults: defaults,
                             automaticallyCheck: false, onSessionInvalidated: {})
        StubURLProtocol.handler = { _ in (200, SessionBridgeTests.bootstrap("account-a", password: true, apple: false)) }
        await auth.checkAuth(useCached: false)
    }

    override func tearDown() async throws {
        StubURLProtocol.handler = nil
        StubURLProtocol.responseDelay = nil
        defaults.removePersistentDomain(forName: namespace)
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace(pending: @escaping @MainActor (String) throws -> [AccountExport.PendingRow] = { _ in [] },
                           purge: @escaping @MainActor (String) throws -> Void = { _ in }) -> AppAccountWorkspace {
        let directory = root!
        return AppAccountWorkspace(open: { try await TrainingWorkspace.open(accountID: $0.accountID, root: directory, api: $0) },
            deleteTraining: { try TrainingWorkspace.deleteStorage(accountID: $0, root: directory) },
            purgeLegacy: purge, pendingLegacy: pending)
    }

    /// An account's data that can't be opened isn't opened again by every
    /// later request for it, only when someone asks to try again.
    func testAFailedOpenIsKeptUntilRetried() async throws {
        struct Unreadable: Error {}
        var attempts = 0
        let owner = AppAccountWorkspace(open: { _ in attempts += 1; throw Unreadable() },
            deleteTraining: { _ in }, purgeLegacy: { _ in }, pendingLegacy: { _ in [] })
        await owner.configure(auth.accountAPI)
        await owner.configure(auth.accountAPI)
        XCTAssertEqual(attempts, 1, "The failure stands; the work isn't repeated")
        XCTAssertNotNil(owner.openingError)
        XCTAssertNil(owner.training)
        await owner.configure(auth.accountAPI, retrying: true)
        XCTAssertEqual(attempts, 2, "Try again opens it again")
    }

    /// An account's history is read off the main thread, so a long one
    /// never holds up the screen while it opens.
    func testHistoryIsReadOffTheMainThread() async throws {
        struct Read: Error { let onMain: Bool }
        do {
            _ = try await TrainingWorkspace.open(accountID: "account-a", root: root, api: nil,
                                                 read: { _ in throw Read(onMain: Thread.isMainThread) })
            XCTFail("The history was read")
        } catch let read as Read {
            XCTAssertFalse(read.onMain, "Read off the main thread")
        }
    }

    func testSignOutQuiescesSyncAndKeepsTrainingForTheSameAccount() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let training = try XCTUnwrap(owner.training)
        let originalEngine = try XCTUnwrap(training.sync)
        try training.store.startSession(name: "Saved locally", bodyweight: nil)
        let revoked = expectation(description: "The signed-out session is revoked")
        StubURLProtocol.handler = { _ in
            revoked.fulfill()
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        await owner.signOut(auth: auth)
        await fulfillment(of: [revoked], timeout: 2)
        XCTAssertNil(owner.training)
        XCTAssertThrowsError(try training.store.updateActiveSession { $0.notes = "A stale screen tried to save" })
        XCTAssertEqual(auth.authState, .unauthenticated)
        do { try await originalEngine.sync(); XCTFail("A stopped engine must not run") }
        catch is CancellationError { }
        let restored = try TrainingWorkspace(accountID: "account-a", root: root)
        XCTAssertEqual(restored.store.activeSession?.name, "Saved locally")
        XCTAssertNil(try TrainingWorkspace(accountID: "account-b", root: root).store.activeSession)
    }

    func testReconfiguringAwayClosesAStoreStillHeldByAScreen() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let retained = try XCTUnwrap(owner.training)
        try retained.store.startSession(name: "Saved before switch", bodyweight: nil)
        await owner.configure(nil)
        XCTAssertThrowsError(try retained.store.updateActiveSession { $0.notes = "Late edit" })
        let reopened = try TrainingWorkspace(accountID: "account-a", root: root)
        XCTAssertEqual(reopened.store.activeSession?.notes, "")
    }

    func testCancelledAccountTransitionCanReopenTheSameAccount() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let original = try XCTUnwrap(owner.training)
        try original.store.startSession(name: "Keep through transition", bodyweight: nil)
        let transition = Task { @MainActor in await owner.configure(nil) }
        transition.cancel()
        await transition.value
        await owner.configure(auth.accountAPI)
        let reopened = try XCTUnwrap(owner.training)
        try reopened.store.updateActiveSession { $0.notes = "Still editable" }
        XCTAssertEqual(reopened.store.activeSession?.name, "Keep through transition")
        XCTAssertEqual(reopened.store.activeSession?.notes, "Still editable")
        XCTAssertThrowsError(try original.store.updateActiveSession { $0.notes = "Late edit" })
    }

    func testAccountActionsIncludePendingEntriesInOnlineAndOfflineExports() async throws {
        let food = Data(#"{"client_id":"local-food","name":"Saved offline","calories":120}"#.utf8)
        let owner = workspace(pending: { accountID in
            XCTAssertEqual(accountID, "account-a")
            return [AccountExport.PendingRow(table: "food", clientID: "local-food", serverID: nil, row: food)]
        })
        await owner.configure(auth.accountAPI)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/export")
            return (200, Data(#"{"documents":[],"food":[]}"#.utf8))
        }
        let actions = owner.actions(auth: auth, accountID: "account-a")
        let online = try await actions.exportAccount()
        let offline = try XCTUnwrap(actions.exportDeviceData)()
        for data in [online, offline] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rows = try XCTUnwrap(json["food"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["name"] as? String, "Saved offline")
            XCTAssertEqual(rows.first?["pending_sync"] as? Bool, true)
        }
    }

    func testFailedDeleteKeepsTheSessionAndStartsAFreshSyncEngine() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let training = try XCTUnwrap(owner.training)
        let oldEngine = try XCTUnwrap(training.sync)
        try training.store.startSession(name: "Keep me", bodyweight: nil)
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do { try await owner.deleteAccount(auth: auth, confirmation: .password("synthetic-password")); XCTFail("Expected offline error") }
        catch { XCTAssertNotNil(error as? URLError) }
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertEqual(owner.training?.store.activeSession?.name, "Keep me")
        XCTAssertFalse(owner.training?.sync === oldEngine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: training.url.path))
        XCTAssertTrue(auth.accountsAwaitingLocalCleanup.isEmpty)
    }

    func testConfirmedDeleteCleansOnlyThatAccountAndRetriesFailedLocalCleanupAfterRelaunch() async throws {
        var attempts = 0
        let owner = workspace(purge: { id in
            XCTAssertEqual(id, "account-a")
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
        })
        await owner.configure(auth.accountAPI)
        let original = try XCTUnwrap(owner.training)
        try original.store.startSession(name: "Delete me", bodyweight: nil)
        let other = try TrainingWorkspace(accountID: "account-b", root: root)
        try other.store.startSession(name: "Keep other account", bodyweight: nil)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/account")
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        try await owner.deleteAccount(auth: auth, confirmation: .password("synthetic-password"))
        XCTAssertEqual(auth.authState, .unauthenticated)
        XCTAssertNil(owner.training)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.url.path))
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, ["account-a"])
        XCTAssertNotNil(owner.cleanupError)
        let relaunched = workspace(purge: { id in XCTAssertEqual(id, "account-a") })
        let relaunchedAuth = AuthViewModel(api: api, keychain: credentials, defaults: defaults,
                                           automaticallyCheck: false, onSessionInvalidated: {})
        XCTAssertEqual(relaunchedAuth.accountsAwaitingLocalCleanup, ["account-a"])
        await relaunched.retryCleanup(auth: relaunchedAuth)
        XCTAssertTrue(relaunchedAuth.accountsAwaitingLocalCleanup.isEmpty)
        XCTAssertNil(relaunched.cleanupError)
        XCTAssertEqual(try TrainingWorkspace(accountID: "account-b", root: root).store.activeSession?.name,
                       "Keep other account")
    }

    func testAppleReauthorizationRestartsSyncWithoutDeletingLocalFiles() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let training = try XCTUnwrap(owner.training)
        let oldEngine = training.sync
        StubURLProtocol.handler = { _ in
            (400, Data(#"{"message":"Confirm with Apple","details":{"code":"apple_reauthorization_required"}}"#.utf8))
        }
        do { try await owner.deleteAccount(auth: auth, confirmation: .password("synthetic-password")); XCTFail("Expected Apple authorization") }
        catch ExerlyCore.APIError.appleReauthorizationRequired { }
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertFalse(training.sync === oldEngine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: training.url.path))
        XCTAssertTrue(auth.accountsAwaitingLocalCleanup.isEmpty)
    }

    func testDeletionOnAnotherDeviceStopsThisStoreBeforeCleanup() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let training = try XCTUnwrap(owner.training)
        let engine = try XCTUnwrap(training.sync)
        try training.store.startSession(name: "Removed elsewhere", bodyweight: nil)
        StubURLProtocol.handler = { _ in (401, SessionBridgeTests.deletedBody) }
        await auth.checkAuth(useCached: false)
        XCTAssertEqual(auth.accountsAwaitingLocalCleanup, ["account-a"])
        await owner.retryCleanup(auth: auth)
        XCTAssertNil(owner.training)
        XCTAssertFalse(FileManager.default.fileExists(atPath: training.url.path))
        XCTAssertTrue(auth.accountsAwaitingLocalCleanup.isEmpty)
        do { try await engine.sync(); XCTFail("Deleted stores must stay stopped") }
        catch is CancellationError { }
    }

    func testWorkspaceExportsUnsyncedTrainingOnlineAndLabelsADeviceOnlyExport() async throws {
        let owner = workspace()
        await owner.configure(auth.accountAPI)
        let training = try XCTUnwrap(owner.training)
        try training.store.startSession(name: "Not uploaded", bodyweight: nil)
        let online = try training.export(server: Data(#"{"account":{"name":"Morgan"},"documents":[]}"#.utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: online) as? [String: Any])
        XCTAssertEqual((json["account"] as? [String: Any])?["name"] as? String, "Morgan")
        let document = try XCTUnwrap((json["documents"] as? [[String: Any]])?.first)
        XCTAssertEqual(document["pending_sync"] as? Bool, true)
        XCTAssertEqual((document["payload"] as? [String: Any])?["name"] as? String, "Not uploaded")
        let offline = try XCTUnwrap(JSONSerialization.jsonObject(with: training.export(server: nil)) as? [String: Any])
        XCTAssertEqual(offline["source"] as? String, "device")
        XCTAssertNil(offline["account"])
        XCTAssertNotNil(offline["note"])
    }

    func testSetupWeightIsRecordedOnceWithTheLegacyImportsID() async throws {
        let workspace = try TrainingWorkspace(accountID: "account-a", root: root)
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-09T02:30:00Z"))
        SetupWeighIn.remember(accountID: "account-a", kilograms: 81.4, timeZone: zone.identifier,
                              namespace: namespace, defaults: defaults, now: now)
        await SetupWeighIn.recordIfPending(workspace, namespace: namespace, defaults: defaults)
        let day = try XCTUnwrap(LocalDate("2026-10-08"), "The account's day, not UTC's")
        XCTAssertEqual(workspace.nutrition.weights.map(\.id), [NutritionStore.legacyWeightID(accountID: "account-a", date: day)])
        XCTAssertEqual(workspace.nutrition.weights.first?.weight.kilograms ?? 0, 81.4, accuracy: 0.0001)
        await SetupWeighIn.recordIfPending(workspace, namespace: namespace, defaults: defaults)
        let serverCopy = try workspace.nutrition.importLegacyWeights([LegacyWeighIn(date: day, kilograms: 81.4)],
                                                                    accountID: "account-a", timeZone: zone)
        XCTAssertEqual(serverCopy, 0, "Today's import of the server's copy adds nothing")
        XCTAssertEqual(workspace.nutrition.weights.count, 1)
        await workspace.close()
    }
}
