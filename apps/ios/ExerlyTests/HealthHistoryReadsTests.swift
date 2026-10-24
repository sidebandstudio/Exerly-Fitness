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
    private var root: URL!
    private var activities: FakeActivityStore!
    private var current = "history"
    private var install = "this-phone"
    private var reviewedWeights: [Set<UUID>] = []
    private var weightsMatch = true

    override func setUp() async throws {
        client = FakeHistoryClient()
        defaults = UserDefaults(suiteName: "history-\(UUID().uuidString)")
        root = temporaryRoot()
        workspace = try TrainingWorkspace(accountID: "history", root: root)
        activities = FakeActivityStore(today: LocalDate(Date(), in: zone))
        current = "history"
        install = "this-phone"
        reviewedWeights = []
        weightsMatch = true
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// `phone` and `client` stand for another phone's data and Health.
    private func model(_ account: String = "history", defaults: UserDefaults? = nil, on phone: TrainingWorkspace? = nil,
                       client: FakeHistoryClient? = nil, queueCap: Int = HealthChangeQueue.cap) -> HealthHistoryModel {
        HealthHistoryModel(accountID: account, timeZone: zone, client: client ?? self.client, namespace: "test",
                           defaults: defaults ?? self.defaults, install: install,
                           workspace: { phone ?? self.workspace }, isCurrent: { $0 == self.current },
                           enableWeights: { self.reviewedWeights.append($0); return self.weightsMatch },
                           activities: { self.activities }, queueCap: queueCap)
    }

    /// Health answering as if it had nothing, as a revoked read does: no samples, and no deletions.
    private func revoke() { client.revoked = true }

    /// Entries another phone imported, with their records, which reached this one by sync.
    private func importedOnAnotherPhone(_ foods: [HealthFoodReading]) throws {
        var changes = HealthFoodChanges()
        changes.adding = foods
        try workspace.healthImports.apply(changes, to: workspace.nutrition, install: "another-phone", timeZone: zone)
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
        XCTAssertEqual(history.lastImport[.foods], "Added 2 foods. 1 food from other sources set aside.")

        let later = food(19, "com.example.tracker", daysAgo: 0)
        client.foods = [earlier, other, later]
        let reading = model()
        await reading.refresh()
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [mine.id, earlier.id, later.id], "New ones added; nothing taken out")
        await reading.applyChanges()
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [earlier.id, later.id], "Deleted in Health, gone here once applied")
        XCTAssertEqual(client.anchorsSeen.count, 2, "Read from where the import stopped")
        XCTAssertTrue(model("someone-else").enabled.isEmpty, "Each account chooses its own")
    }

    /// Review 5: a source arriving later for a day already imported is set
    /// aside and noted on what's there, never swapped in, applying changes too.
    func testALaterSourceForAnImportedDayIsSetAsideAndNoted() async throws {
        let first = food(8, "com.example.zdiary")
        client.foods = [first]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        // As many records each, the tracker ranks first by name.
        let better = food(8, "com.example.atracker")
        client.foods = [first, better]
        await history.refresh()
        await history.applyChanges()
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [first.id], "Never swapped in")
        XCTAssertEqual(workspace.healthImports.records[first.id]?.alsoInNote, "Also in Health from com.example.atracker, not imported")
        XCTAssertNil(workspace.healthImports.records[better.id])
        XCTAssertTrue(workspace.healthImports.queue.isEmpty, "Nothing waits for it")
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
        XCTAssertEqual(history.pending?.preview.removing, 1, "The preview lists its deletion")
        await history.confirm()
        XCTAssertEqual(history.lastImport[.foods], "Added 0 foods. 1 change waits in Changes from Health.")
        await history.applyChanges()
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [toast.id])
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
        install = "new-install"
        let reinstalled = model(defaults: UserDefaults(suiteName: "history-\(UUID().uuidString)"))
        await reinstalled.begin(.workouts)
        XCTAssertEqual(reinstalled.pending?.preview.adding, 0, "Found in the account, not added again")
        XCTAssertEqual(reinstalled.pending?.preview.alreadyIn, 2)
        XCTAssertFalse(activities.read.isEmpty, "The account's days were read first")
        XCTAssertEqual(reinstalled.pending?.preview.adoptable, 2, "Offered to keep as this iPhone's, never taken")
        await reinstalled.confirm(adopt: true)
        XCTAssertEqual(activities.saved.count, 2)

        client.workouts = [ride]
        await reinstalled.refresh()
        XCTAssertTrue(activities.deleted.isEmpty, "Waits in Changes from Health")
        await reinstalled.applyChanges()
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

    // MARK: Review 2

    /// Item 1: a read Health has revoked looks like no data, so nothing imported goes for it.
    func testARevokedReadRemovesNothing() async throws {
        let breakfast = food(8, "com.example.tracker"), lunch = food(12, "com.example.tracker")
        client.foods = [breakfast, lunch]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        revoke()
        await history.refresh()
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [breakfast.id, lunch.id])
        // Checking everything again lists them, kept unless they choose.
        await history.checkEverythingAgain(.foods)
        XCTAssertEqual(history.pending?.preview.missing, 2)
        await history.confirm()
        XCTAssertEqual(workspace.nutrition.entries.count, 2, "Kept: they wait in Changes from Health")
        XCTAssertEqual(Set(workspace.healthImports.queue.entries.filter { $0.reason == .missing }.map(\.id)), [breakfast.id, lunch.id])
        await history.applyChanges()
        XCTAssertTrue(workspace.nutrition.entries.isEmpty, "Removed once chosen")
    }

    /// Item 2: an entry they changed, in amount or day and meal, stays when
    /// a better source covers its day and Health deletes it.
    func testAnEntryTheyChangedStaysWhenOutrankedOrDeleted() async throws {
        let breakfast = food(8, "com.example.zdiary"), snack = food(15, "com.example.zdiary", daysAgo: 2)
        client.foods = [breakfast, snack]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        var portion = try XCTUnwrap(workspace.nutrition.entries.first { $0.id == breakfast.id })
        portion.grams = 150
        try workspace.nutrition.saveEntry(portion)
        try workspace.nutrition.move([snack.id], to: LocalDate(Date(), in: zone), meal: "Dinner")
        client.foods = [food(8, "com.example.atracker"), food(15, "com.example.atracker", daysAgo: 2)]
        await history.refresh()
        XCTAssertTrue(Set(workspace.nutrition.entries.map(\.id)).isSuperset(of: [breakfast.id, snack.id]))
    }

    /// Item 2: a nutrient change made while the preview is open keeps the entry it would take out.
    func testANutrientChangeAfterThePreviewKeepsTheEntry() async throws {
        let soup = food(12, "com.example.zdiary")
        client.foods = [soup]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods = [food(12, "com.example.atracker")]
        await history.checkEverythingAgain(.foods)
        let entry = try XCTUnwrap(workspace.nutrition.entries.first { $0.id == soup.id })
        try workspace.nutrition.saveEntry(entry.editingNutrients(NutrientAmounts([.energy: 320])))
        await history.confirm()
        await history.applyChanges()
        XCTAssertTrue(workspace.nutrition.entries.contains { $0.id == soup.id })
    }

    /// Item 3: what another phone imported is never taken out here, outranked or missing.
    func testAnotherPhonesImportsAreNeverRemovedHere() async throws {
        let breakfast = food(8, "com.example.zdiary"), lunch = food(12, "com.example.zdiary", daysAgo: 3)
        try importedOnAnotherPhone([breakfast, lunch])
        client.foods = [breakfast, food(8, "com.example.atracker")]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods = [food(8, "com.example.atracker")]
        await history.refresh()
        XCTAssertTrue(Set(workspace.nutrition.entries.map(\.id)).isSuperset(of: [breakfast.id, lunch.id]))
    }

    /// Review 5: a workout from another source over one already imported is
    /// set aside and noted, never swapped in.
    func testALaterSourceForAnImportedWorkoutIsSetAsideAndNoted() async throws {
        let app = workout(source: "com.example.runs")
        var watch = workout(source: "com.apple.health.watch")
        watch.start = app.start.addingTimeInterval(60)
        client.workouts = [app]
        let history = model()
        await history.begin(.workouts)
        await history.confirm()
        client.workouts = [app, watch]
        await history.refresh()
        await history.applyChanges()
        XCTAssertEqual(activities.saved.map(\.clientID), [HealthHistory.activityID(for: app.id, accountID: "history")])
        XCTAssertTrue(activities.deleted.isEmpty)
        XCTAssertEqual(workspace.healthImports.records[app.id]?.alsoIn, ["Watch"])
        XCTAssertNil(workspace.healthImports.records[watch.id])
    }

    /// Item 2: an activity they changed stays when Health deletes its workout
    /// and a better source covers its time, and nothing is added beside it.
    func testAnActivityTheyChangedStaysWhenDeletedOrOutranked() async throws {
        let run = workout(source: "com.example.runs")
        client.workouts = [run]
        let history = model()
        await history.begin(.workouts)
        await history.confirm()
        let id = HealthHistory.activityID(for: run.id, accountID: "history")
        activities.prints[id] = "they changed the minutes"
        var watch = workout(source: "com.apple.health.watch")
        watch.start = run.start.addingTimeInterval(60)
        client.workouts = [watch]
        await history.refresh()
        XCTAssertEqual(activities.states[id], false)
        XCTAssertTrue(activities.deleted.isEmpty)
        XCTAssertEqual(activities.saved.count, 1, "The watch's isn't added beside theirs")
    }

    /// Item 8: offline just after a reinstall, nothing is added while the
    /// account can't be checked, so nothing is sent twice and needs attention;
    /// online, one already in the account is found, and only the new one is added.
    func testOfflineAfterAReinstallAddsNothingUntilTheAccountIsReached() async throws {
        let synced = workout(), fresh = workout(daysAgo: 1)
        activities.remote[HealthHistory.activityID(for: synced.id, accountID: "history")] = false
        client.workouts = [synced, fresh]
        activities.reachable = false
        let history = model()
        await history.begin(.workouts)
        XCTAssertEqual(history.pending?.preview.adding, 0)
        XCTAssertNotNil(history.pending?.note)
        await history.confirm()
        XCTAssertTrue(activities.saved.isEmpty)
        activities.reachable = true
        await history.refresh()
        XCTAssertEqual(activities.saved.map(\.clientID), [HealthHistory.activityID(for: fresh.id, accountID: "history")])
    }

    /// Item 5: turning reading off while Health is read saves nothing from that read.
    func testTurningReadingOffDuringARefreshSavesNothing() async throws {
        client.foods = [food(8, "com.example.tracker")]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods.append(food(12, "com.example.tracker"))
        client.onRead = { history.turnOff(.foods) }
        await history.refresh()
        XCTAssertEqual(workspace.nutrition.entries.count, 1)
    }

    // MARK: Review 5

    /// A deletion read while changes are being applied is listed after them, never lost.
    func testADeletionReadWhileChangesAreAppliedStaysListed() async throws {
        let soup = food(12, "com.example.tracker"), toast = food(8, "com.example.tracker")
        client.foods = [soup, toast]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods = [toast]
        await history.refresh()
        client.foods = []
        let reading = model()
        async let applying: Void = history.applyChanges()
        async let read: Void = reading.refresh()
        _ = await (applying, read)
        XCTAssertFalse(workspace.nutrition.entries.contains { $0.id == soup.id })
        XCTAssertEqual(workspace.healthImports.queue.entries.map(\.id), [toast.id], "Toast's deletion still waits")
    }

    /// Phone A applies a change both phones listed and syncs: phone B's card
    /// and Today's row don't show it, and its list is pruned.
    func testAChangeAppliedOnAnotherPhoneLeavesThisPhonesCardAndToday() async throws {
        let server = MemoryDocumentServer()
        let phoneA = try XCTUnwrap(workspace)
        phoneA.resumeSync(api: AccountAPI(accountID: "history", transport: server))
        let phoneB = try TrainingWorkspace(accountID: "history", root: temporaryRoot(), api: AccountAPI(accountID: "history", transport: server))
        let soup = food(12, "com.example.tracker")
        let healthB = FakeHistoryClient()
        healthB.foods = [soup]
        install = "phone-b"
        let historyB = model(defaults: UserDefaults(suiteName: "b-\(UUID().uuidString)"), on: phoneB, client: healthB)
        await historyB.begin(.foods)
        await historyB.confirm()
        try await phoneB.sync?.sync()
        try await phoneA.sync?.sync()
        // A keeps it as its own, before syncing again.
        install = "this-phone"
        client.foods = [soup]
        let historyA = model(on: phoneA)
        await historyA.checkEverythingAgain(.foods)
        await historyA.confirm(adopt: true)
        // Health deletes it: each phone lists it, each as its own.
        client.foods = []
        healthB.foods = []
        await historyA.refresh()
        await historyB.refresh()
        XCTAssertEqual(historyB.changeRows().count, 1)
        await historyA.applyChanges()
        try await phoneA.sync?.sync()
        try await phoneB.sync?.sync()
        XCTAssertFalse(phoneB.nutrition.entries.contains { $0.id == soup.id })
        XCTAssertTrue(historyB.changeRows().isEmpty, "B's card doesn't show")
        XCTAssertTrue(HealthChangeList.actionable(phoneB, activities: activities).isEmpty, "Nor does Today's row")
        await historyB.refresh()
        XCTAssertTrue(phoneB.healthImports.queue.isEmpty, "And B's list is pruned")
    }

    /// A read whose deletions don't all fit under the cap keeps its anchor;
    /// read again once there's room, nothing is lost.
    func testAFullListKeepsItsAnchorAndLosesNothing() async throws {
        let foods = (0..<3).map { food(8 + $0, "com.example.tracker", daysAgo: 1 + $0) }
        client.foods = foods
        let history = model(queueCap: 2)
        await history.begin(.foods)
        await history.confirm()
        client.foods = []
        await history.refresh()
        XCTAssertEqual(workspace.healthImports.queue.entries.count, 2)
        let held = try XCTUnwrap(client.anchorsSeen.last)
        await history.applyChanges()
        await history.refresh()
        XCTAssertEqual(client.anchorsSeen.last, held, "Read again from where the full list stopped it")
        XCTAssertEqual(workspace.healthImports.queue.entries.count, 1, "The third, listed once there's room")
        await history.applyChanges()
        XCTAssertTrue(workspace.nutrition.entries.isEmpty, "Nothing lost")
        await history.refresh()
        XCTAssertNotEqual(client.anchorsSeen.last, held, "Moved on once everything fitted")
    }

    /// A crash before or after each write of a workout's journal, adding it
    /// or taking it out, ends consistent once Exerly opens again.
    func testACrashAtEachStepOfAWorkoutJournalEndsConsistent() async throws {
        for (removing, before) in [(false, true), (false, false), (true, true), (true, false)] {
            try await setUp()
            let run = workout()
            let id = HealthHistory.activityID(for: run.id, accountID: "history")
            client.workouts = [run]
            let history = model()
            await history.begin(.workouts)
            func crash() { if before { activities.crashBeforeNextWrite = true } else { activities.crashAfterNextWrite = true } }
            if !removing { crash() }
            await history.confirm()
            if removing {
                client.workouts = []
                await history.refresh()
                crash()
                await history.applyChanges()
            }
            workspace = try TrainingWorkspace(accountID: "history", root: root)
            await model().refresh()
            XCTAssertNil(try workspace.healthImports.pendingWork())
            let record = workspace.healthImports.records[run.id]
            if removing {
                XCTAssertEqual(activities.states[id], true, "\(before)")
                XCTAssertEqual(record?.state, .removed)
                XCTAssertTrue(workspace.healthImports.queue.isEmpty)
            } else {
                XCTAssertEqual(activities.states[id], false, "\(before)")
                XCTAssertEqual(record?.state, .imported)
                XCTAssertEqual(activities.saved.count, 1)
            }
        }
    }

    // MARK: Review 4

    /// Item 2, review 5: Health deleting a food with no one there takes
    /// nothing out: it waits as one small reference to it.
    func testAHealthDeletionTakesNothingOutAndWaitsAsOneChange() async throws {
        let soup = food(12, "com.example.tracker")
        client.foods = [soup]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        let record = try XCTUnwrap(workspace.healthImports.records[soup.id])
        client.foods = []
        await history.refresh()
        XCTAssertTrue(workspace.nutrition.entries.contains { $0.id == soup.id }, "Still in the diary")
        XCTAssertEqual(workspace.healthImports.queue.entries,
                       [HealthChangeQueue.Entry(kind: .food, id: soup.id, target: soup.id.uuidString, fingerprint: record.fingerprint, reason: .deleted)])
        XCTAssertEqual(history.changeRows().map(\.detail), ["Deleted in Health: takes it out of your diary."])
    }

    /// Review 5: Apply changes takes out exactly what was listed, as this
    /// iPhone's a generation on, and drops a change whose entry they edited.
    func testApplyingTakesOutExactlyWhatWasListedAndDropsWhatTheyChanged() async throws {
        let soup = food(12, "com.example.tracker"), toast = food(8, "com.example.tracker"), tea = food(16, "com.example.tracker")
        client.foods = [soup, toast, tea]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        let before = try XCTUnwrap(workspace.healthImports.records[soup.id])
        client.foods = [tea]
        await history.refresh()
        XCTAssertEqual(Set(workspace.healthImports.queue.entries.map(\.id)), [soup.id, toast.id])
        var edited = try XCTUnwrap(workspace.nutrition.entries.first { $0.id == toast.id })
        edited.grams = 150
        try workspace.nutrition.saveEntry(edited)
        XCTAssertEqual(history.changeRows().map(\.id), [soup.id], "Changed since: not shown")
        await history.applyChanges()
        XCTAssertEqual(Set(workspace.nutrition.entries.map(\.id)), [toast.id, tea.id])
        let after = try XCTUnwrap(workspace.healthImports.records[soup.id])
        XCTAssertEqual(after.state, .removed)
        XCTAssertEqual(after.owner, "this-phone")
        XCTAssertEqual(after.generation, before.generation + 1)
        XCTAssertEqual(workspace.healthImports.records[toast.id]?.state, .imported)
        XCTAssertTrue(workspace.healthImports.queue.isEmpty, "The edited one is dropped")
    }

    /// Review 5: Keep everything dismisses exactly the changes shown, and a
    /// deletion read later is listed on its own.
    func testKeepEverythingDismissesExactlyTheChangesShown() async throws {
        let soup = food(12, "com.example.tracker"), toast = food(8, "com.example.tracker")
        client.foods = [soup, toast]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods = [toast]
        await history.refresh()
        history.keepEverything()
        XCTAssertTrue(workspace.healthImports.queue.isEmpty)
        XCTAssertEqual(workspace.nutrition.entries.count, 2, "Both kept")
        client.foods = []
        await history.refresh()
        XCTAssertEqual(workspace.healthImports.queue.entries.map(\.id), [toast.id])
    }

    /// Item 3: a crash just after a removal is written down, before the
    /// activity changes: the next open takes out the right activity, or,
    /// if they changed it meanwhile, keeps it and drops the removal.
    func testACrashBeforeARemovalIsMadeTakesOutTheRightActivityOrKeepsAChangedOne() async throws {
        for edited in [false, true] {
            try await setUp()
            let run = workout()
            let id = HealthHistory.activityID(for: run.id, accountID: "history")
            client.workouts = [run]
            let history = model()
            await history.begin(.workouts)
            await history.confirm()
            client.workouts = []
            await history.refresh()
            activities.crashBeforeNextWrite = true
            await history.applyChanges()
            XCTAssertEqual(activities.states[id], false, "Nothing changed before the crash")
            if edited { activities.prints[id] = "they changed the minutes" }
            workspace = try TrainingWorkspace(accountID: "history", root: root)
            await model().refresh()
            XCTAssertNil(try workspace.healthImports.pendingWork())
            if edited {
                XCTAssertEqual(activities.states[id], false, "Theirs now")
                XCTAssertEqual(workspace.healthImports.records[run.id]?.state, .imported)
            } else {
                XCTAssertEqual(activities.deleted, [id])
                XCTAssertEqual(workspace.healthImports.records[run.id]?.state, .removed)
            }
        }
    }

    // MARK: Review 3

    /// Item 2: a phone that adopted another's import keeps it, even when the
    /// first phone, offline meanwhile, reads Health's deletion of it with
    /// its old ownership and later comes back online.
    func testAStaleOwnerNeverRemovesWhatAnotherPhoneAdopted() async throws {
        let server = MemoryDocumentServer()
        let phoneA = try XCTUnwrap(workspace)
        phoneA.resumeSync(api: AccountAPI(accountID: "history", transport: server))
        let phoneB = try TrainingWorkspace(accountID: "history", root: temporaryRoot(), api: AccountAPI(accountID: "history", transport: server))
        let soup = food(12, "com.example.tracker")
        client.foods = [soup]
        let historyA = model()
        await historyA.begin(.foods)
        await historyA.confirm()
        try await phoneA.sync?.sync()

        // B, with the same Health data, keeps it as its own and syncs.
        try await phoneB.sync?.sync()
        XCTAssertEqual(phoneB.healthImports.records[soup.id]?.owner, "this-phone")
        let healthB = FakeHistoryClient()
        healthB.foods = [soup]
        install = "phone-b"
        let historyB = model(defaults: UserDefaults(suiteName: "b-\(UUID().uuidString)"), on: phoneB, client: healthB)
        await historyB.checkEverythingAgain(.foods)
        XCTAssertEqual(historyB.pending?.preview.adoptable, 1)
        await historyB.confirm(adopt: true)
        try await phoneB.sync?.sync()

        // A, offline all the while, reads Health deleting it; then it's back online.
        server.offline = true
        client.foods = []
        await historyA.refresh()
        server.offline = false
        try await phoneA.sync?.sync()
        await historyA.refresh()
        try await phoneA.sync?.sync()
        try await phoneB.sync?.sync()
        XCTAssertTrue(phoneB.nutrition.entries.contains { $0.id == soup.id }, "B's soup is still there")
        XCTAssertEqual(phoneB.healthImports.records[soup.id]?.owner, "phone-b")
        XCTAssertEqual(phoneB.healthImports.records[soup.id]?.state, .imported)
        XCTAssertEqual(phoneA.healthImports.records[soup.id]?.owner, "phone-b")
    }

    /// Item 3: a crash between saving a workout's activity and its record,
    /// adding it or taking it out, leaves nothing half done once Exerly opens again.
    func testACrashBetweenAnActivityAndItsRecordIsFinishedOnTheNextOpen() async throws {
        let run = workout()
        let id = HealthHistory.activityID(for: run.id, accountID: "history")
        client.workouts = [run]
        let history = model()
        await history.begin(.workouts)
        activities.crashAfterNextWrite = true
        await history.confirm()
        XCTAssertEqual(activities.states[id], false, "The activity was saved before the crash")

        workspace = try TrainingWorkspace(accountID: "history", root: root)
        await model().refresh()
        let record = try XCTUnwrap(workspace.healthImports.records[run.id], "Its record is saved on the next open")
        XCTAssertEqual(record.state, .imported)
        XCTAssertEqual(record.target, id)
        XCTAssertEqual(record.owner, "this-phone")
        XCTAssertEqual(activities.saved.count, 1, "Never saved twice")

        client.workouts = []
        let reading = model()
        await reading.refresh()
        activities.crashAfterNextWrite = true
        await reading.applyChanges()
        XCTAssertEqual(activities.states[id], true, "Taken out before the crash")
        workspace = try TrainingWorkspace(accountID: "history", root: root)
        await model().refresh()
        XCTAssertEqual(workspace.healthImports.records[run.id]?.state, .removed)
    }

    /// A workout half saved before a crash is finished as the account opens
    /// again, its work read with the history off the main actor, without the
    /// Health screen opening.
    func testACrashedWorkoutImportIsFinishedAsTheAccountOpens() async throws {
        let run = workout()
        client.workouts = [run]
        let history = model()
        await history.begin(.workouts)
        activities.crashAfterNextWrite = true
        await history.confirm()
        XCTAssertNil(workspace.healthImports.records[run.id], "The crash came before its record")
        await workspace.close()

        let root = try XCTUnwrap(root), read = WorkRead()
        let account = AppAccountWorkspace(open: { api in
            try await TrainingWorkspace.open(accountID: api.accountID, root: root, api: nil) { try read.read($0) }
        }, finishHealthWork: { workspace in
            try? HealthWorkoutWork.recover(workspace, activities: self.activities, defaults: self.defaults)
        })
        await account.configure(AccountAPI(accountID: "history", transport: MemoryDocumentServer()))
        let opened = try XCTUnwrap(account.training)
        XCTAssertNotNil(read.work, "The work was read with the account's history")
        let record = try XCTUnwrap(opened.healthImports.records[run.id])
        XCTAssertEqual(record.state, .imported)
        XCTAssertEqual(record.target, HealthHistory.activityID(for: run.id, accountID: "history"))
        XCTAssertNil(try opened.healthImports.pendingWork())
        XCTAssertEqual(activities.saved.count, 1, "Never saved twice")
        XCTAssertNotNil(defaults.data(forKey: "healthHistory.test.history.anchor.workouts"), "Health's anchor moved on")
        workspace = opened
        XCTAssertTrue(model().enabled.contains(.workouts), "Reading workouts is on, as confirming turned it on")
        await opened.close()
    }

    /// Item 8: a food Health deleted is kept only as a tombstone, which still
    /// stops the same sample being imported again on a later read.
    func testAFoodTakenOutIsATombstoneThatNeverComesBack() async throws {
        let soup = food(12, "com.example.tracker"), toast = food(8, "com.example.tracker")
        client.foods = [soup, toast]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods = [toast]
        await history.refresh()
        await history.applyChanges()
        XCTAssertEqual(workspace.healthImports.records[soup.id]?.target, "", "Kept as a tombstone")
        client.foods = [toast, soup]
        await history.refresh()
        await history.checkEverythingAgain(.foods)
        XCTAssertEqual(history.pending?.preview.adding, 0)
        XCTAssertEqual(workspace.nutrition.entries.map(\.id), [toast.id])
    }

    /// Item 7: an export holds the account's Health import records, and
    /// restoring it brings each back with its owner, generation, fingerprint and state.
    func testAnExportKeepsHealthImportRecordsAndRestoringBringsThemBack() async throws {
        let soup = food(12, "com.example.tracker"), toast = food(8, "com.example.tracker", daysAgo: 2)
        client.foods = [soup, toast]
        let history = model()
        await history.begin(.foods)
        await history.confirm()
        client.foods = [soup]
        await history.refresh()
        await history.applyChanges()
        let records = workspace.healthImports.records
        XCTAssertEqual(records[toast.id]?.state, .removed)
        let export = try workspace.export(server: nil)
        let restored = try TrainingWorkspace(accountID: "restored", root: temporaryRoot())
        let options = HistoryImportReader.Options(timeZone: zone, unit: .kilograms)
        let parsed = try HistoryImportReader.read([("exerly-export.json", export)], options: options, library: restored.store.library)
        let plan = try HistoryImportReader.plan(parsed, files: ["exerly-export.json"], options: options, hosts: restored.documentHosts)
        try restored.importer.commit(plan)
        XCTAssertEqual(restored.healthImports.records, records)
    }
}

