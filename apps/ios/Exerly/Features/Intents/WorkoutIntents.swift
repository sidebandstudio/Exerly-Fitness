import AppIntents
import ExerlyCore
import Foundation

// The workout in progress, from Shortcuts and Siri: the same changes as the
// Live Activity's buttons, for whichever set is next rather than the one a
// button was drawn for. Starting today's workout opens the app
// (StartWorkoutIntent, in Shared).

struct LogNextSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Log the next set"
    static let description = IntentDescription("Logs the next set of the workout in progress with the values already filled in for it.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (text, content) = try await IntentAccess().perform { try WorkoutIntentActions.logNextSet(in: $0) }
        await WorkoutActivityCoordinator.shared.show(content)
        return .result(dialog: "\(text)")
    }
}

struct RestIntent: AppIntent {
    static let title: LocalizedStringResource = "Rest"
    static let description = IntentDescription("Adds time to the rest that's running, or starts one, in the workout in progress.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Seconds", description: "Leave empty to add 30 seconds, or to start the rest your settings give.",
               inclusiveRange: (1, 1800))
    var seconds: Int?

    static var parameterSummary: some ParameterSummary { Summary("Rest") { \.$seconds } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (text, content) = try await IntentAccess().perform { try WorkoutIntentActions.rest(seconds.map(Double.init), in: $0) }
        await WorkoutActivityCoordinator.shared.show(content)
        return .result(dialog: "\(text)")
    }
}

/// What the workout intents do to the account's workout in progress, and
/// what they say. Each returns the Live Activity's new content.
@MainActor
enum WorkoutIntentActions {
    static func logNextSet(in account: IntentAccess.Account) throws -> (String, WorkoutActivityContent?) {
        let store = account.workspace.store
        guard let next = WorkoutActivityContent(store: store, unit: account.unit)?.state.next else {
            throw LoggingIntentError.invalid(store.activeSession == nil
                ? "There's no workout in progress. Start today's workout first."
                : "Every set of this workout is logged.")
        }
        guard next.isLoggable else {
            throw LoggingIntentError.invalid("Set \(next.number) of \(next.exercise) has no values yet. Fill it in in Exerly.")
        }
        try store.completeSet(next.setID)
        var text = "Logged \(next.exercise) set \(next.number), \(next.spokenValues)."
        if let rest = store.restTimer {
            text += " Rest \(spoken(rest.duration))."
        } else if store.activeSession?.isEverySetCompleted == true {
            text += " That was the last set."
        }
        return (text, WorkoutActivityContent(store: store, unit: account.unit))
    }

    static func rest(_ seconds: Double?, in account: IntentAccess.Account, now: Date = .now) throws -> (String, WorkoutActivityContent?) {
        let store = account.workspace.store
        guard let session = store.activeSession else {
            throw LoggingIntentError.invalid("There's no workout in progress. Start today's workout first.")
        }
        guard let action = WorkoutShortcuts.rest(seconds: seconds, running: store.restTimer, now: now, session: session,
                                                 policy: store.restPolicy, library: store.library) else {
            throw LoggingIntentError.invalid("Enter 1 second to 30 minutes.")
        }
        let text: String
        switch action {
        case .extend(let added):
            try store.extendRest(by: added)
            text = "Added \(spoken(added)). \(spoken(store.restTimer?.remaining(at: now) ?? added)) left."
        case .start(let length):
            try store.startRest(seconds: length)
            text = "Resting \(spoken(length))."
        }
        return (text, WorkoutActivityContent(store: store, unit: account.unit, now: now))
    }

    /// "2 minutes, 30 seconds".
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}
