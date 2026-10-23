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

    @Test func eachDaysFoodComesFromItsBestSourceAndIsPreviewedFirst() {
        // Oct 5: both apps saved the day; the tracker has more overall. Oct 6: only the diary.
        let foods = [food(5, 8, tracker, kcal: 300), food(5, 13, tracker, kcal: 600), food(6, 19, tracker, kcal: 700),
                     food(5, 8, diary, kcal: 310), food(7, 12, diary, kcal: 500)]
        let imported = foods[2].id
        let plan = HealthHistory.foods(foods, existing: [imported], timeZone: newYork)
        let preview = plan.preview
        #expect(Set(plan.adding.map(\.id)) == [foods[0].id, foods[1].id, foods[4].id])
        #expect(preview.adding == 3 && preview.alreadyIn == 1 && preview.leftOut == 1)
        #expect(preview.first == LocalDate("2026-10-05") && preview.last == LocalDate("2026-10-07"))
        #expect(preview.sources == [.init(name: "Tracker", adding: 2, leftOut: 0), .init(name: "Diary", adding: 1, leftOut: 1)])

        let chosen = HealthHistory.foods(foods, existing: [], timeZone: newYork, preferred: [diary])
        #expect(Set(chosen.adding.map(\.id)) == [foods[3].id, foods[2].id, foods[4].id], "the person's order wins")
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

    @Test func overlappingWorkoutsAddOnceFromTheBestSource() {
        func workout(_ start: Date, _ end: Date, _ source: String) -> HealthWorkoutReading {
            HealthWorkoutReading(id: UUID(), start: start, end: end, activity: "Running", kilocalories: 300, source: source, sourceName: source)
        }
        // A watch and a running app record one run; a ride later is only in the app.
        let run = [workout(at(5, 7), at(5, 7, 40), watch), workout(at(5, 7, 2), at(5, 7, 41), tracker)]
        let ride = workout(at(5, 17), at(5, 18), tracker)
        let plan = HealthHistory.workouts(run + [ride], existing: [], timeZone: newYork)
        #expect(plan.adding.map(\.id) == [run[0].id, ride.id])
        #expect(plan.preview.leftOut == 1 && plan.preview.adding == 2)
        #expect(plan.adding[0].minutes == 40)
    }

    @Test func aBetterSourceLaterReplacesTheDayImportedBeforeAndAWorseOneAddsNothing() {
        let breakfast = food(5, 8, diary, kcal: 300)
        let first = HealthHistory.foods([breakfast], existing: [], timeZone: newYork)
        #expect(first.adding.map(\.id) == [breakfast.id] && first.imported == [breakfast.id])

        // The tracker saves the same breakfast later. With more of the day's history, the diary keeps it.
        let more = [breakfast, food(5, 13, diary, kcal: 500), food(5, 8, tracker, kcal: 310)]
        let worse = HealthHistory.foods(more, existing: [breakfast.id], imported: first.imported, timeZone: newYork)
        #expect(worse.adding.map(\.id) == [more[1].id] && worse.removing.isEmpty && worse.preview.leftOut == 1)

        // Chosen first, the tracker's replaces it, even though it arrives alone.
        let better = HealthHistory.foods([breakfast, more[2]], existing: [breakfast.id], imported: first.imported, timeZone: newYork,
                                         preferred: [tracker])
        #expect(better.adding.map(\.id) == [more[2].id] && better.removing == [breakfast.id])
        #expect(better.preview.adding == 1 && better.preview.removing == 1)
        #expect(better.imported == [more[2].id], "what's taken out can come back if it's best again")
    }

    @Test func whatHealthNoLongerHasIsTakenOutUnlessTheyChangedIt() {
        let soup = food(5, 12, tracker, kcal: 250), toast = food(5, 8, tracker, kcal: 120)
        // Imported, then deleted in Health while reading was off: the next full read finds it gone.
        let plan = HealthHistory.foods([toast], existing: [soup.id, toast.id], imported: [soup.id, toast.id], timeZone: newYork)
        #expect(plan.removing == [soup.id] && plan.preview.removing == 1 && plan.adding.isEmpty)
        #expect(HealthHistory.foods([toast], existing: [soup.id, toast.id], imported: [soup.id, toast.id], locked: [soup.id],
                                    timeZone: newYork).removing.isEmpty, "an entry they edited is theirs")
        // One from another phone's Health is left alone; one they deleted here isn't added back.
        #expect(HealthHistory.foods([toast], existing: [soup.id], imported: [toast.id], timeZone: newYork).removing.isEmpty)
        #expect(HealthHistory.foods([toast], existing: [soup.id], imported: [toast.id], timeZone: newYork).adding.isEmpty)
        // After a reinstall, what's synced and still in Health counts as imported here again.
        let reinstalled = HealthHistory.foods([toast], existing: [toast.id], imported: [], timeZone: newYork)
        #expect(reinstalled.imported == [toast.id] && reinstalled.preview.alreadyIn == 1 && reinstalled.adding.isEmpty)
    }

    @Test func workoutsOutsideTheTenYearsExerlyKeepsAreSetAsideAndTheRestImport() {
        func workout(_ start: Date, _ source: String = "com.example.runs") -> HealthWorkoutReading {
            HealthWorkoutReading(id: UUID(), start: start, end: start.addingTimeInterval(1800), activity: "Running", kilocalories: 300,
                                 source: source, sourceName: "Runs")
        }
        let old = workout(at(5, 7).addingTimeInterval(-11 * 365 * 86400)), recent = workout(at(5, 7)), ahead = workout(at(9, 7))
        let window = LocalDate("2016-10-08")!...LocalDate("2026-10-08")!
        let plan = HealthHistory.workouts([old, recent, ahead], existing: [old.id], imported: [old.id], timeZone: newYork, within: window)
        #expect(plan.adding.map(\.id) == [recent.id])
        #expect(plan.preview.outside == 2 && plan.preview.adding == 1)
        #expect(plan.removing.isEmpty, "one imported when it was newer stays")
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
