import XCTest
import ExerlyCore
@testable import Exerly

/// Health sync against a fake HealthKit: consent, idempotence, deletions,
/// reading weigh-ins and account isolation. Synthetic data only.
@MainActor
final class HealthSyncTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var client: FakeHealthClient!
    private var sync: HealthSync!
    private let newYork = TimeZone(identifier: "America/New_York")!
    /// Health sync holds the workspace weakly, as the app's account owns it.
    private var opened: [TrainingWorkspace] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "exerly.health.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        client = FakeHealthClient()
        sync = HealthSync(client: client, defaults: defaults, namespace: "fixture", writeDelay: .milliseconds(20))
    }

    override func tearDown() async throws {
        sync.attach(nil, timeZone: newYork)
        for workspace in opened { await workspace.close() }
        opened = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ account: String) throws -> TrainingWorkspace {
        let workspace = try TrainingWorkspace(accountID: account, root: root)
        opened.append(workspace)
        sync.attach(workspace, timeZone: newYork)
        return workspace
    }

    /// Waits for scheduled writes and any sync in flight to finish. A change
    /// reaches the sync through an observation hop and the write delay, which
    /// a busy machine can stretch, so wait on the sync's own state.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
        let deadline = Date().addingTimeInterval(5)
        while (sync.isSyncing || sync.hasPendingWrite) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func logFood(_ workspace: TrainingWorkspace, kcal: Double = 400, protein: Double = 30) throws -> FoodEntry {
        let food = Food(name: "Synthetic rice bowl", per100g: NutrientAmounts([.energy: kcal, .protein: protein, .water: 60]))
        return try workspace.nutrition.log(food, grams: 100, on: LocalDate(Date(), in: newYork), meal: "Lunch")
    }

    /// A workout that ended now and started within today in New York: writes
    /// cover records from the day a switch was turned on, so a test run just
    /// after midnight mustn't start it the day before.
    private func finishWorkout(_ workspace: TrainingWorkspace) throws -> WorkoutSession {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let now = Date()
        let start = max(now.addingTimeInterval(-3600), calendar.startOfDay(for: now).addingTimeInterval(1))
        let session = WorkoutSession(name: "Synthetic pull", startedAt: start, endedAt: now, timeZone: newYork)
        try workspace.store.importSessions([session])
        return session
    }

    func testNothingIsReadOrWrittenWhileEverySwitchIsOff() async throws {
        let workspace = try open("account-a")
        _ = try logFood(workspace)
        try workspace.nutrition.logWeight(.kg(80), timeZone: newYork)
        _ = try finishWorkout(workspace)
        await sync.sync()
        try await settle()
        XCTAssertTrue(client.calls.isEmpty, "No HealthKit call without a switch on: \(client.calls)")
        XCTAssertNil(sync.preferences.lastSync)
    }

    func testFoodIsWrittenOnceThenReplacedOnEditAndRemovedOnDelete() async throws {
        let workspace = try open("account-a")
        await sync.setEnabled(.writeFood, true)
        XCTAssertEqual(client.requested, [.writeFood], "Only food's types are requested")
        let entry = try logFood(workspace)
        try await settle()
        XCTAssertEqual(client.savedFood.map(\.id), [entry.id])
        let saved = try XCTUnwrap(client.savedFood.first)
        XCTAssertEqual(saved.quantities.map(\.type), ["HKQuantityTypeIdentifierDietaryEnergyConsumed",
                                                      "HKQuantityTypeIdentifierDietaryProtein"], "Water isn't written")
        XCTAssertEqual(sync.lastResult?.written[.food], 1)

        // Retries and unrelated syncs write nothing more.
        await sync.sync()
        await sync.sync()
        try await settle()
        XCTAssertEqual(client.savedFood.count, 1)
        XCTAssertTrue(client.removed.isEmpty)

        var edited = entry
        edited.grams = 150
        try workspace.nutrition.saveEntry(edited)
        try await settle()
        XCTAssertEqual(client.removed.map(\.ids), [[entry.id]], "The old samples come out first")
        XCTAssertEqual(client.savedFood.map(\.id), [entry.id, entry.id])
        XCTAssertEqual(client.savedFood.last?.quantities.first?.value ?? 0, 600, accuracy: 0.001)

        try workspace.nutrition.deleteEntry(entry.id)
        try await settle()
        XCTAssertEqual(client.removed.map(\.ids), [[entry.id], [entry.id]])
        XCTAssertEqual(client.savedFood.count, 2)
    }

    func testFoodLoggedBeforeTheSwitchDayStaysOut() async throws {
        let workspace = try open("account-a")
        let food = Food(name: "Synthetic toast", per100g: NutrientAmounts([.energy: 260]))
        let old = try workspace.nutrition.log(food, grams: 80, on: LocalDate(Date(), in: newYork).adding(days: -3), meal: "Breakfast")
        let today = try logFood(workspace)
        await sync.setEnabled(.writeFood, true)
        try await settle()
        XCTAssertEqual(client.savedFood.map(\.id), [today.id])
        XCTAssertFalse(client.savedFood.contains { $0.id == old.id })
    }

    func testAFailedSaveIsRetriedWithoutDuplicates() async throws {
        let workspace = try open("account-a")
        await sync.setEnabled(.writeWeights, true)
        client.failSaves = 1
        let weight = try workspace.nutrition.logWeight(.lb(184.6), bodyFat: 21, timeZone: newYork)
        try await settle()
        XCTAssertTrue(client.savedWeights.isEmpty)
        XCTAssertNotNil(sync.problem)
        await sync.sync()
        try await settle()
        XCTAssertEqual(client.savedWeights.map(\.id), [weight.id])
        XCTAssertEqual(client.savedWeights.first?.weight.unit, .pounds)
        XCTAssertEqual(client.savedWeights.first?.bodyFatFraction ?? 0, 0.21, accuracy: 1e-9)
        XCTAssertNil(sync.problem)
        await sync.sync()
        try await settle()
        XCTAssertEqual(client.savedWeights.count, 1)
    }

    func testWorkoutsAreWrittenWhenFinished() async throws {
        let workspace = try open("account-a")
        await sync.setEnabled(.writeWorkouts, true)
        let session = try finishWorkout(workspace)
        try await settle()
        XCTAssertEqual(client.savedWorkouts.map(\.id), [session.id])
        XCTAssertEqual(client.savedWorkouts.first?.end.timeIntervalSince(session.startedAt) ?? 0,
                       session.duration ?? -1, accuracy: 0.01)
        try workspace.store.deleteSession(session.id)
        try await settle()
        XCTAssertEqual(client.removed.map(\.kind), [.workout])
    }

    func testAWorkoutTheWatchRecordedIsNotWrittenASecondTime() async throws {
        let workspace = try open("account-a")
        XCTAssertFalse(sync.writesWorkouts(accountID: "account-a"))
        await sync.setEnabled(.writeWorkouts, true)
        XCTAssertTrue(sync.writesWorkouts(accountID: "account-a"))
        XCTAssertFalse(sync.writesWorkouts(accountID: "account-b"), "Each account has its own switch")
        let template = try finishWorkout(workspace)
        try await settle()
        let watched = WorkoutSession(name: "Synthetic legs", startedAt: template.startedAt.addingTimeInterval(1),
                                     endedAt: template.endedAt, timeZone: newYork)
        WatchHealthWorkouts.insert(watched.id, defaults: defaults)
        try workspace.store.importSessions([watched])
        try await settle()
        XCTAssertEqual(client.savedWorkouts.map(\.id), [template.id], "Only the workout the watch didn't record is saved")
        XCTAssertNil(sync.problem)
        // Deleting it in Exerly still removes what Exerly wrote under its ID.
        try workspace.store.deleteSession(watched.id)
        try await settle()
        XCTAssertEqual(client.removed.map(\.kind), [.workout])
    }

    func testADeniedWriteKeepsItsSwitchOffAndSaysWhere() async throws {
        let workspace = try open("account-a")
        client.denied = [.writeFood]
        await sync.setEnabled(.writeFood, true)
        XCTAssertFalse(sync.preferences.isOn(.writeFood))
        XCTAssertEqual(sync.notices[.writeFood], HealthSync.deniedNotice)
        _ = try logFood(workspace)
        try await settle()
        XCTAssertTrue(client.savedFood.isEmpty)
    }

    func testAccessRevokedLaterIsReportedAndNothingIsWritten() async throws {
        let workspace = try open("account-a")
        await sync.setEnabled(.writeWeights, true)
        client.denied = [.writeWeights]
        try workspace.nutrition.logWeight(.kg(80), timeZone: newYork)
        try await settle()
        XCTAssertTrue(client.savedWeights.isEmpty)
        XCTAssertTrue(sync.preferences.isOn(.writeWeights), "The choice is kept for when Health allows it again")
        XCTAssertEqual(sync.notices[.writeWeights], HealthSync.deniedNotice)
    }

    func testWeighInsFromHealthArriveWithBodyFatAndFollowDeletions() async throws {
        let workspace = try open("account-a")
        let at = Date().addingTimeInterval(-600)
        let morning = HealthMassReading(id: UUID(), at: at, kilograms: 80.4, timeZone: newYork, source: "com.example.scale")
        let fat = HealthBodyFatReading(id: UUID(), at: at, fraction: 0.214, source: "com.example.scale")
        client.deltas = [HealthWeightDelta(addedMass: [morning], addedBodyFat: [fat], massAnchor: Data([1]), bodyFatAnchor: Data([2]))]
        await sync.setEnabled(.readWeights, true)
        try await settle()
        XCTAssertTrue(client.observing)
        let imported = try XCTUnwrap(workspace.nutrition.weights.first { $0.id == morning.id })
        XCTAssertEqual(imported.source, .appleHealth)
        XCTAssertEqual(imported.weight, .kg(80.4))
        XCTAssertEqual(imported.bodyFat, 21.4)
        XCTAssertEqual(imported.date, LocalDate(at, in: newYork))
        XCTAssertEqual(sync.lastResult?.read, 1)

        // The next read resumes from the saved anchors, and a deletion in Health follows.
        client.deltas = [HealthWeightDelta(deletedMass: [morning.id], massAnchor: Data([3]), bodyFatAnchor: Data([4]))]
        await sync.sync()
        try await settle()
        XCTAssertEqual(client.anchorsSeen.last?.mass, Data([1]))
        XCTAssertEqual(client.anchorsSeen.last?.fat, Data([2]))
        XCTAssertFalse(workspace.nutrition.weights.contains { $0.id == morning.id })
    }

    /// Review 1: turning Read weigh-ins on from its preview read Health again
    /// and imported a reading saved while the preview was open, unseen.
    func testReadWeighInsFromItsPreviewImportsOnlyTheReadingsShown() async throws {
        let workspace = try open("account-a")
        let shown = HealthMassReading(id: UUID(), at: Date().addingTimeInterval(-86400), kilograms: 80.4, source: "com.example.scale")
        let unseen = HealthMassReading(id: UUID(), at: Date().addingTimeInterval(-600), kilograms: 80.1, source: "com.example.scale")
        let watch = HealthMassReading(id: UUID(), at: Date().addingTimeInterval(-300), kilograms: 80.2, source: "com.exerly.fitness.watchkitapp")
        client.deltas = [HealthWeightDelta(addedMass: [shown, unseen], massAnchor: Data([1]))]
        let matched = await sync.enableReadingWeights(reviewed: [shown.id])
        try await settle()
        XCTAssertFalse(matched, "Health had one the preview didn't show")
        XCTAssertFalse(sync.preferences.isOn(.readWeights), "So it stays off for a new preview")
        XCTAssertTrue(workspace.nutrition.weights.isEmpty, "And nothing was imported")
        XCTAssertEqual(sync.notices[.readWeights], HealthSync.reviewChangedNotice)

        client.deltas = [HealthWeightDelta(addedMass: [shown, unseen, watch], massAnchor: Data([1]))]
        let again = await sync.enableReadingWeights(reviewed: [shown.id, unseen.id])
        try await settle()
        XCTAssertTrue(again)
        XCTAssertTrue(sync.preferences.isOn(.readWeights))
        XCTAssertEqual(Set(workspace.nutrition.weights.map(\.id)), [shown.id, unseen.id, watch.id])
        XCTAssertNil(sync.notices[.readWeights])
    }

    func testBodyFatArrivingLaterJoinsItsWeighIn() async throws {
        let workspace = try open("account-a")
        let at = Date().addingTimeInterval(-900)
        let weight = HealthMassReading(id: UUID(), at: at, kilograms: 79.8)
        client.deltas = [HealthWeightDelta(addedMass: [weight], massAnchor: Data([1]), bodyFatAnchor: Data([1]))]
        await sync.setEnabled(.readWeights, true)
        try await settle()
        XCTAssertNil(workspace.nutrition.weights.first { $0.id == weight.id }?.bodyFat)

        let fat = HealthBodyFatReading(id: UUID(), at: at.addingTimeInterval(30), fraction: 0.2)
        client.deltas = [HealthWeightDelta(addedBodyFat: [fat], massAnchor: Data([2]), bodyFatAnchor: Data([2]))]
        client.around = ([weight], [fat])
        await sync.sync()
        try await settle()
        XCTAssertEqual(workspace.nutrition.weights.first { $0.id == weight.id }?.bodyFat, 20)
        let span = try XCTUnwrap(client.spans.last)
        XCTAssertTrue(span.contains(at) && span.contains(fat.at))

        // Deleting the body fat in Health takes it off the weigh-in.
        client.deltas = [HealthWeightDelta(deletedBodyFat: [fat.id], massAnchor: Data([3]), bodyFatAnchor: Data([3]))]
        client.around = ([weight], [])
        await sync.sync()
        try await settle()
        XCTAssertNil(workspace.nutrition.weights.first { $0.id == weight.id }?.bodyFat)
    }

    func testWeighInsReadFromHealthAreNeverWrittenBack() async throws {
        let workspace = try open("account-a")
        let reading = HealthMassReading(id: UUID(), at: Date().addingTimeInterval(-60), kilograms: 81)
        client.deltas = [HealthWeightDelta(addedMass: [reading], massAnchor: Data([1]), bodyFatAnchor: Data([1]))]
        await sync.setEnabled(.writeWeights, true)
        await sync.setEnabled(.readWeights, true)
        try await settle()
        XCTAssertTrue(workspace.nutrition.weights.contains { $0.id == reading.id })
        XCTAssertTrue(client.savedWeights.isEmpty, "Health's own reading must not loop back")
        let typed = try workspace.nutrition.logWeight(.kg(80.5), timeZone: newYork)
        try await settle()
        XCTAssertEqual(client.savedWeights.map(\.id), [typed.id])
    }

    func testSwitchesLedgerAndAnchorsBelongToOneAccount() async throws {
        let a = try open("account-a")
        await sync.setEnabled(.writeFood, true)
        client.deltas = [HealthWeightDelta(massAnchor: Data([9]), bodyFatAnchor: Data([9]))]
        await sync.setEnabled(.readWeights, true)
        _ = try logFood(a)
        try await settle()
        XCTAssertEqual(client.savedFood.count, 1)

        let b = try open("account-b")
        XCTAssertFalse(sync.preferences.isOn(.writeFood), "Another account starts with every switch off")
        XCTAssertFalse(sync.preferences.isOn(.readWeights))
        _ = try logFood(b)
        try await settle()
        XCTAssertEqual(client.savedFood.count, 1, "Account B's food isn't written without its own consent")

        await a.close()
        await b.close()
        _ = try open("account-a")
        XCTAssertTrue(sync.preferences.isOn(.writeFood))
        await sync.sync()
        try await settle()
        XCTAssertEqual(client.savedFood.count, 1, "Account A's ledger survives the switch")
        XCTAssertEqual(client.anchorsSeen.last?.mass, Data([9]))
    }

    func testTheOfferHidesOnceAnswered() async throws {
        _ = try open("account-a")
        XCTAssertFalse(sync.preferences.promptDismissed)
        sync.dismissPrompt()
        _ = try open("account-b")
        XCTAssertFalse(sync.preferences.promptDismissed, "Each account answers for itself")
        _ = try open("account-a")
        XCTAssertTrue(sync.preferences.promptDismissed)
    }

    func testUnavailableHealthRequestsNothing() async throws {
        _ = try open("account-a")
        client.available = false
        await sync.setEnabled(.readWeights, true)
        XCTAssertFalse(sync.preferences.isOn(.readWeights))
        XCTAssertTrue(client.requested.isEmpty)
        XCTAssertNotNil(sync.notices[.readWeights])
    }

    func testSyncSummaryReadsNaturally() {
        XCTAssertEqual(HealthSyncResult().summary, "Everything is up to date.")
        XCTAssertEqual(HealthSyncResult(read: 1, written: [.food: 3, .workout: 1]).summary,
                       "1 weigh-in from Health · 3 foods written · 1 workout written")
    }
}

