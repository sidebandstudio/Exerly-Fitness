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
        let (preview, adding) = HealthHistory.foods(foods, existing: [imported], timeZone: newYork)
        #expect(Set(adding.map(\.id)) == [foods[0].id, foods[1].id, foods[4].id])
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
        let (preview, adding) = HealthHistory.workouts(run + [ride], existing: [], timeZone: newYork)
        #expect(adding.map(\.id) == [run[0].id, ride.id])
        #expect(preview.leftOut == 1 && preview.adding == 2)
        #expect(adding[0].minutes == 40)
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
