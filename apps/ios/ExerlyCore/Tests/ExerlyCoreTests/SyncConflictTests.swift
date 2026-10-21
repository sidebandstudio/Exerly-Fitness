import Foundation
import Testing
@testable import ExerlyCore

/// A clock that moves a second each time it's read, so every conflict
/// change has its own time.
final class TickingClock {
    private var current = Fixture.instant()
    func now() -> Date {
        current += 1
        return current
    }
}

/// One device of one account: its store, its conflicts and its sync engine.
@MainActor
final class AccountDevice {
    let disk: InMemoryTrainingPersistence
    let nutrition: NutritionStore
    let conflicts: SyncConflictStore
    let sync: SyncEngine

    init(_ name: String, server: FakeDocumentServer, clock: TickingClock, disk: InMemoryTrainingPersistence = InMemoryTrainingPersistence()) throws {
        self.disk = disk
        nutrition = try NutritionStore(persistence: disk, now: { Fixture.instant() })
        conflicts = SyncConflictStore(state: disk, hosts: [nutrition], deviceName: name, now: clock.now)
        sync = SyncEngine(hosts: [nutrition], state: disk, api: server, conflicts: conflicts, now: clock.now)
    }

    func entry(_ id: UUID) -> FoodEntry? { nutrition.entries.first { $0.id == id } }
}

@MainActor
@Suite struct SyncConflictTests {
    let monday = LocalDate("2026-10-05")!

    private func json(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    // MARK: Merge

    @Test func editsToDifferentFieldsMergeAndTheSameFieldIsReported() {
        let base = json(["grams": .number(40), "meal": .string("Breakfast"), "notes": .string("")])
        let phone = json(["grams": .number(60), "meal": .string("Breakfast"), "notes": .string("")])
        let tablet = json(["grams": .number(40), "meal": .string("Lunch"), "notes": .string("")])
        let merged = Merge.fields(base: base, local: phone, remote: tablet)
        #expect(merged.merged == json(["grams": .number(60), "meal": .string("Lunch"), "notes": .string("")]))
        #expect(merged.conflicts.isEmpty)

        let other = json(["grams": .number(90), "meal": .string("Lunch"), "notes": .string("")])
        let both = Merge.fields(base: base, local: phone, remote: other)
        #expect(both.conflicts == ["grams"], "Both changed grams; the meal merged")
        #expect(both.merged == json(["grams": .number(60), "meal": .string("Lunch"), "notes": .string("")]))
        let theirs = Merge.fields(base: base, local: phone, remote: other, preferring: .remote)
        #expect(theirs.merged == other && theirs.conflicts == ["grams"])
    }

    @Test func groupedFieldsMergeTogetherAndAMissingBaseTakesWhatOneSideAdded() {
        let base = json(["grams": .number(40), "quantity": .number(1)])
        // One side typed grams; the other changed the serving count, which
        // also set grams: one amount changed twice, not two fields.
        let typed = json(["grams": .number(55), "quantity": .number(1)])
        let counted = json(["grams": .number(80), "quantity": .number(2)])
        let merged = Merge.fields(base: base, local: typed, remote: counted, groups: [["grams", "quantity"]])
        #expect(merged.conflicts == ["grams"] && merged.merged == typed)
        let added = Merge.fields(base: nil, local: json(["notes": .string("a")]), remote: json(["tags": .array([])]))
        #expect(added.conflicts.isEmpty && added.merged == json(["notes": .string("a"), "tags": .array([])]))
    }

    @Test func aSetDeletedOnOneSideAndEditedOnTheOtherIsReported() throws {
        let set = Fixture.set(5, 100)
        let original = WorkoutSession(name: "Push", startedAt: Fixture.instant(), timeZone: Fixture.utc,
                                      exercises: [PerformedExercise(exerciseID: "bench-press", sets: [set])])
        var deleted = original
        deleted.exercises[0].sets = []
        var edited = original
        edited.exercises[0].sets[0].rir = 2
        // Found by sync, the edited set stays whichever side deleted it.
        for (local, remote) in [(deleted, edited), (edited, deleted)] {
            let found = Merge.session(base: original, local: local, remote: remote, preferring: .local)
            #expect(found.merged.exercises[0].sets.map(\.rir) == [2] && found.conflicts.count == 1)
        }
        // A resolution follows the chosen side.
        #expect(Merge.session(base: original, local: edited, remote: deleted, preferring: .remote).merged.exercises[0].sets.isEmpty)
    }

    // MARK: Two devices

    @Test func editsToDifferentFieldsOfOneEntryBothApply() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try await phone.sync.sync()
        try await tablet.sync.sync()
        var onPhone = try #require(phone.entry(logged.id)), onTablet = try #require(tablet.entry(logged.id))
        onPhone.grams = 60
        onTablet.meal = "Lunch"
        try phone.nutrition.saveEntry(onPhone)
        try tablet.nutrition.saveEntry(onTablet)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
        for device in [phone, tablet] {
            #expect(device.entry(logged.id)?.grams == 60 && device.entry(logged.id)?.meal == "Lunch")
            #expect(device.conflicts.conflicts.isEmpty)
        }
    }

