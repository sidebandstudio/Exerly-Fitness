import ActivityKit
import Foundation

/// The workout in progress as a Live Activity. The app fills it in from the
/// active session; the widget extension only draws it, so it holds display
/// values: names, counts, dates and loads already written in the person's unit.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// The workout's name, or its day for a planned workout: "Upper A".
        var title: String
        /// The program of a planned workout: "Strength foundations".
        var program: String?
        var startedAt: Date
        var completedSets: Int
        var totalSets: Int
        /// Rest between sets, while it runs.
        var rest: Rest?
        /// The first set not yet done, in the order the workout is performed.
        var next: NextSet?
    }

    struct Rest: Codable, Hashable, Sendable {
        var startedAt: Date
        var endsAt: Date
    }

    struct NextSet: Codable, Hashable, Sendable {
        var setID: UUID
        var exercise: String
        /// The set's position in its exercise, from 1.
        var number: Int
        /// Its prefilled values with their unit: "160 lb × 7", "BW × 9", "45 s".
        var values: String
        /// The same values for VoiceOver: "160 pounds, 7 reps".
        var spokenValues: String
        /// Whether every value it needs is filled in, so one tap can log it.
        var isLoggable: Bool
    }

    /// The session's ID, to match an activity to its workout.
    var workoutID: UUID
}

extension WorkoutActivityAttributes.NextSet {
    /// "Barbell Bench Press · Set 3 · 160 lb × 7"
    var line: String { "\(exercise) · Set \(number) · \(values)" }
    var spokenLine: String { "Next, \(exercise), set \(number), \(spokenValues)" }
}

extension WorkoutActivityAttributes.ContentState {
    /// The elapsed-time range for `Text(timerInterval:)`. Activities last at
    /// most twelve hours, so the upper bound is never reached.
    var elapsed: ClosedRange<Date> { startedAt...startedAt.addingTimeInterval(12 * 3600) }

    var setsLabel: String { "\(completedSets)/\(totalSets)" }
    var spokenSets: String { "\(completedSets) of \(totalSets) sets done" }

    /// Rest still running, unless the system has marked the content stale,
    /// which happens when rest ends.
    func activeRest(isStale: Bool) -> WorkoutActivityAttributes.Rest? { isStale ? nil : rest }
}

/// Links from widgets, controls and the Live Activity into the app.
enum ExerlyLinks {
    static let today = URL(string: "exerly://today")!
    /// The Train tab, with the workout in progress.
    static let train = URL(string: "exerly://train")!
    /// The food search tab.
    static let search = URL(string: "exerly://search")!
    /// The barcode scanner over Today.
    static let scan = URL(string: "exerly://scan")!
    /// A new weigh-in over Today.
    static let weighIn = URL(string: "exerly://weigh-in")!
    /// Starts today's workout, or returns to the one in progress.
    static let startWorkout = URL(string: "exerly://start-workout")!

    /// One of the person's foods, ready to log over Today.
    static func food(_ id: String) -> URL {
        var link = URLComponents(string: "exerly://food")!
        link.queryItems = [URLQueryItem(name: "id", value: id)]
        return link.url!
    }
    static func foodID(in url: URL) -> String? {
        guard url.scheme == "exerly", url.host == "food" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }

    /// Today, confirming an entry an account just logged, with Undo.
    static func logged(_ entry: UUID, accountID: String) -> URL {
        var link = URLComponents(string: "exerly://logged")!
        link.queryItems = [URLQueryItem(name: "entry", value: entry.uuidString), URLQueryItem(name: "account", value: accountID)]
        return link.url!
    }
    static func logged(in url: URL) -> (entry: UUID, accountID: String)? {
        guard url.scheme == "exerly", url.host == "logged",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let entry = items.first(where: { $0.name == "entry" })?.value.flatMap(UUID.init(uuidString:)),
              let accountID = items.first(where: { $0.name == "account" })?.value else { return nil }
        return (entry, accountID)
    }
}
