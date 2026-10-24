import ExerlyCore
import Foundation
import SwiftUI

/// Preferences set in one tap away from Your details (what Today leads with,
/// the water goal), kept on this iPhone the moment they change, for each
/// account, and sent on their own: only the fields changed, against the
/// account's latest revision, one send at a time with newer changes queued
/// behind it. Offline they wait and go once a request gets through. Your
/// details' draft and its conflict review are never read or written here.
/// One queue writes an account's storage at a time: a session's queue stops
/// when the session ends, and the account's next session sends what it held.
@MainActor
final class QuickPreferences: ObservableObject {
    struct Queue: Codable, Equatable {
        /// Changed since the send in flight began, the newest value of each field.
        var waiting: [String: JSONValue] = [:]
        /// Sent and not yet acknowledged, replayed exactly after a lost response.
        var sending: Sending?
    }
    struct Sending: Codable, Equatable {
        var id: String
        var baseRevision: Int?
        var changes: [String: JSONValue]
    }

    @Published private(set) var queue: Queue
    /// A send failed for want of a connection; it's retried.
    @Published private(set) var isWaitingForConnection = false
    @Published private(set) var error: String?
    let accountID: String
    let storageKey: String
    private let api: APIClient
    private let defaults: UserDefaults
    private let onAccepted: (PreferencesSnapshot) -> Void
    private let isCurrent: () -> Bool
    private let retryDelays: [Duration]
    private var flushing: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0
    private var stopped = false

