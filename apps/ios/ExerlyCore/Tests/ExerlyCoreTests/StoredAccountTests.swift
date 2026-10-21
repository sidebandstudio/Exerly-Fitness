import Foundation
import Testing
@testable import ExerlyCore

/// Opening an account from its database read off the main actor gives the
/// same stores as reading it on the main actor.
@MainActor
@Suite struct StoredAccountTests {
    @Test func storesOpenedFromAReadOffTheMainActorMatchOnesReadOnIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-stored-\(UUID().uuidString)/x.sqlite")
        #expect(try StoredAccount.read(url: url) == nil, "Nothing to read before the file exists")
        let persistence = try SQLiteTrainingPersistence(url: url)
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let thursday = LocalDate("2026-10-08")!, friday = LocalDate("2026-10-09")!
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 244, on: friday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: thursday, meal: "Dinner")
        try persistence.save(Fixture.session([("deadlift", [Fixture.set(5, 140)])]))
        // A row a newer version wrote, which this one can't read, stays and is counted.
        try persistence.database.execute("INSERT INTO sessions (id, started_at, ended_at, payload, updated_at) VALUES (?, ?, ?, ?, ?)",
                                          "unreadable", Date(), Date(), Data("{}".utf8), Date())

        let stored = try #require(try await Task.detached { try StoredAccount.read(url: url) }.value)
        let fromStored = NutritionStore(persistence: persistence, loaded: stored.nutrition)
        let direct = try NutritionStore(persistence: persistence)
        #expect(fromStored.entries == direct.entries)
        #expect(fromStored.entries.map(\.date) == [thursday, thursday, friday], "In the store's order")
        let training = try TrainingStore(persistence: persistence, loaded: stored.training)
        let directTraining = try TrainingStore(persistence: persistence)
        #expect(training.history.sessions == directTraining.history.sessions)
        #expect(stored.unreadableRows == ["sessions/unreadable"])
    }
}