    /// Both change the amount: the tablet, syncing second, keeps its 90 g and
    /// records the phone's 60 g; the conflict reaches the phone, which picks
    /// 60 g, and both end with 60 g and a resolved conflict. Undo reopens it.
    @Test func theSameFieldChangedOnTwoDevicesWaitsForAReviewAndItsResolutionSyncs() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try await phone.sync.sync()
        try await tablet.sync.sync()
        var onPhone = try #require(phone.entry(logged.id)), onTablet = try #require(tablet.entry(logged.id))
        onPhone.grams = 60
        onTablet.grams = 90
        try phone.nutrition.saveEntry(onPhone)
        try tablet.nutrition.saveEntry(onTablet)
        for device in [phone, tablet, phone] { try await device.sync.sync() }

        let conflict = try #require(tablet.conflicts.unresolved.first)
        #expect(tablet.entry(logged.id)?.grams == 90 && phone.entry(logged.id)?.grams == 90)
        #expect(conflict.fields == ["grams"] && phone.conflicts.unresolved.map(\.id) == [conflict.id])
        let words = conflict.summary(on: tablet.conflicts.device, unit: .kilograms, timeZone: Fixture.utc, locale: Locale(identifier: "en_US"))
        #expect(words.title == "Rolled oats" && words.local.device == "This iPad" && words.local.value == "90 g")
        #expect(words.remote.device == "Another device" && words.remote.value == "60 g")
        #expect(words.explanation == "Both devices changed the amount.")
        #expect(words.options.map(\.title) == ["Keep this iPad's", "Keep the other device's", "Keep both"])
        #expect(words.options.map(\.done) == ["Kept this iPad's", "Kept the other device's", "Kept both"])
        #expect(conflict.summary(on: phone.conflicts.device, unit: .kilograms, timeZone: Fixture.utc).local.device == "iPad")

        try phone.conflicts.resolve(conflict.id, .remote)
        #expect(phone.entry(logged.id)?.grams == 60 && phone.conflicts.unresolved.isEmpty)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(tablet.entry(logged.id)?.grams == 60 && tablet.conflicts.conflict(conflict.id)?.resolution?.choice == .remote)
        #expect(tablet.conflicts.unresolved.isEmpty && tablet.entry(logged.id)?.meal == "Breakfast")