/// Health as a list of samples. An anchored read returns what was added
/// since the anchor and, as deletions, what's gone; a revoked one returns
/// nothing at all, as HealthKit does.
final class FakeHistoryClient: HealthHistoryClient, @unchecked Sendable {
    var available = true
    var foods: [HealthFoodReading] = []
    var workouts: [HealthWorkoutReading] = []
    var weightReadings: [(weight: HealthWeight, source: String)] = []
    var revoked = false
    var workoutReads = 0
    var anchorsSeen: [Data?] = []
    /// Runs while Health is read, before it answers.
    var onRead: (@MainActor () -> Void)?
    private var seen: [Data: Set<UUID>] = [:]

    var isAvailable: Bool { available }
    func requestAccess(_ kind: HealthHistoryKind) async throws {}

    private func changes<T>(_ all: [T], id: (T) -> UUID, after anchor: Data?) -> HealthChanges<T> {
        let next = Data(UUID().uuidString.utf8)
        guard !revoked else { return HealthChanges(anchor: next) }
        let before = anchor.flatMap { seen[$0] } ?? []
        let now = Set(all.map(id))
        seen[next] = now
        return HealthChanges(added: all.filter { !before.contains(id($0)) }, deleted: Array(before.subtracting(now)), anchor: next)
    }

