import ExerlyCore
import Foundation
import SwiftUI

/// Preferences set in one tap away from Your details (what Today leads with,
/// the water goal), kept on this iPhone the moment they change, for each
/// account, and sent on their own: only the fields changed, against the
/// account's latest revision, one send at a time with newer changes queued
/// behind it. Offline they wait and go once a request gets through. Your
/// details' draft and its conflict review are never read or written here.
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
    private let retryDelays: [Duration]
    private var flushing: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0

    init(accountID: String, api: APIClient = .shared, defaults: UserDefaults = .standard,
         retryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(20)],
         onAccepted: @escaping (PreferencesSnapshot) -> Void = { _ in }) {
        self.accountID = accountID
        self.api = api
        self.defaults = defaults
        self.onAccepted = onAccepted
        self.retryDelays = retryDelays
        storageKey = "preferences.quick.v1.\(api.storageNamespace).\(accountID)"
        queue = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Queue.self, from: $0) } ?? Queue()
        if hasUnsent { flush() }
    }

    private static var instances: [String: QuickPreferences] = [:]

    /// The signed-in account's queue, shared by every control that sets one
    /// of these preferences; what the server accepts reaches `auth`.
    static func signedIn(accountID: String, auth: AuthViewModel) -> QuickPreferences {
        let sessionID = auth.sessionID
        let key = "\(APIClient.shared.storageNamespace).\(accountID).\(sessionID)"
        if let existing = instances[key] { return existing }
        let made = QuickPreferences(accountID: accountID) { [weak auth] snapshot in
            auth?.acceptPreferences(snapshot.user, accountID: accountID, sessionID: sessionID)
            NotificationService.shared.accept(snapshot)
        }
        instances[key] = made
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

    private func persist() {
        if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: storageKey) }
    }

    private func send() async {
        while true {
            if queue.sending == nil {
                guard !queue.waiting.isEmpty else { return }
                queue.sending = Sending(id: UUID().uuidString, baseRevision: nil, changes: queue.waiting)
                queue.waiting = [:]
                persist()
            }
            guard let sending = queue.sending else { return }
            do {
                let result = try await deliver(sending)
                // Accepted: anything changed meanwhile is still waiting, and goes next.
                queue.sending = nil
                persist()
                failures = 0
                isWaitingForConnection = false
                error = nil
                onAccepted(result)
            } catch APIError.serverError(400, let message) {
                // The server refuses these values: nothing to retry.
                queue.sending = nil
                persist()
                error = message
            } catch is CancellationError {
                return
            } catch APIError.unauthorized {
                return
            } catch {
                isWaitingForConnection = true
                scheduleRetry()
                return
            }
        }
    }

    /// Sends `sending`: as it was first sent after a lost response, so the
    /// server replays its answer, else against the latest revision.
    private func deliver(_ sending: Sending) async throws -> PreferencesSnapshot {
        var sending = sending
        for _ in 0..<3 {
            if sending.baseRevision == nil {
                let remote: PreferencesSnapshot = try await api.request("GET", path: "/api/preferences", expectedAccountID: accountID)
                guard remote.accountID == accountID else { throw CancellationError() }
                sending.baseRevision = remote.revision
                queue.sending = sending
                persist()
            }
            do {
                return try await api.request("PATCH", path: "/api/preferences",
                                             body: PreferenceMutation(baseRevision: sending.baseRevision ?? 0, changes: sending.changes),
                                             operationID: sending.id, expectedAccountID: accountID)
            } catch APIError.serverError(409, _) {
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
