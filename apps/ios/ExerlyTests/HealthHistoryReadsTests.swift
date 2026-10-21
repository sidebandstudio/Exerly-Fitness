import ExerlyCore
import XCTest
@testable import Exerly

/// Food, workouts and weigh-ins from Health are previewed, and nothing is
/// saved or turned on until the preview is confirmed.
@MainActor
final class HealthHistoryReadsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private var client: FakeHistoryClient!
    private var defaults: UserDefaults!
    private var workspace: TrainingWorkspace!
    private var activities: [ActivityRequest] = []
    private var weightsEnabled = 0

    override func setUp() async throws {
        client = FakeHistoryClient()
        defaults = UserDefaults(suiteName: "history-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        workspace = try TrainingWorkspace(accountID: "history", root: root)
        activities = []
        weightsEnabled = 0
    }

    private func model(_ account: String = "history") -> HealthHistoryModel {
        HealthHistoryModel(accountID: account, timeZone: zone, client: client, namespace: "test", defaults: defaults,
                           workspace: { self.workspace }, enableWeights: { self.weightsEnabled += 1 },
                           saveActivity: { self.activities.append($0) })
    }

    private func food(_ hour: Int, _ source: String, daysAgo: Int = 1) -> HealthFoodReading {
        let at = Date().addingTimeInterval(Double(-daysAgo) * 86400).addingTimeInterval(Double(hour - 12) * 3600)
        return HealthFoodReading(id: UUID(), at: at, name: "Synthetic soup", nutrients: NutrientAmounts([.energy: 250]),
                                 source: source, sourceName: source)
    }

    func testFoodIsPreviewedThenImportedOnceAndNewOnesFollow() async throws {
        // Both apps saved yesterday; the tracker, which saved more, counts.
        let mine = food(12, "com.example.tracker"), earlier = food(12, "com.example.tracker", daysAgo: 2)
        let other = food(12, "com.example.diary")
        client.foodChanges = [HealthChanges(added: [mine, earlier, other], anchor: Data("1".utf8))]
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
        client.foodChanges = [HealthChanges(added: [later], deleted: [mine.id], anchor: Data("2".utf8))]
        await model().refresh()
        XCTAssertEqual(client.anchorsSeen, [nil, Data("1".utf8)], "New ones are read from where the import stopped")
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [earlier.id, later.id], "Deleted in Health, gone here; new ones added")
        XCTAssertTrue(model("someone-else").enabled.isEmpty, "Each account chooses its own")
    }

    func testCancellingSavesNothingAndLeavesItOff() async throws {
        client.workoutChanges = [HealthChanges(added: [HealthWorkoutReading(id: UUID(), start: Date().addingTimeInterval(-7200),
                                                                         end: Date().addingTimeInterval(-5400), activity: "Running",
                                                                         kilocalories: 320.4, source: "watch", sourceName: "Watch")])]
        let history = model()
        await history.begin(.workouts)
        XCTAssertEqual(history.pending?.preview.adding, 1)
        history.cancel()
        XCTAssertNil(history.pending)
        XCTAssertTrue(activities.isEmpty)
        await history.refresh()
        XCTAssertEqual(client.workoutReads, 1, "Nothing is read while it's off")

        client.workoutChanges = [client.lastWorkouts!]
        await history.begin(.workouts)
        await history.confirm()
        XCTAssertEqual(activities.map(\.type), ["Running"])
        XCTAssertEqual(activities.first?.duration, 30)
        XCTAssertEqual(activities.first?.calories, 320)
        client.workoutChanges = [client.lastWorkouts!]
        await history.refresh()
        XCTAssertEqual(activities.count, 1, "A workout read again isn't added twice")
    }

    func testWeighInsArePreviewedBeforeTheSwitchReadsThem() async throws {
        try workspace.nutrition.logWeight(.kg(80), timeZone: zone)
        client.weightReadings = [(HealthWeight(id: UUID(), at: Date().addingTimeInterval(-86400), kilograms: 79.5), "Scale")]
        let history = model()
        await history.begin(.weights)
        XCTAssertEqual(history.pending?.preview.adding, 1)
        XCTAssertEqual(history.pending?.preview.sources.map(\.name), ["Scale"])
        XCTAssertEqual(weightsEnabled, 0)
        await history.confirm()
        XCTAssertEqual(weightsEnabled, 1, "Confirming turns on Read weigh-ins, which imports them")
    }
}

final class FakeHistoryClient: HealthHistoryClient, @unchecked Sendable {
    var available = true
    var foodChanges: [HealthChanges<HealthFoodReading>] = []
    var workoutChanges: [HealthChanges<HealthWorkoutReading>] = []
    var lastWorkouts: HealthChanges<HealthWorkoutReading>?
    var weightReadings: [(weight: HealthWeight, source: String)] = []
    var anchorsSeen: [Data?] = []
    var workoutReads = 0

    var isAvailable: Bool { available }
    func requestAccess(_ kind: HealthHistoryKind) async throws {}

    func foods(after anchor: Data?) async throws -> HealthChanges<HealthFoodReading> {
        anchorsSeen.append(anchor)
        return foodChanges.isEmpty ? HealthChanges(anchor: anchor) : foodChanges.removeFirst()
    }

    func workouts(after anchor: Data?) async throws -> HealthChanges<HealthWorkoutReading> {
        workoutReads += 1
        let changes = workoutChanges.isEmpty ? HealthChanges(anchor: anchor) : workoutChanges.removeFirst()
        if !changes.added.isEmpty { lastWorkouts = changes }
        return changes
    }

    func weights() async throws -> [(weight: HealthWeight, source: String)] { weightReadings }
}