    func foods(after anchor: Data?) async throws -> HealthChanges<HealthFoodReading> {
        anchorsSeen.append(anchor)
        await onRead?()
        return changes(foods, id: \.id, after: anchor)
    }

    func workouts(after anchor: Data?) async throws -> HealthChanges<HealthWorkoutReading> {
        workoutReads += 1
        await onRead?()
        return changes(workouts, id: \.id, after: anchor)
    }

    func foods(_ ids: Set<UUID>) async throws -> [HealthFoodReading] { revoked ? [] : foods.filter { ids.contains($0.id) } }

    func weights() async throws -> [(weight: HealthWeight, source: String)] { weightReadings }
}

@MainActor
final class FakeActivityStore: HealthActivityStore {
    let days: ClosedRange<LocalDate>
    /// On this phone: each true if deleted.
    var states: [String: Bool] = [:]
    /// In the account, read by `readActivities`.
    var remote: [String: Bool] = [:]
    /// Each activity's fingerprint; a change to one is an edit.
    var prints: [String: String] = [:]
    var reachable = true
    var saved: [(request: ActivityRequest, clientID: String)] = []
    var deleted: [String] = []
    var read: [ClosedRange<LocalDate>] = []
    /// Fails the next write after making it, as a crash right after it would.
    var crashAfterNextWrite = false
    /// Fails the next write before making it, as a crash just before it would.
    var crashBeforeNextWrite = false
    struct Crash: Error {}

