import ExerlyCore
import XCTest
@testable import Exerly

/// Food, workouts and weigh-ins from Health are previewed, and nothing is
/// saved or turned on until the preview is confirmed. After that, Health is
/// followed: a better source, a deletion, a reinstall, another account.
@MainActor
final class HealthHistoryReadsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private var client: FakeHistoryClient!
    private var defaults: UserDefaults!
    private var workspace: TrainingWorkspace!
    private var activities: FakeActivityStore!
    private var current = "history"
    private var reviewedWeights: [Set<UUID>] = []
    private var weightsMatch = true

    override func setUp() async throws {
        client = FakeHistoryClient()
        defaults = UserDefaults(suiteName: "history-\(UUID().uuidString)")
        workspace = try TrainingWorkspace(accountID: "history", root: temporaryRoot())
        activities = FakeActivityStore(today: LocalDate(Date(), in: zone))
        current = "history"
        reviewedWeights = []
        weightsMatch = true
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func model(_ account: String = "history", defaults: UserDefaults? = nil) -> HealthHistoryModel {
        HealthHistoryModel(accountID: account, timeZone: zone, client: client, namespace: "test", defaults: defaults ?? self.defaults,
                           workspace: { self.workspace }, isCurrent: { $0 == self.current },
                           enableWeights: { self.reviewedWeights.append($0); return self.weightsMatch },
                           activities: { self.activities })
    }

    private func food(_ hour: Int, _ source: String, daysAgo: Int = 1) -> HealthFoodReading {
        let at = Date().addingTimeInterval(Double(-daysAgo) * 86400).addingTimeInterval(Double(hour - 12) * 3600)
        return HealthFoodReading(id: UUID(), at: at, name: "Synthetic soup", nutrients: NutrientAmounts([.energy: 250]),
                                 source: source, sourceName: source)
    }

    private func workout(daysAgo: Double = 0.1, source: String = "watch") -> HealthWorkoutReading {
        let start = Date().addingTimeInterval(-daysAgo * 86400)
        return HealthWorkoutReading(id: UUID(), start: start, end: start.addingTimeInterval(1800), activity: "Running",
                                    kilocalories: 320.4, source: source, sourceName: "Watch")
    }

    func testFoodIsPreviewedThenImportedOnceAndHealthIsFollowed() async throws {
        // Both apps saved yesterday; the tracker, which saved more, counts.
        let mine = food(12, "com.example.tracker"), earlier = food(12, "com.example.tracker", daysAgo: 2)
        let other = food(12, "com.example.diary")
        client.foods = [mine, earlier, other]
        let history = model()
        await history.begin(.foods)
        let pending = try XCTUnwrap(history.pending)
        XCTAssertEqual(pending.preview.adding, 2, "One source per day")
        XCTAssertEqual(pending.preview.leftOut, 1)
        XCTAssertTrue(workspace.nutrition.entries.isEmpty, "Nothing is saved before confirming")
        XCTAssertFalse(history.enabled.contains(.foods))

        await history.confirm()
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [mine.id, earlier.id])
        XCTAssertTrue(history.enabled.contains(.foods))
        XCTAssertEqual(history.lastImport[.foods], "Added 2 foods.")

        let later = food(19, "com.example.tracker", daysAgo: 0)
        client.foods = [earlier, other, later]
        await model().refresh()
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [earlier.id, other.id, later.id],
                       "Deleted in Health, gone here, so the diary's covers that day; new ones added")
        XCTAssertTrue(model("someone-else").enabled.isEmpty, "Each account chooses its own")
    }

    /// Review 1: a better source saving the same day later, alone in what's
    /// new, used to be added beside what was imported.
    func testABetterSourceSavingTheSameDayLaterReplacesItsFood() async throws {
        let first = food(8, "com.example.zdiary")
        client.foods = [first]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [first.id])

        // As many records each, the tracker ranks first by name.
        let better = food(8, "com.example.atracker")
        client.foods = [first, better]
        await history.refresh()
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [better.id], "The day counts one source once")
        await history.refresh()
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [better.id], "And stays so")
    }

    /// Review 1: soup deleted in Health while reading was off was kept.
    func testFoodDeletedInHealthWhileReadingWasOffIsTakenOutWhenItsOn() async throws {
        let soup = food(12, "com.example.tracker"), toast = food(8, "com.example.tracker")
        client.foods = [soup, toast]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        history.turnOff(.foods)
        client.foods = [toast]
        await history.refresh()
        XCTAssertEqual(workspace.nutrition.entries.count, 2, "Nothing is read while it's off")

        await history.begin(.foods)
        XCTAssertEqual(history.pending?.preview.removing, 1, "The preview says it goes")
        await history.confirm()
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [toast.id])
        XCTAssertEqual(history.lastImport[.foods], "Added 0 foods. Took out 1 food.")
    }

    func testCancellingSavesNothingAndLeavesItOff() async throws {
        client.workouts = [workout()]
        let history = model()
        await history.begin(.workouts)
        XCTAssertEqual(history.pending?.preview.adding, 1)
        history.cancel()
        XCTAssertNil(history.pending)
        XCTAssertTrue(activities.saved.isEmpty)
        await history.refresh()
        XCTAssertEqual(client.workoutReads, 1, "Nothing is read while it's off")

        await history.begin(.workouts)
        await history.confirm()
        XCTAssertEqual(activities.saved.map(\.request.type), ["Running"])
        XCTAssertEqual(activities.saved.first?.request.duration, 30)
        XCTAssertEqual(activities.saved.first?.request.calories, 320)
        await history.refresh()
        XCTAssertEqual(activities.saved.count, 1, "A workout read again isn't added twice")
    }

    /// Review 1: a reinstall imported every workout again, and deleting one
    /// in Health left its activity.
    func testAWorkoutIsOneActivityAcrossReinstallsAndGoesWhenHealthDeletesIt() async throws {
        let run = workout(), ride = workout(daysAgo: 2)
        client.workouts = [run, ride]
        let history = model()
        await history.begin(.workouts)
        await history.confirm()
        let ids = activities.saved.map(\.clientID)
        XCTAssertEqual(Set(ids), [HealthHistory.activityID(for: run.id, accountID: "history"),
                                  HealthHistory.activityID(for: ride.id, accountID: "history")])

        // A new install: nothing on this phone until the account's activities are read.
        let synced = activities.states
        activities.states = [:]
        activities.remote = synced
        let reinstalled = model(defaults: UserDefaults(suiteName: "history-\(UUID().uuidString)"))
        await reinstalled.begin(.workouts)
        XCTAssertEqual(reinstalled.pending?.preview.adding, 0, "Found in the account, not added again")
        XCTAssertEqual(reinstalled.pending?.preview.alreadyIn, 2)
        XCTAssertFalse(activities.read.isEmpty, "The account's days were read first")
        await reinstalled.confirm()
        XCTAssertEqual(activities.saved.count, 2)

        client.workouts = [ride]
        await reinstalled.refresh()
        XCTAssertEqual(activities.deleted, [HealthHistory.activityID(for: run.id, accountID: "history")])
        // Deleted in Exerly, it isn't added back.
        activities.states[HealthHistory.activityID(for: ride.id, accountID: "history")] = true
        await reinstalled.refresh()
        XCTAssertEqual(activities.saved.count, 2)
    }

    /// Review 1: a workout from before the ten years Exerly keeps failed the
    /// whole import.
    func testWorkoutsOlderThanTenYearsAreSetAsideAndTheRestImport() async throws {
        let old = workout(daysAgo: 4000), recent = workout()
        client.workouts = [old, recent]
        let history = model()
        await history.begin(.workouts)
        XCTAssertEqual(history.pending?.preview.outside, 1)
        XCTAssertEqual(history.pending?.preview.adding, 1)
        await history.confirm()
        XCTAssertNil(history.messages[.workouts])
        XCTAssertEqual(activities.saved.map(\.clientID), [HealthHistory.activityID(for: recent.id, accountID: "history")])
    }

    /// Review 1: a read that finished after another account opened saved
    /// into that account.
    func testAReadThatFinishesAfterAnotherAccountOpensSavesNothing() async throws {
        let breakfast = food(8, "com.example.tracker")
        client.foods = [breakfast]
        client.workouts = [workout()]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        await history.begin(.workouts)
        await history.confirm()
        XCTAssertEqual(activities.saved.count, 1)

        let other = try TrainingWorkspace(accountID: "other", root: temporaryRoot())
        client.foods = [breakfast, food(12, "com.example.tracker")]
        client.workouts = [workout(), workout(daysAgo: 1)]
        client.onRead = { self.workspace = other; self.current = "other" }
        await history.refresh()
        XCTAssertEqual(workspace.nutrition.entries.count, 0, "Nothing goes into the account now open")
        XCTAssertEqual(activities.saved.count, 1, "Nor into its activity log")

        // Switching back, the same read is made again for this account.
        client.onRead = nil
        current = "history"
        await history.begin(.foods)
        XCTAssertNil(history.pending, "Another account's data is open")
    }

    func testWeighInsArePreviewedAndOnlyThoseShownAreImported() async throws {
        try workspace.nutrition.logWeight(.kg(80), timeZone: zone)
        let scale = HealthWeight(id: UUID(), at: Date().addingTimeInterval(-86400), kilograms: 79.5)
        client.weightReadings = [(scale, "Scale")]
        let history = model()
        await history.begin(.weights)
        XCTAssertEqual(history.pending?.preview.adding, 1)
        XCTAssertEqual(history.pending?.preview.sources.map(\.name), ["Scale"])
        XCTAssertTrue(reviewedWeights.isEmpty)

        // One saved while the preview was open isn't imported unseen: the preview opens again with it.
        weightsMatch = false
        let added = HealthWeight(id: UUID(), at: Date().addingTimeInterval(-600), kilograms: 79.4)
        client.weightReadings.append((added, "Scale"))
        await history.confirm()
        XCTAssertEqual(reviewedWeights, [[scale.id]], "Turned on with what was shown")
        XCTAssertEqual(history.pending?.preview.adding, 2)
        XCTAssertNotNil(history.pending?.note)
        weightsMatch = true
        await history.confirm()
        XCTAssertEqual(reviewedWeights.last, [scale.id, added.id])
        XCTAssertEqual(history.lastImport[.weights], "Added 2 weigh-ins.")
    }
}