        try phone.conflicts.undo()
        #expect(phone.entry(logged.id)?.grams == 90 && phone.conflicts.unresolved.map(\.id) == [conflict.id])
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(tablet.entry(logged.id)?.grams == 90 && tablet.conflicts.unresolved.map(\.id) == [conflict.id])
    }

    @Test func keepingBothMakesTwoEntriesAndUndoRemovesTheCopy() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try await phone.sync.sync()
        try await tablet.sync.sync()
        var onPhone = try #require(phone.entry(logged.id)), onTablet = try #require(tablet.entry(logged.id))
        onPhone.grams = 60
        onTablet.grams = 90
        try phone.nutrition.saveEntry(onPhone)
        try tablet.nutrition.saveEntry(onTablet)
        try await phone.sync.sync()
        try await tablet.sync.sync()
        let conflict = try #require(tablet.conflicts.unresolved.first)
        #expect(throws: SyncConflictStore.ResolveError.notOpen) { try tablet.conflicts.resolve(UUID(), .both) }
        try tablet.conflicts.resolve(conflict.id, .both)
        #expect(tablet.nutrition.entries.map(\.grams).sorted() == [60, 90])
        try await tablet.sync.sync()
        try await phone.sync.sync()
        #expect(phone.nutrition.entries.map(\.grams).sorted() == [60, 90])
        try tablet.conflicts.undo()
        #expect(tablet.nutrition.entries.map(\.grams) == [90] && tablet.conflicts.unresolved.count == 1)
    }

    /// The phone deletes an entry the tablet changed. It stays deleted on
    /// both, and the tablet's version waits to be brought back.
    @Test func deletedHereAndChangedThereStaysDeletedUntilBroughtBack() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try await phone.sync.sync()
        try await tablet.sync.sync()
        var onTablet = try #require(tablet.entry(logged.id))
        onTablet.grams = 60
        try tablet.nutrition.saveEntry(onTablet)
        try await tablet.sync.sync()
        try phone.nutrition.deleteEntry(logged.id)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(phone.entry(logged.id) == nil && tablet.entry(logged.id) == nil, "Nothing comes back on its own")
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(conflict.local == nil && conflict.choices == [.local, .remote])
        let words = conflict.summary(on: phone.conflicts.device, unit: .kilograms, timeZone: Fixture.utc)
        #expect(words.explanation == "Deleted on this iPhone, changed on another device.")
        #expect(words.local.value == "Deleted" && words.remote.value == "60 g")
        #expect(words.options.map(\.title) == ["Keep it deleted", "Bring back the other device's version"])
        #expect(tablet.conflicts.unresolved.map(\.id) == [conflict.id])

        try tablet.conflicts.resolve(conflict.id, .remote)
        for device in [tablet, phone] { try await device.sync.sync() }
        #expect(phone.entry(logged.id)?.grams == 60 && tablet.entry(logged.id)?.grams == 60)
        #expect(phone.conflicts.unresolved.isEmpty)
    }

    /// The reverse: changed here, deleted there. The deletion stands here
    /// too, and this device's change waits for review.
    @Test func changedHereAndDeletedThereIsDeletedAndKeptForReview() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let logged = try phone.nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try await phone.sync.sync()
        try await tablet.sync.sync()
        try tablet.nutrition.deleteEntry(logged.id)
        try await tablet.sync.sync()
        var onPhone = try #require(phone.entry(logged.id))
        onPhone.grams = 75
        try phone.nutrition.saveEntry(onPhone)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(phone.entry(logged.id) == nil && tablet.entry(logged.id) == nil)
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(conflict.remote == nil && conflict.choices == [.remote, .local])
        let words = conflict.summary(on: phone.conflicts.device, unit: .kilograms, timeZone: Fixture.utc)
        #expect(words.options.map(\.title) == ["Keep it deleted", "Bring back this iPhone's version"])
        try phone.conflicts.resolve(conflict.id, .remote)
        #expect(phone.entry(logged.id) == nil)
        try phone.conflicts.undo()
        try phone.conflicts.resolve(conflict.id, .local)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(tablet.entry(logged.id)?.grams == 75)
    }

    @Test func weighInsConflictAndReadInTheChosenUnit() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let reading = try phone.nutrition.logWeight(.kg(80.4), at: Fixture.instant(), timeZone: Fixture.utc)
        try await phone.sync.sync()
        try await tablet.sync.sync()
        var mine = reading, theirs = reading
        mine.weight = .kg(80.0)
        theirs.weight = .kg(81.0)
        theirs.bodyFat = 0.2
        try phone.nutrition.commit(NutritionStore.weightKind, reading.id.uuidString, mine)
        try tablet.nutrition.commit(NutritionStore.weightKind, reading.id.uuidString, theirs)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
        let conflict = try #require(phone.conflicts.unresolved.first)
        #expect(conflict.fields == ["weight"], "Body fat merged; only the weight conflicts")
        #expect(phone.nutrition.weights.first?.bodyFat == 0.2 && tablet.nutrition.weights.first?.weight == .kg(81.0))
        let words = conflict.summary(on: SyncDevice(id: UUID(), name: "iPhone"), unit: .pounds, timeZone: Fixture.utc,
                                     locale: Locale(identifier: "en_US"))
        #expect(words.title == "Weigh-in" && words.local.value == "178.6 lb" && words.remote.value == "176.4 lb")
        try phone.conflicts.resolve(conflict.id, .both)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(tablet.nutrition.weights.map(\.weight.value).sorted() == [80.0, 81.0])
    }

    @Test func plansMergeFieldByFieldAndConflictOnTheSameField() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock), tablet = try AccountDevice("iPad", server: server, clock: clock)
        let plan = try NutritionPlan(startDate: monday, goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80))
        try phone.nutrition.commit(NutritionStore.planKind, plan.id.uuidString, plan)
        try await phone.sync.sync()
        try await tablet.sync.sync()
        var mine = plan, theirs = plan
        mine.goal = NutritionGoal(.lose, weeklyRate: 0.0075)
        theirs.goal = NutritionGoal(.maintain)
        try phone.nutrition.commit(NutritionStore.planKind, plan.id.uuidString, mine)
        try tablet.nutrition.commit(NutritionStore.planKind, plan.id.uuidString, theirs)
        for device in [phone, tablet, phone] { try await device.sync.sync() }
        let conflict = try #require(tablet.conflicts.unresolved.first)
        #expect(conflict.fields == ["goal"] && conflict.choices == [.local, .remote])
        #expect(phone.nutrition.plans.first?.goal == theirs.goal)
        try phone.conflicts.resolve(conflict.id, .remote)
        for device in [phone, tablet] { try await device.sync.sync() }
        #expect(tablet.nutrition.plans.first?.goal == mine.goal)
    }

    /// The workout in progress isn't taken away when another device
    /// deletes it; the deletion waits for review instead.
    @Test func theWorkoutInProgressStaysWhenDeletedElsewhere() async throws {
        let server = FakeDocumentServer()
        let phoneDisk = InMemoryTrainingPersistence(), tabletDisk = InMemoryTrainingPersistence()
        let phone = try TrainingStore(persistence: phoneDisk), tablet = try TrainingStore(persistence: tabletDisk)
        let phoneSync = SyncEngine(store: phone, state: phoneDisk, api: server)
        let tabletSync = SyncEngine(store: tablet, state: tabletDisk, api: server)
        try phone.startSession(name: "Pull", bodyweight: nil)
        try phone.addExercise("deadlift")
        let id = try #require(phone.activeSession?.id)
        try await phoneSync.sync()
        try await tabletSync.sync()
        #expect(tablet.activeSession?.id == id)
        try tablet.discardSession()
        try await tabletSync.sync()
        try phone.addExercise("barbell-row")
        try await phoneSync.sync()
        #expect(phone.activeSession?.exercises.count == 2)
        #expect(phoneSync.conflicts.unresolved.first?.remote == nil)
    }

    // MARK: Durable and per account

    @Test func conflictsSurviveARelaunchAndStayWithTheirAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-conflicts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let urlA = directory.appendingPathComponent("a.sqlite"), urlB = directory.appendingPathComponent("b.sqlite")
        let server = FakeDocumentServer(), otherServer = FakeDocumentServer(), clock = TickingClock()
        let tablet = try AccountDevice("iPad", server: server, clock: clock)
        var conflictID: UUID?
        var device: SyncDevice?
        do {
            let disk = try SQLiteTrainingPersistence(url: urlA)
            let nutrition = try NutritionStore(persistence: disk)
            let conflicts = SyncConflictStore(state: disk, hosts: [nutrition], now: clock.now)
            let sync = SyncEngine(hosts: [nutrition], state: disk, api: server, conflicts: conflicts)
            let logged = try nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
            try await sync.sync()
            try await tablet.sync.sync()
            var theirs = try #require(tablet.entry(logged.id)), mine = logged
            theirs.grams = 90
            mine.grams = 60
            try tablet.nutrition.saveEntry(theirs)
            try await tablet.sync.sync()
            try nutrition.saveEntry(mine)
            try await sync.sync()
            conflictID = conflicts.unresolved.first?.id
            device = conflicts.device
            // Account B on the same phone, with its own store and server.
            let other = try SQLiteTrainingPersistence(url: urlB)
            let otherNutrition = try NutritionStore(persistence: other)
            let otherConflicts = SyncConflictStore(state: other, hosts: [otherNutrition])
            try await SyncEngine(hosts: [otherNutrition], state: other, api: otherServer, conflicts: otherConflicts).sync()
            #expect(otherConflicts.conflicts.isEmpty && otherConflicts.device.id != conflicts.device.id)
        }
        let id = try #require(conflictID)
        let disk = try SQLiteTrainingPersistence(url: urlA)
        let nutrition = try NutritionStore(persistence: disk)
        let conflicts = SyncConflictStore(state: disk, hosts: [nutrition], now: clock.now)
        #expect(conflicts.unresolved.map(\.id) == [id] && conflicts.device == device)
        try conflicts.resolve(id, .remote)
        #expect(nutrition.entries.first?.grams == 90)
        #expect(try SQLiteTrainingPersistence(url: urlB).syncConflicts().isEmpty)
        #expect(otherServer.revision(SyncConflictStore.kind, id.uuidString) == nil, "Account B's server never saw it")
    }

    // MARK: Randomized

    /// Two devices edit amounts and meals, delete, log, sync, resolve and
    /// undo at random. Every sync keeps every edit either applied or in a
    /// conflict, and once both have synced they agree. An edit that matches
    /// a version the other device wrote and then changed again isn't a
    /// conflict: that device saw it and moved on.
    @Test func twoDevicesNeverLoseAnEditSilently() async throws {
        for seed in 0..<120 { try await run(seed: UInt64(seed)) }
    }

    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
        mutating func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[next(values.count)] }
    }

    private static let amount = ["grams", "serving", "quantity", "amountChanged"]

    private func run(seed: UInt64) async throws {
        var random = Random(state: seed &+ 0xC0FF1C7)
        let server = FakeDocumentServer(), clock = TickingClock()
        let devices = [try AccountDevice("iPhone", server: server, clock: clock), try AccountDevice("iPad", server: server, clock: clock)]
        for _ in 0..<3 { try devices[0].nutrition.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast") }
        for device in devices { try await device.sync.sync() }
        let kind = NutritionStore.entryKind
        var steps: [String] = []
        func name(_ device: AccountDevice) -> String { device === devices[0] ? "phone" : "tablet" }

        func fields(_ value: JSONValue?, _ keys: [String]) -> [String: JSONValue]? {
            guard case .object(let all)? = value else { return nil }
            return all.filter { keys.contains($0.key) }
        }
        func current(_ device: AccountDevice, _ id: String) throws -> JSONValue? {
            try device.nutrition.payload(kind: kind, id: id).map(JSONValue.init(data:))
        }
        /// An edit is kept when the device shows it or one of its conflicts
        /// holds it, or the other device wrote it too before changing it again.
        func kept(_ device: AccountDevice, _ id: String, _ keys: [String], _ value: [String: JSONValue]?,
                  superseded: [JSONValue?]) throws -> Bool {
            if superseded.contains(where: { fields($0, keys) == value }) { return true }
            let shown = try current(device, id)
            if value == nil { return shown == nil || device.conflicts.conflicts.contains { $0.documentID == id && $0.isDeletion } }
            if fields(shown, keys) == value { return true }
            return device.conflicts.conflicts.contains { conflict in
                conflict.documentID == id && (fields(conflict.local, keys) == value || fields(conflict.remote, keys) == value)
            }
        }
        func sync(_ device: AccountDevice) async throws {
            let bases = Dictionary(try device.disk.syncBases().filter { $0.kind == kind }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var edits: [(id: String, keys: [String], value: [String: JSONValue]?)] = []
            var superseded: [String: [JSONValue?]] = [:]
            let ids = Set(bases.keys).union(device.nutrition.entries.map(\.id.uuidString))
            for id in ids {
                let base = try bases[id]?.payload.map(JSONValue.init(data:))
                let mine = try current(device, id)
                let newer = server.history(kind, id).filter { $0.revision > (bases[id]?.revision ?? 0) }
                superseded[id] = try newer.dropLast().map { try $0.payload.map(JSONValue.init(data:)) }
                let theirs = try server.stored(kind, id).flatMap { stored in
                    stored.revision > (bases[id]?.revision ?? 0) ? .some(try stored.payload.map(JSONValue.init(data:))) : nil
                }
                for keys in [Self.amount, ["meal"]] {
                    if base != nil || mine != nil, fields(mine, keys) != fields(base, keys) { edits.append((id, keys, fields(mine, keys))) }
                    if let theirs, fields(theirs, keys) != fields(base, keys) { edits.append((id, keys, fields(theirs, keys))) }
                }
            }
            try await device.sync.sync()
            steps.append("sync \(name(device))")
            for edit in edits {
                func show(_ value: [String: JSONValue]?) -> String { value.map { String(describing: $0[edit.keys[0]] ?? .null) } ?? "deleted" }
                let held = device.conflicts.conflicts.filter { $0.documentID == edit.id }
                    .map { "\(show(fields($0.local, edit.keys)))/\(show(fields($0.remote, edit.keys)))" }
                let shown = show(fields(try current(device, edit.id), edit.keys))
                #expect(try kept(device, edit.id, edit.keys, edit.value, superseded: superseded[edit.id] ?? []),
                        """
                        seed \(seed): \(edit.keys[0]) \(show(edit.value)) of \(edit.id.prefix(4)) was lost after \(steps); \
                        shows \(shown), conflicts \(held)
                        """)
            }
        }

        for _ in 0..<30 {
            guard let device = random.pick(devices) else { continue }
            switch random.next(9) {
            case 0, 1:
                guard var entry = random.pick(device.nutrition.entries) else { continue }
                entry.grams = Double([30, 45, 60, 75, 90][random.next(5)])
                try device.nutrition.saveEntry(entry)
                steps.append("\(name(device)) \(entry.id.uuidString.prefix(4)) \(entry.grams) g")
            case 2:
                guard var entry = random.pick(device.nutrition.entries) else { continue }
                entry.meal = ["Breakfast", "Lunch", "Dinner"][random.next(3)]
                try device.nutrition.saveEntry(entry)
                steps.append("\(name(device)) \(entry.id.uuidString.prefix(4)) \(entry.meal)")
            case 3:
                guard let entry = random.pick(device.nutrition.entries) else { continue }
                try device.nutrition.deleteEntry(entry.id)
                steps.append("\(name(device)) deletes \(entry.id.uuidString.prefix(4))")
            case 4:
                try device.nutrition.log(Foods.milk, grams: 100, on: monday, meal: "Snacks")
            case 5, 6:
                try await sync(device)
            case 7:
                guard let conflict = random.pick(device.conflicts.unresolved), let choice = random.pick(conflict.choices) else { continue }
                try device.conflicts.resolve(conflict.id, choice)
                steps.append("\(name(device)) resolves \(conflict.documentID.prefix(4)) \(choice)")
            default:
                if device.conflicts.undoable != nil { steps.append("\(name(device)) undoes") }
                try device.conflicts.undo()
            }
        }
        for _ in 0..<3 { for device in devices { try await sync(device) } }
        let (a, b) = (devices[0], devices[1])
        #expect(a.nutrition.entries == b.nutrition.entries, "seed \(seed): the devices disagree")
        #expect(a.conflicts.conflicts == b.conflicts.conflicts, "seed \(seed): the conflicts disagree")
    }
}
