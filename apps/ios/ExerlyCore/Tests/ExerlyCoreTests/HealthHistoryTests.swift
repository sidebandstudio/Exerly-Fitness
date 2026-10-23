import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct HealthHistoryTests {
    let newYork = TimeZone(identifier: "America/New_York")!
    let tracker = "com.example.tracker", diary = "com.example.diary", watch = "com.apple.health.81E5A1B0"

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func food(_ day: Int, _ hour: Int, _ source: String, kcal: Double, name: String? = "Synthetic oats") -> HealthFoodReading {
        HealthFoodReading(id: UUID(), at: at(day, hour), name: name, nutrients: NutrientAmounts([.energy: kcal, .protein: 10]),
                          source: source, sourceName: source == tracker ? "Tracker" : "Diary")
    }

    let install = "phone-a"

    func item(_ food: HealthFoodReading) -> HealthItem { HealthHistory.item(food, timeZone: newYork) }

    /// A record of `food` imported by `owner`.
    func record(_ food: HealthFoodReading, owner: String = "phone-a", state: HealthImport.State = .imported) -> HealthImport {
        HealthImport(id: food.id, kind: .food, target: food.id.uuidString, owner: owner, source: food.source, sourceName: food.sourceName,
                     start: food.at, end: food.at, day: LocalDate(food.at, in: newYork), fingerprint: "f", state: state, updatedAt: at(1, 0))
    }

    func plan(_ added: [HealthFoodReading], deleted: Set<UUID> = [], full: Bool = false, records: [HealthImport] = [],
              live: Set<UUID>? = nil, changed: Set<UUID> = [], preferred: [String] = []) -> HealthImportPlan<HealthFoodReading> {
        HealthHistory.plan(added: added, deleted: deleted, full: full, records: records, install: install,
                           live: live ?? Set(records.map(\.id)), changed: changed, grouping: .day, preferred: preferred, item: item)
    }

    @Test func eachDaysFoodComesFromItsBestSourceAndIsPreviewedFirst() {
        // Oct 5: both apps saved the day; the tracker has more overall. Oct 6: only the diary.
        let foods = [food(5, 8, tracker, kcal: 300), food(5, 13, tracker, kcal: 600), food(6, 19, tracker, kcal: 700),
                     food(5, 8, diary, kcal: 310), food(7, 12, diary, kcal: 500)]
        let first = plan(foods, full: true, records: [record(foods[2])])
        #expect(Set(first.adding.map(\.id)) == [foods[0].id, foods[1].id, foods[4].id])
        #expect(first.preview.adding == 3 && first.preview.alreadyIn == 1 && first.preview.leftOut == 1)
        #expect(first.preview.first == LocalDate("2026-10-05") && first.preview.last == LocalDate("2026-10-07"))
        #expect(first.preview.sources == [.init(name: "Tracker", adding: 2, leftOut: 0), .init(name: "Diary", adding: 1, leftOut: 1)])
        #expect(Set(plan(foods, full: true, preferred: [diary]).adding.map(\.id)) == [foods[3].id, foods[2].id, foods[4].id],
                "the person's order wins")
    }

    @Test func aBetterSourceLaterDisplacesTheDayAndItComesBackWhenThatGoes() {
        let breakfast = food(5, 8, diary, kcal: 300), better = food(5, 8, tracker, kcal: 310)
        let displaced = plan([better], records: [record(breakfast)], preferred: [tracker])
        #expect(displaced.adding.map(\.id) == [better.id] && displaced.displacing == [breakfast.id] && displaced.removing.isEmpty)
        // The tracker's is deleted in Health: it goes, and the diary's comes back.
        let back = plan([], deleted: [better.id], records: [record(breakfast, state: .displaced), record(better)], preferred: [tracker])
        #expect(back.removing == [better.id] && back.restoring == [breakfast.id])
        // A worse source adds nothing to a day already held.
        #expect(plan([food(5, 9, diary, kcal: 1)], records: [record(better)], preferred: [tracker]).adding.isEmpty)
    }

    @Test func nothingIsTakenOutForBeingMissingOnlyForHealthsDeletions() {
        let soup = food(5, 12, tracker, kcal: 250), toast = food(5, 8, tracker, kcal: 120)
        let records = [record(soup), record(toast)]
        // A read that comes back empty, as a revoked one does.
        let empty = plan([], full: true, records: records)
        #expect(empty.removing.isEmpty && empty.displacing.isEmpty && empty.missing == [soup.id, toast.id].sorted { $0.uuidString < $1.uuidString })
        #expect(empty.preview.missing == 2)
        #expect(plan([], records: records).missing.isEmpty, "an anchored read lists nothing as missing")
        #expect(plan([], deleted: [soup.id], records: records).removing == [soup.id])
    }

    @Test func whatTheyChangedOrAnotherInstallImportedIsNeverTakenOut() {
        let breakfast = food(5, 8, diary, kcal: 300), better = food(5, 8, tracker, kcal: 310)
        let changed = plan([better], deleted: [breakfast.id], records: [record(breakfast)], changed: [breakfast.id], preferred: [tracker])
        #expect(changed.removing.isEmpty && changed.displacing.isEmpty && changed.adding.isEmpty, "theirs now, and it holds its day")
        let theirs = [record(breakfast, owner: "phone-b")]
        let other = plan([better], deleted: [breakfast.id], full: true, records: theirs, preferred: [tracker])
        #expect(other.removing.isEmpty && other.displacing.isEmpty && other.adding.isEmpty)
        #expect(plan([breakfast], full: true, records: theirs).adoptable == [breakfast.id], "a full read offers it to keep as this phone's")
        #expect(plan([breakfast], records: theirs).adoptable.isEmpty, "never implicitly")
    }

    @Test func overlappingWorkoutsAddOnceFromTheBestSourceInsideTheDaysKept() {
        func workout(_ start: Date, _ end: Date, _ source: String) -> HealthWorkoutReading {
            HealthWorkoutReading(id: UUID(), start: start, end: end, activity: "Running", kilocalories: 300, source: source, sourceName: source)
        }
        let run = [workout(at(5, 7), at(5, 7, 40), watch), workout(at(5, 7, 2), at(5, 7, 41), tracker)]
        let ride = workout(at(5, 17), at(5, 18), tracker)
        let old = workout(at(5, 7).addingTimeInterval(-11 * 365 * 86400), at(5, 8).addingTimeInterval(-11 * 365 * 86400), tracker)
        let result = HealthHistory.plan(added: run + [ride, old], full: true, records: [], install: install, live: [], changed: [],
                                        grouping: .overlap, within: LocalDate("2016-10-08")!...LocalDate("2026-10-08")!) {
            HealthHistory.item($0, timeZone: newYork)
        }
        #expect(result.adding.map(\.id) == [run[0].id, ride.id])
        #expect(result.preview.leftOut == 1 && result.preview.adding == 2 && result.preview.outside == 1)
    }

    @Test func foodChangesAreSavedWithTheirRecordsAndRecheckedInside() throws {
        let persistence = InMemoryTrainingPersistence()
        let store = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let imports = try HealthImportStore(persistence: persistence)
        let soup = food(5, 12, tracker, kcal: 250), toast = food(5, 8, tracker, kcal: 120)
        var changes = HealthFoodChanges()
        changes.adding = [soup, toast]
        #expect(try imports.apply(changes, to: store, install: install, timeZone: newYork).added == 2)
        #expect(imports.records.count == 2 && imports.records[soup.id]?.owner == install)
        // Changed after the plan was made: removal is checked again as it's saved.
        let entry = try #require(store.entries.first { $0.id == soup.id })
        try store.saveEntry(entry.editingNutrients(NutrientAmounts([.energy: 320])))
        var removing = HealthFoodChanges()
        removing.removing = [soup.id, toast.id]
        #expect(try imports.apply(removing, to: store, install: install, timeZone: newYork).removed == 1)
        #expect(store.entries.map(\.id) == [soup.id] && imports.records[toast.id]?.state == .removed)
        #expect(try imports.apply(removing, to: store, install: "phone-b", timeZone: newYork).removed == 0, "never another install")
        // Both kinds reach the documents sync tracks.
        #expect(try persistence.loadDocuments(kind: "health_import").count == 2)
        #expect(try persistence.loadDocuments(kind: "food_entry").count == 1)
    }

    /// Merge note (claude/sync): Health's additions and removals go through
    /// the persistence saves and deletes that document sync tracks, records too.
    @Test func healthImportsAndRemovalsReachTheServerWithTheirRecords() async throws {
        let server = FakeDocumentServer(), disk = InMemoryTrainingPersistence()
        let store = try NutritionStore(persistence: disk), imports = try HealthImportStore(persistence: disk)
        let sync = SyncEngine(hosts: [store, imports], state: disk, api: server)
        let soup = food(5, 12, tracker, kcal: 250)
        var adding = HealthFoodChanges()
        adding.adding = [soup]
        try imports.apply(adding, to: store, install: install, timeZone: newYork)
        try await sync.sync()
        #expect(server.revision("food_entry", soup.id.uuidString) != nil && server.revision("health_import", soup.id.uuidString) != nil)
        var removing = HealthFoodChanges()
        removing.removing = [soup.id]
        try imports.apply(removing, to: store, install: install, timeZone: newYork)
        try await sync.sync()
        let other = InMemoryTrainingPersistence()
        let otherStore = try NutritionStore(persistence: other), otherImports = try HealthImportStore(persistence: other)
        try await SyncEngine(hosts: [otherStore, otherImports], state: other, api: server).sync()
        #expect(otherStore.entries.isEmpty, "the removal reached another device")
        #expect(otherImports.records[soup.id]?.state == .removed && otherImports.records[soup.id]?.owner == install)
    }

    @Test func importedFoodsLandInTheirMealOnceAndAreNeverWrittenBack() throws {
        let store = try NutritionStore(persistence: InMemoryTrainingPersistence(), now: { Fixture.instant() })
        let breakfast = food(5, 8, tracker, kcal: 300), unnamed = food(5, 19, tracker, kcal: 650, name: nil)
        #expect(try store.importHealthFoods([breakfast, unnamed], timeZone: newYork) == 2)
        #expect(try store.importHealthFoods([breakfast, unnamed], timeZone: newYork) == 0, "importing again adds nothing")
        let entries = store.entries(on: LocalDate("2026-10-05")!).sorted { $0.loggedAt < $1.loggedAt }
        #expect(entries.map(\.meal) == ["Breakfast", "Dinner"])
        #expect(entries.map(\.nutrients.energy) == [300, 650])
        #expect(entries[1].food.name == "Food from Tracker" && entries[0].food.brand == "Tracker")
        #expect(entries.allSatisfy { HealthFoodRecord(entry: $0, timeZone: newYork) == nil }, "Health stays their source")

        try store.importHealthFoods([], deleted: [breakfast.id], timeZone: newYork)
        #expect(store.entries(on: LocalDate("2026-10-05")!).map(\.id) == [unnamed.id], "deleted in Health, gone here")
    }

    /// Review 3, item 1: an activity's fingerprint covers what it's saved
    /// with, minutes and type among them, and not how the server writes numbers.
    @Test func anActivitysFingerprintCoversItsMinutesAndType() {
        let saved: [String: Any] = ["activity": "Running", "duration_min": 30.0, "calories": 320.0, "type": "health", "entry_date": "2026-10-20"]
        let print = HealthImport.fingerprint(activity: saved)
        #expect(HealthImport.fingerprint(activity: saved.merging(["duration_min": 35.0]) { $1 }) != print, "minutes")
        #expect(HealthImport.fingerprint(activity: saved.merging(["type": "cardio"]) { $1 }) != print, "type")
        let server = saved.merging(["duration_min": 30, "calories": 320, "intensity": NSNull(), "id": "server-1", "revision": 2,
                                    "created_at": "2026-10-20T08:00:00.000Z"]) { $1 }
        #expect(HealthImport.fingerprint(activity: server) == print, "the server's copy")
    }

    /// Review 3, item 2: an adoption's generation stands against a stale
    /// owner's change made later, whichever side it arrives from.
    @Test func aLaterGenerationWinsOverALaterTime() throws {
        let imports = try HealthImportStore(persistence: InMemoryTrainingPersistence())
        let soup = food(5, 12, tracker, kcal: 250)
        var adopted = record(soup)
        adopted.adopt(by: "phone-b", at: at(2, 0))
        #expect(adopted.generation == 1 && adopted.owner == "phone-b")
        var stale = record(soup)
        stale.state = .removed
        stale.updatedAt = at(3, 0)
        for (local, remote) in [(stale, adopted), (adopted, stale)] {
            let merged = try imports.merge(kind: "health_import", base: nil, local: ExerlyJSON.canonical(local),
                                           remote: ExerlyJSON.canonical(remote))
            #expect(try ExerlyJSON.decoder.decode(HealthImport.self, from: merged) == adopted)
        }
        var object = try #require(try JSONSerialization.jsonObject(with: ExerlyJSON.canonical(record(soup))) as? [String: Any])
        object["generation"] = nil
        let older = try ExerlyJSON.decoder.decode(HealthImport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.generation == 0, "a record from before generations is the first")
    }

    @Test func aWorkoutsActivityIDIsTheSameOnEveryInstallAndDiffersByAccount() {
        let id = UUID()
        #expect(HealthHistory.activityID(for: id, accountID: "a") == HealthHistory.activityID(for: id, accountID: "a"))
        #expect(HealthHistory.activityID(for: id, accountID: "a") != HealthHistory.activityID(for: id, accountID: "b"))
        #expect(HealthHistory.activityID(for: id, accountID: "a") != HealthHistory.activityID(for: UUID(), accountID: "a"))
        #expect(UUID(uuidString: HealthHistory.activityID(for: id, accountID: "a")) != nil, "a client ID like any other")
    }

    @Test func aWeightPreviewCountsWhatsNewAndWhatsAlreadyIn() {
        let readings = [(HealthWeight(id: UUID(), at: at(1, 7), kilograms: 80), "Scale"),
                        (HealthWeight(id: UUID(), at: at(9, 7), kilograms: 79.6), "Scale"),
                        (HealthWeight(id: UUID(), at: at(9, 8), kilograms: 79.9), "Manual")]
        let preview = HealthHistory.weights(readings.map { ($0.0, $0.1) }, existing: [readings[0].0.id], timeZone: newYork)
        #expect(preview.adding == 2 && preview.alreadyIn == 1 && preview.leftOut == 0)
        #expect(preview.first == LocalDate("2026-10-09") && preview.last == LocalDate("2026-10-09"))
        #expect(preview.sources.map(\.name) == ["Scale", "Manual"])
    }

    @Test func anImportedFoodsIDFollowsItsSourceAndName() {
        #expect(HealthHistory.foodID(source: tracker, name: "Oats") == HealthHistory.foodID(source: tracker, name: " oats "))
        #expect(HealthHistory.foodID(source: tracker, name: "Oats") != HealthHistory.foodID(source: diary, name: "Oats"))
        #expect(HealthHistory.foodID(source: tracker, name: "Oats").count <= 64)
    }
}