    static let standardRetryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(20)]

    init(accountID: String, api: APIClient = .shared, defaults: UserDefaults = .standard,
         retryDelays: [Duration] = standardRetryDelays, isCurrent: @escaping () -> Bool = { true },
         onAccepted: @escaping (PreferencesSnapshot) -> Void = { _ in }) {
        self.accountID = accountID
        self.api = api
        self.defaults = defaults
        self.onAccepted = onAccepted
        self.isCurrent = isCurrent
        self.retryDelays = retryDelays
        storageKey = "preferences.quick.v1.\(api.storageNamespace).\(accountID)"
        queue = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Queue.self, from: $0) } ?? Queue()
        if hasUnsent { flush() }
    }

    private static var instances: [String: (sessionID: UUID, quick: QuickPreferences)] = [:]

    /// The signed-in account's queue, shared by every control that sets one
    /// of these preferences; what the server accepts reaches `auth`. Queues
    /// from a session that has ended stop here, before this one reads the
    /// account's storage.
    static func signedIn(accountID: String, auth: AuthViewModel, api: APIClient = .shared,
                         defaults: UserDefaults = .standard,
                         retryDelays: [Duration] = standardRetryDelays) -> QuickPreferences {
        let sessionID = auth.sessionID
        let key = "\(api.storageNamespace).\(accountID)"
        if let existing = instances[key], existing.sessionID == sessionID { return existing.quick }
        for (other, entry) in instances where entry.sessionID != sessionID {
            entry.quick.stop()
            instances[other] = nil
        }
        let made = QuickPreferences(accountID: accountID, api: api, defaults: defaults, retryDelays: retryDelays,
                                    isCurrent: { [weak auth] in auth?.sessionID == sessionID },
                                    onAccepted: { [weak auth] snapshot in
                                        auth?.acceptPreferences(snapshot.user, accountID: accountID, sessionID: sessionID)
                                        NotificationService.shared.accept(snapshot)
                                    })
        instances[key] = (sessionID, made)
        return made
    }

    /// Under a control whose change waits for a connection.
    static let waitingNote = "Saved on this iPhone. It syncs when you're back online."

    var hasUnsent: Bool { queue.sending != nil || !queue.waiting.isEmpty }

    /// This iPhone's value for `key` that the server may not have yet.
    func value(_ key: String) -> JSONValue? { queue.waiting[key] ?? queue.sending?.changes[key] }

    /// Whether `key` changed here and hasn't reached the server.
    func isUnsent(_ key: String) -> Bool { value(key) != nil }

    /// What Today leads with, this iPhone's choice first.
    func leadsWithEaten(_ user: UserDTO?) -> Bool {
        if case .string(let display)? = value("nutritionDisplay") { return display == "consumed" }
        return user?.leadsWithEaten ?? false
    }

    /// The daily water goal in millilitres, this iPhone's choice first.
    func waterGoal(_ user: UserDTO?) -> Int? {
        switch value("waterGoalMl") {
        case .number(let milliliters)?: Int(milliliters)
        case .null?: nil
        default: user?.waterGoalMl
        }
    }

    /// Keeps `value` for `key` on this iPhone at once and sends it.
    func set(_ key: String, _ value: JSONValue) {
        queue.waiting[key] = value
        persist()
        error = nil
        flush()
    }

    /// Sends what's queued, unless a send is already running; that one
    /// picks up whatever was queued behind it.
    func flush() {
        retry?.cancel()
        retry = nil
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            await self?.send()
            self?.flushing = nil
        }
    }

    /// Waits for the send running now, for tests.
    func waitForSend() async { await flushing?.value }

    /// Ends this queue for good: it no longer sends, retries or saves.
    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        flushing?.cancel()
        isWaitingForConnection = false
    }

    /// False once stopped or once the session it belongs to has ended
    /// (signed out, or signed in again).
    private var isActive: Bool { !stopped && isCurrent() }

    private func persist() {
        guard isActive else { return }
        if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: storageKey) }
    }

    private func send() async {
        while isActive {
            if queue.sending == nil {
                guard !queue.waiting.isEmpty else { return }
                queue.sending = Sending(id: UUID().uuidString, baseRevision: nil, changes: queue.waiting)
                queue.waiting = [:]
                persist()
            }
            guard let sending = queue.sending else { return }
            do {
                let result = try await deliver(sending)
                // A replay after a lost response answers with the revision it made,
                // which another device may have passed since: read the account as it
                // is now. Until that succeeds the send stays queued; sent again, it replays.
                let current = try await latest()
                // Accepted: anything changed meanwhile is still waiting, and goes next.
                queue.sending = nil
                persist()
                failures = 0
                isWaitingForConnection = false
                error = nil
                onAccepted(current.revision >= result.revision ? current : result)
            } catch APIError.serverError(400, let message) {
                guard isActive else { return }
                // The server refuses these values: nothing to retry.
                queue.sending = nil
                persist()
                error = message
            } catch is CancellationError {
                return
            } catch APIError.unauthorized {
                return
            } catch {
                guard isActive else { return }
                isWaitingForConnection = true
                scheduleRetry()
                return
            }
        }
    }

    /// The account's preferences now, unless this queue's session has ended.
    private func latest() async throws -> PreferencesSnapshot {
        guard isActive else { throw CancellationError() }
        let remote: PreferencesSnapshot = try await api.request("GET", path: "/api/preferences", expectedAccountID: accountID)
        guard remote.accountID == accountID, isActive else { throw CancellationError() }
        return remote
    }

    /// Sends `sending`: as it was first sent after a lost response, so the
    /// server replays its answer, else against the latest revision.
    private func deliver(_ sending: Sending) async throws -> PreferencesSnapshot {
        var sending = sending
        for _ in 0..<3 {
            if sending.baseRevision == nil {
                sending.baseRevision = try await latest().revision
                queue.sending = sending
                persist()
            }
            guard isActive else { throw CancellationError() }
            do {
                let result: PreferencesSnapshot = try await api.request(
                    "PATCH", path: "/api/preferences",
                    body: PreferenceMutation(baseRevision: sending.baseRevision ?? 0, changes: sending.changes),
                    operationID: sending.id, expectedAccountID: accountID)
                guard isActive else { throw CancellationError() }
                return result
            } catch APIError.serverError(409, _) {
                guard isActive else { throw CancellationError() }
                // Another device saved first: only these fields are sent, so send them again on top of its save.
                sending = Sending(id: UUID().uuidString, baseRevision: nil, changes: sending.changes)
                queue.sending = sending
                persist()
            }
        }
        throw APIError.serverError(409, "Preferences kept changing on another device.")
    }

    private func scheduleRetry() {
        let delay = retryDelays[min(failures, retryDelays.count - 1)]
        failures += 1
        retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
    }
}

/// Shows `content` with `quick`, redrawn as it changes, and sends what it
/// holds when the app comes back to the front or the connection returns.
struct QuickPreferencesReader<Content: View>: View {
    @ObservedObject var quick: QuickPreferences
    @ViewBuilder var content: (QuickPreferences) -> Content
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content(quick)
            .onChange(of: scenePhase) { _, phase in if phase == .active, quick.hasUnsent { quick.flush() } }
            .onChange(of: sync.isOffline) { _, offline in if !offline, quick.hasUnsent { quick.flush() } }
    }
}
