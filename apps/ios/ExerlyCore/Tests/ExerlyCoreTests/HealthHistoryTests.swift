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

    /// Review 5: a day already imported keeps its source. A better source
    /// arriving later is set aside and noted on what's there, never swapped
    /// in; more from the day's own source still comes in.
    @Test func aLaterSourceForAnImportedDayOrTimeIsSetAsideAndNoted() {
        let breakfast = food(5, 8, diary, kcal: 300), better = food(5, 8, tracker, kcal: 310), lunch = food(5, 13, diary, kcal: 500)
        let later = plan([better, lunch], records: [record(breakfast)], preferred: [tracker])
        #expect(later.adding.map(\.id) == [lunch.id], "the day's own source still adds")
        #expect(later.preview.leftOut == 1 && later.alsoIn == [breakfast.id: [.init(source: tracker, name: better.sourceName)]])
        let gone = plan([], deleted: [breakfast.id], records: [record(breakfast)], preferred: [tracker])
        #expect(gone.removing == [breakfast.id] && gone.adding.isEmpty, "Health's deletion is listed, and nothing comes in its place")
        func workout(_ start: Date, _ source: String) -> HealthWorkoutReading {
            HealthWorkoutReading(id: UUID(), start: start, end: start.addingTimeInterval(2400), activity: "Running", kilocalories: 300,
                                 source: source, sourceName: source)
        }
        let run = workout(at(5, 7), tracker), watched = workout(at(5, 7, 2), watch)
        let ran = HealthImport(workout: run, clientID: "run", fingerprint: "f", owner: install, timeZone: newYork)
        let overlap = HealthHistory.plan(added: [watched], full: false, records: [ran], install: install, live: [ran.id], changed: [],
                                         grouping: .overlap) { HealthHistory.item($0, timeZone: newYork) }
        #expect(overlap.adding.isEmpty && overlap.alsoIn == [run.id: [.init(source: watch, name: watch)]], "the watch, Health's own, is noted, not swapped in")
    }

    /// Review 6: the queue holds small removal references, each once, with
    /// no cap; a full read's "No longer in Health" replaces the last one's.
    @Test func theQueueHoldsSmallRemovalsOnce() throws {
        let ids = (0..<3).map { _ in UUID() }
        let entries = ids.map {
            HealthChangeQueue.Entry(kind: .food, id: $0, target: $0.uuidString, fingerprint: "f", owner: install, generation: 0, reason: .missing)
        }
        let all = HealthChangeQueue().adding(entries)
        #expect(all.entries.map(\.id) == ids && all.adding([entries[0]]) == all, "listed once")
        #expect(all.removing([ids[0]]).entries.map(\.id) == Array(ids.dropFirst()))
        #expect(all.adding([entries[2]], replacingMissing: .food).entries.map(\.id) == [ids[2]], "a full read finds them afresh")
        #expect(try ExerlyJSON.canonical(all).count < 800, "references, not payloads")
    }

    /// Review 6: a removal listed for this install is dropped once another
    /// install adopts the import, a generation on.
    @Test func aListedRemovalIsDroppedOnceAnotherInstallAdoptsTheImport() throws {
        let persistence = InMemoryTrainingPersistence()
        let store = try NutritionStore(persistence: persistence), imports = try HealthImportStore(persistence: persistence)
        let soup = food(5, 12, tracker, kcal: 250)
        var changes = HealthFoodChanges()
        changes.adding = [soup]
        try imports.apply(changes, to: store, install: install, timeZone: newYork)
        let listed = HealthChangeQueue.Entry(try #require(imports.records[soup.id]), reason: .deleted)
        changes = HealthFoodChanges()
        changes.adopting = [soup.id]
        try imports.apply(changes, to: store, install: "phone-b", timeZone: newYork)
        #expect(!listed.stillFor(try #require(imports.records[soup.id])))
        #expect(try imports.applyRemovals([listed], to: store, install: install) == 0)
        #expect(store.entries.map(\.id) == [soup.id] && imports.records[soup.id]?.owner == "phone-b")
    }

    /// Review 6: sources set aside are noted once each, at most five, each
    /// name at most 60 characters, and a record read back is held to the same.
    @Test func sourcesSetAsideAreNotedOnceEachWithinLimits() throws {
        let persistence = InMemoryTrainingPersistence()
        let store = try NutritionStore(persistence: persistence), imports = try HealthImportStore(persistence: persistence)
        let soup = food(5, 12, tracker, kcal: 250)
        var changes = HealthFoodChanges()
        changes.adding = [soup]
        try imports.apply(changes, to: store, install: install, timeZone: newYork)
        let long = String(repeating: "N", count: 90)
        let sources = (0..<7).map { HealthImport.AlsoIn(source: "com.example.app\($0)", name: $0 == 0 ? long : "App \($0)") }
        let noted = try #require(imports.noting([soup.id: sources + [.init(source: "com.example.app1", name: "App 1 again")]], now: at(6, 0)).first)
        #expect(noted.alsoIn.count == 5 && Set(noted.alsoIn.map(\.source)).count == 5)
        #expect(noted.alsoIn.allSatisfy { $0.name.count <= 60 })
        var object = try #require(try JSONSerialization.jsonObject(with: ExerlyJSON.canonical(record(soup))) as? [String: Any])
        object["alsoIn"] = (0..<8).map { ["source": "com.example.dup\($0 % 6)", "name": long] }
        let read = try ExerlyJSON.decoder.decode(HealthImport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(read.alsoIn.count == 5 && Set(read.alsoIn.map(\.source)).count == 5 && read.alsoIn.allSatisfy { $0.name.count == 60 })
        #expect(read.sourceLines == ["From Health · \(soup.sourceName)",
                                     "Also in Health from \(ListFormatter.localizedString(byJoining: read.alsoIn.map(\.name))), not imported"])
    }

    @Test func nothingIsTakenOutForBeingMissingOnlyForHealthsDeletions() {
        let soup = food(5, 12, tracker, kcal: 250), toast = food(5, 8, tracker, kcal: 120)
        let records = [record(soup), record(toast)]
        // A read that comes back empty, as a revoked one does.
        let empty = plan([], full: true, records: records)
        #expect(empty.removing.isEmpty && empty.missing == [soup.id, toast.id].sorted { $0.uuidString < $1.uuidString })
        #expect(empty.preview.missing == 2)
        #expect(plan([], records: records).missing.isEmpty, "an anchored read lists nothing as missing")
        #expect(plan([], deleted: [soup.id], records: records).removing == [soup.id])
    }

    /// Only this install's imports, unchanged since, are listed for removal.
    @Test func onlyThisInstallsUnchangedImportsAreListedForRemoval() {
        let breakfast = food(5, 8, diary, kcal: 300), better = food(5, 8, tracker, kcal: 310)
        let changed = plan([better], deleted: [breakfast.id], records: [record(breakfast)], changed: [breakfast.id], preferred: [tracker])
        #expect(changed.removing.isEmpty && changed.adding.isEmpty, "theirs now, and it holds its day")
        let theirs = [record(breakfast, owner: "phone-b")]
        let other = plan([better], deleted: [breakfast.id], full: true, records: theirs, preferred: [tracker])
        #expect(other.removing.isEmpty && other.adding.isEmpty && other.missing.isEmpty)
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
        #expect(try imports.apply(changes, to: store, install: install, timeZone: newYork) == 2)
        #expect(imports.records.count == 2 && imports.records[soup.id]?.owner == install)
        let listed = try [soup, toast].map { HealthChangeQueue.Entry(try #require(imports.records[$0.id]), reason: .deleted) }
        try imports.save([], queue: HealthChangeQueue(entries: listed))
        // Changed after it was listed: checked again as it's applied, and dropped.
        let entry = try #require(store.entries.first { $0.id == soup.id })
        try store.saveEntry(entry.editingNutrients(NutrientAmounts([.energy: 320])))
        #expect(try imports.applyRemovals(listed, to: store, install: "phone-b") == 1)
        #expect(store.entries.map(\.id) == [soup.id] && imports.records[toast.id]?.state == .removed)
        #expect(imports.records[toast.id]?.owner == "phone-b" && imports.records[toast.id]?.generation == 1, "applied here, a generation on")
        #expect(imports.queue.isEmpty, "exactly what was applied leaves, the dropped one too")
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
        try imports.applyRemovals([HealthChangeQueue.Entry(try #require(imports.records[soup.id]), reason: .deleted)], to: store, install: install)
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

    /// Review 3, item 3: work written down outlasts reopening the store, and
    /// is cleared in the same transaction that saves its records.
    @Test func workWrittenDownIsClearedWithItsRecords() throws {
        let persistence = InMemoryTrainingPersistence()
        let imports = try HealthImportStore(persistence: persistence)
        try imports.recordWork(Data("planned".utf8))
        #expect(try HealthImportStore(persistence: persistence).pendingWork() == Data("planned".utf8))
        let soup = food(5, 12, tracker, kcal: 250)
        try imports.save([record(soup)], finishingWork: true)
        #expect(try imports.pendingWork() == nil && imports.records[soup.id] != nil)
    }

    /// Review 3, item 8: a removed record keeps only its ID, kind, owner,
    /// generation and state, and still keeps its sample from coming back.
    @Test func aRemovedRecordIsATombstoneThatStillStopsItsSample() throws {
        let soup = food(5, 12, tracker, kcal: 250)
        var removed = record(soup, state: .removed)
        removed.adopt(by: "phone-b", at: at(2, 0))
        let json = try #require(try JSONSerialization.jsonObject(with: ExerlyJSON.canonical(removed)) as? [String: Any])
        #expect(Set(json.keys) == ["id", "kind", "owner", "generation", "state", "updatedAt"])
        let read = try ExerlyJSON.decoder.decode(HealthImport.self, from: ExerlyJSON.canonical(removed))
        #expect(read.id == soup.id && read.owner == "phone-b" && read.generation == 1 && read.state == .removed && read.kind == .food)
        #expect(try ExerlyJSON.canonical(read) == ExerlyJSON.canonical(removed), "the same tombstone again")
        let plan = HealthHistory.plan(added: [soup], full: true, records: [read], install: "phone-b", live: [], changed: [],
                                      grouping: .day, item: item)
        #expect(plan.adding.isEmpty && plan.preview.adding == 0, "never imported again")
        var kept = record(soup)
        kept.adopt(by: "phone-b", at: at(2, 0))
        #expect(try ExerlyJSON.decoder.decode(HealthImport.self, from: ExerlyJSON.canonical(kept)) == kept, "one still in keeps it all")
    }

    /// Review 4, item 1: through sync, a stale owner's removal at generation
    /// 0 meets another phone's adoption at 1. Both phones end with the
    /// adoption whole, never fields of each.
    @Test func conflictingRecordsMergeWholeByGenerationThroughSync() async throws {
        let server = FakeDocumentServer()
        func phone() throws -> (InMemoryTrainingPersistence, NutritionStore, HealthImportStore, SyncEngine) {
            let disk = InMemoryTrainingPersistence()
            let store = try NutritionStore(persistence: disk), imports = try HealthImportStore(persistence: disk)
            return (disk, store, imports, SyncEngine(hosts: [store, imports], state: disk, api: server))
        }
        let a = try phone(), b = try phone()
        let soup = food(5, 12, tracker, kcal: 250)
        var adding = HealthFoodChanges()
        adding.adding = [soup]
        try a.2.apply(adding, to: a.1, install: "phone-a", timeZone: newYork, now: at(5, 13))
        try await a.3.sync()
        try await b.3.sync()
        var adopted = try #require(b.2.records[soup.id])
        adopted.adopt(by: "phone-b", at: at(6, 9))
        try b.2.save([adopted])
        try await b.3.sync()
        var stale = try #require(a.2.records[soup.id])
        stale.state = .removed
        stale.updatedAt = at(7, 9)
        try a.2.save([stale])
        try await a.3.sync()
        try await b.3.sync()
        #expect(a.2.records[soup.id] == adopted, "the removal from before the adoption doesn't stand")
        #expect(b.2.records[soup.id] == adopted)
    }

    /// Review 7: a name is kept to 60 Unicode scalars, as the API counts
    /// them, without splitting a character. The same names are in
    /// api.documents.test.js, which accepts what's kept here.
    @Test func aSourceNameIsCutTo60ScalarsOnAWholeCharacter() {
        let clip = HealthImport.AlsoIn.clipped
        let ascii = String(repeating: "a", count: 60)
        #expect(clip(ascii) == ascii && clip(ascii + "a") == ascii, "exactly 60 ASCII stays")
        let accent = "e\u{301}", family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let accents = String(repeating: accent, count: 31)
        #expect(accents.count == 31 && accents.unicodeScalars.count == 62)
        #expect(clip(accents) == String(repeating: accent, count: 30), "the 31st accented letter would go past 60, so it's left out whole")
        let families = String(repeating: family, count: 9)
        #expect(clip(families) == String(repeating: family, count: 8), "eight families are 56 scalars; a ninth would be 63")
        for name in [ascii + "b", accents, families, "Tracker"] {
            let kept = HealthImport.AlsoIn(source: "s", name: name).name
            #expect(kept.unicodeScalars.count <= 60 && name.hasPrefix(kept))
        }
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