final class FakeHistoryClient: HealthHistoryClient, @unchecked Sendable {
    var available = true
    var foods: [HealthFoodReading] = []
    var workouts: [HealthWorkoutReading] = []
    var weightReadings: [(weight: HealthWeight, source: String)] = []
    var workoutReads = 0
    /// Runs while Health is read, before it answers.
    var onRead: (@MainActor () -> Void)?

    var isAvailable: Bool { available }
    func requestAccess(_ kind: HealthHistoryKind) async throws {}

    func foods() async throws -> [HealthFoodReading] {
        await onRead?()
        return foods
    }

    func workouts() async throws -> [HealthWorkoutReading] {
        workoutReads += 1
        await onRead?()
        return workouts
    }

    func weights() async throws -> [(weight: HealthWeight, source: String)] { weightReadings }
}

@MainActor
final class FakeActivityStore: HealthActivityStore {
    let days: ClosedRange<LocalDate>
    /// On this phone: each true if deleted.
    var states: [String: Bool] = [:]
    /// In the account, read by `readActivities`.
    var remote: [String: Bool] = [:]
    var saved: [(request: ActivityRequest, clientID: String)] = []
    var deleted: [String] = []
    var read: [ClosedRange<LocalDate>] = []

    init(today: LocalDate) { days = today.adding(days: -3650)...today }

    func activityStates(_ ids: Set<String>) -> [String: Bool] { states.filter { ids.contains($0.key) } }

    func readActivities(_ days: ClosedRange<LocalDate>) async {
        read.append(days)
        states.merge(remote) { local, _ in local }
    }

    func saveImportedActivity(_ request: ActivityRequest, clientID: String) throws {
        saved.append((request, clientID))
        states[clientID] = false
    }

    func deleteImportedActivity(clientID: String) throws {
        deleted.append(clientID)
        states[clientID] = true
    }
}
