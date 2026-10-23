import ExerlyCore
import XCTest
@testable import Exerly

/// Every Undo on Today, a chip's second tap or the confirmation's, takes
/// back only what its tap logged, and only while it's unchanged.
final class TodayUndoTests: XCTestCase {
    private func entry(_ grams: Double) -> FoodEntry {
        FoodEntry(date: LocalDate("2026-10-20")!, meal: "Breakfast", loggedAt: Date(timeIntervalSince1970: 1_792_000_000),
                  food: Food(id: UUID().uuidString, name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]),
                             servings: [], createdAt: Date(timeIntervalSince1970: 1_792_000_000)).snapshot, grams: grams)
    }

    func testAnEntryChangedSinceItWasLoggedIsNotTakenBack() {
        let oats = entry(60), milk = entry(244), deleted = entry(80)
        var edited = milk
        edited.grams = 200
        // Another device changed the milk; the deleted one is gone.
        XCTAssertEqual(TodayUndo.removable([oats, milk, deleted], in: [oats, edited]), [oats.id])
        XCTAssertEqual(TodayUndo.removable([oats, milk], in: [oats, milk]), [oats.id, milk.id])
        XCTAssertTrue(TodayUndo.removable([milk], in: [edited]).isEmpty, "Nothing left this Undo may take back")
    }

    /// An Undo whose deletion fails partway takes nothing back, so the
    /// repeat keeps what it logged and the same Undo can be tried again.
    @MainActor
    func testAnUndoThatCannotFinishTakesNothingBack() throws {
        let disk = DeleteFailingStore()
        let store = try NutritionStore(persistence: disk)
        let oats = entry(60), milk = entry(244)
        for logged in [oats, milk] { try store.saveEntry(logged) }
        disk.failingDelete = 2
        XCTAssertThrowsError(try TodayUndo.remove([oats, milk], from: store))
        XCTAssertEqual(Set(store.entries.map(\.id)), [oats.id, milk.id], "Both are still logged")
        XCTAssertEqual(try NutritionStore(persistence: disk).entries.count, 2, "And saved")
        try TodayUndo.remove([oats, milk], from: store)
        XCTAssertTrue(store.entries.isEmpty, "Trying again takes back both")
        XCTAssertTrue(try NutritionStore(persistence: disk).entries.isEmpty)
    }
}

/// A repeat logged from a meal card or onto an empty past day has no chip
/// to tap again: its only Undo is the confirmation's, so a failure keeps it
/// as Try again, which retries that same Undo until it finishes.
@MainActor
final class TodayUndoRetryTests: XCTestCase {
    private let today = LocalDate("2026-10-22")!
    private let oats = Food(id: UUID().uuidString, name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]),
                            servings: [], createdAt: Date(timeIntervalSince1970: 1_792_000_000))
    private let milk = Food(id: UUID().uuidString, name: "Synthetic milk", per100g: NutrientAmounts([.energy: 60]),
                            servings: [], createdAt: Date(timeIntervalSince1970: 1_792_000_000))

    private func store(_ disk: DeleteFailingStore, loggedOn day: LocalDate) throws -> NutritionStore {
        let store = try NutritionStore(persistence: disk)
        try store.log(oats, grams: 60, on: day, meal: "Breakfast")
        try store.log(milk, grams: 244, on: day, meal: "Breakfast")
        return store
    }

    /// Fails twice, each a new failure still offering the Undo, then finishes.
    private func retryUntilDone(_ copied: [FoodEntry], in store: NutritionStore, disk: DeleteFailingStore) throws {
        disk.failingDelete = 1
        let failure = try XCTUnwrap(TodayUndo.attempt(copied, from: store), "Saving failed")
        XCTAssertTrue(failure.failed)
        XCTAssertEqual(failure.undo, .remove(copied), "The failure keeps the Undo for Try again")
        XCTAssertTrue(Set(copied.map(\.id)).isSubset(of: store.entries.map(\.id)), "Nothing was taken back")
        disk.failingDelete = 1
        let again = try XCTUnwrap(TodayUndo.attempt(copied, from: store))
        XCTAssertNotEqual(again.id, failure.id, "A new failure, so its time starts over")
        XCTAssertEqual(again.undo, .remove(copied))
        XCTAssertNil(TodayUndo.attempt(copied, from: store), "Try again finishes once saving works")
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: store.entries.map(\.id)))
        XCTAssertEqual(store.entries.count, 2, "The day it was repeated from stays")
    }

    func testAMealCardRepeatsUndoIsRetriedUntilItFinishes() throws {
        let disk = DeleteFailingStore()
        let store = try store(disk, loggedOn: today.adding(days: -1))
        let breakfast = try XCTUnwrap(store.repeatable("Breakfast", for: today))
        try retryUntilDone(try store.apply(breakfast, to: today), in: store, disk: disk)
    }

    func testAnEmptyPastDaysRepeatsUndoIsRetriedUntilItFinishes() throws {
        let disk = DeleteFailingStore()
        let past = today.adding(days: -3)
        let store = try store(disk, loggedOn: past.adding(days: -1))
        let day = try XCTUnwrap(store.repeatable(nil, for: past))
        try retryUntilDone(try store.apply(day, to: past), in: store, disk: disk)
    }
}

/// Storage whose `failingDelete`th document deletion fails, as a full disk
/// would, rolling back the transaction it is in.
@MainActor
private final class DeleteFailingStore: TrainingPersistence, DocumentPersistence {
    struct DeleteFailed: Error {}
    let disk = InMemoryTrainingPersistence()
    var failingDelete: Int?

    func loadSessions() throws -> [WorkoutSession] { try disk.loadSessions() }
    func loadCustomExercises() throws -> [ExerlyCore.Exercise] { try disk.loadCustomExercises() }
    func save(_ session: WorkoutSession) throws { try disk.save(session) }
    func deleteSession(_ id: UUID) throws { try disk.deleteSession(id) }
    func save(_ exercise: ExerlyCore.Exercise) throws { try disk.save(exercise) }
    func loadValue(forKey key: String) throws -> Data? { try disk.loadValue(forKey: key) }
    func saveValue(_ value: Data?, forKey key: String) throws { try disk.saveValue(value, forKey: key) }
    func loadDocuments(kind: String) throws -> [Data] { try disk.loadDocuments(kind: kind) }
    func saveDocument(kind: String, id: String, payload: Data) throws { try disk.saveDocument(kind: kind, id: id, payload: payload) }
    func deleteDocument(kind: String, id: String) throws {
        if let count = failingDelete {
            failingDelete = count - 1
            if count == 1 { failingDelete = nil; throw DeleteFailed() }
        }
        try disk.deleteDocument(kind: kind, id: id)
    }
    func performAtomically(_ body: () throws -> Void) throws { try disk.performAtomically(body) }
    func afterCommit(_ action: @escaping () -> Void) { disk.afterCommit(action) }
}