    init(today: LocalDate) { days = today.adding(days: -3650)...today }

    func activityStates(_ ids: Set<String>) -> [String: Bool] { states.filter { ids.contains($0.key) } }

    func activityFingerprint(_ clientID: String) -> String? { states[clientID] == false ? prints[clientID, default: "as imported"] : nil }

    func readActivities(_ days: ClosedRange<LocalDate>) async -> Bool {
        read.append(days)
        guard reachable else { return false }
        states.merge(remote) { local, _ in local }
        return true
    }

    func saveImportedActivity(_ request: ActivityRequest, clientID: String) throws {
        if crashBeforeNextWrite {
            crashBeforeNextWrite = false
            throw Crash()
        }
        saved.append((request, clientID))
        states[clientID] = false
        try crashIfAsked()
    }

    func deleteImportedActivity(clientID: String) throws {
        if crashBeforeNextWrite {
            crashBeforeNextWrite = false
            throw Crash()
        }
        deleted.append(clientID)
        states[clientID] = true
        try crashIfAsked()
    }

    private func crashIfAsked() throws {
        guard crashAfterNextWrite else { return }
        crashAfterNextWrite = false
        throw Crash()
    }
}

/// The API's document endpoints in memory, shared by phones: revisions,
/// conflicts that carry the current version, and the change feed.
final class MemoryDocumentServer: SessionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: (revision: Int, payload: Any?)] = [:]
    private var feed: [[String: Any]] = []
    private var isOffline = false

    var offline: Bool {
        get { lock.withLock { isOffline } }
        set { lock.withLock { isOffline = newValue } }
    }

    func send(_ method: String, path: String, body: Data?, headers: [String: String],
              as accountID: String) async throws -> (status: Int, data: Data) {
        try lock.withLock {
            if isOffline { throw URLError(.notConnectedToInternet) }
            let url = try XCTUnwrap(URLComponents(string: "https://exerly.test" + path))
            let query = { (name: String) in Int(url.queryItems?.first { $0.name == name }?.value ?? "") ?? 0 }
            if method == "GET", url.path == "/v1/changes" {
                let changes = feed.filter { ($0["sequence"] as? Int ?? 0) > query("after") }
                return (200, try JSONSerialization.data(withJSONObject: ["changes": changes, "cursor": feed.count, "has_more": false]))
            }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[1] == "documents" else { return (404, Data(#"{"message":"Not found"}"#.utf8)) }
            let kind = parts[2], id = UUID(uuidString: parts[3])?.uuidString ?? parts[3]
            let current = documents["\(kind)/\(id)"]
            func document(_ revision: Int, _ payload: Any?, sequence: Int? = nil) -> [String: Any] {
                var document: [String: Any] = ["kind": kind, "id": id, "revision": revision, "deleted": payload == nil]
                document["payload"] = payload
                document["sequence"] = sequence
                return document
            }
            let base: Int, payload: Any?
            if method == "PUT" {
                let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
                (base, payload) = (json["base_revision"] as? Int ?? 0, json["payload"])
            } else {
                guard current?.payload != nil else { return (404, Data(#"{"message":"Document not found"}"#.utf8)) }
                (base, payload) = (query("base_revision"), nil)
            }
            guard base == (current?.revision ?? 0) else {
                let details: [String: Any] = current.map { ["document": document($0.revision, $0.payload)] } ?? [:]
                return (409, try JSONSerialization.data(withJSONObject: ["message": "Changed elsewhere", "details": details]))
            }
            documents["\(kind)/\(id)"] = (base + 1, payload)
            feed.append(document(base + 1, payload, sequence: feed.count + 1))
            return (200, try JSONSerialization.data(withJSONObject: ["revision": base + 1]))
        }
    }
}

/// What an account's opening read, to check the work came with its history.
private final class WorkRead: @unchecked Sendable {
    private(set) var work: Data?

    func read(_ url: URL) throws -> StoredAccount? {
        let stored = try StoredAccount.read(url: url)
        work = stored?.healthImportWork
        return stored
    }
}