/// Records every call instead of touching HealthKit.
final class FakeHealthClient: HealthStoreClient, @unchecked Sendable {
    var available = true
    var denied: Set<HealthCategory> = []
    var requested: [HealthCategory] = []
    var deltas: [HealthWeightDelta] = []
    var around: (mass: [HealthMassReading], bodyFat: [HealthBodyFatReading]) = ([], [])
    var spans: [DateInterval] = []
    var anchorsSeen: [(mass: Data?, fat: Data?)] = []
    var removed: [(kind: HealthRecordKind, ids: [UUID])] = []
    var savedFood: [HealthFoodRecord] = []
    var savedWeights: [HealthWeightRecord] = []
    var savedWorkouts: [HealthWorkoutRecord] = []
    var failSaves = 0
    var observing = false
    var calls: [String] = []

    var isAvailable: Bool { available }

    func requestAccess(_ category: HealthCategory) async throws {
        calls.append("request")
        requested.append(category)
    }

    func writeAccess(_ category: HealthCategory) -> HealthWriteAccess { denied.contains(category) ? .denied : .allowed }

    func weightChanges(massAnchor: Data?, bodyFatAnchor: Data?) async throws -> HealthWeightDelta {
        calls.append("read")
        anchorsSeen.append((massAnchor, bodyFatAnchor))
        return deltas.isEmpty ? HealthWeightDelta(massAnchor: massAnchor, bodyFatAnchor: bodyFatAnchor) : deltas.removeFirst()
    }

    func weights(in span: DateInterval) async throws -> (mass: [HealthMassReading], bodyFat: [HealthBodyFatReading]) {
        calls.append("around")
        spans.append(span)
        return around
    }

    func remove(_ kind: HealthRecordKind, ids: [UUID]) async throws {
        calls.append("remove")
        removed.append((kind, ids))
    }

    private func failIfAsked() throws {
        if failSaves > 0 {
            failSaves -= 1
            throw URLError(.cannotWriteToFile)
        }
    }

    func saveFood(_ records: [HealthFoodRecord]) async throws {
        calls.append("saveFood")
        try failIfAsked()
        savedFood += records
    }

    func saveWeights(_ records: [HealthWeightRecord]) async throws {
        calls.append("saveWeights")
        try failIfAsked()
        savedWeights += records
    }

    func saveWorkout(_ record: HealthWorkoutRecord) async throws {
        calls.append("saveWorkout")
        try failIfAsked()
        savedWorkouts.append(record)
    }

    func activity(on date: LocalDate, timeZone: TimeZone) async -> HealthActivity { HealthActivity() }

    func observeWeights(_ onChange: @escaping @Sendable () async -> Void) {
        calls.append("observe")
        observing = true
    }

    func stopObservingWeights() { observing = false }
}
