import ExerlyCore
import Foundation

/// What an Undo on Today may take back.
enum TodayUndo {
    /// Of the entries a tap logged, the ones still in `current` exactly as
    /// logged: an Undo removes these IDs. One changed since, here or on
    /// another device, is the person's now, and stays.
    static func removable(_ logged: [FoodEntry], in current: [FoodEntry]) -> [UUID] {
        let now = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return logged.filter { now[$0.id] == $0 }.map(\.id)
    }

    /// Takes back those of `logged` still as logged: all of them, or, if
    /// saving fails, none, so the same Undo can be tried again.
    @MainActor static func remove(_ logged: [FoodEntry], from store: NutritionStore) throws {
        #if DEBUG
        if failingDeletes > 0 {
            failingDeletes -= 1
            throw TestDeleteFailure()
        }
        #endif
        try store.deleteEntries(removable(logged, in: store.entries))
    }

    #if DEBUG
    /// UI tests only: this many Undos fail before deleting anything, as one
    /// a full disk rolls back would, set by the launch argument
    /// `-exerlyTestFailNextDeletes <count>`.
    @MainActor private static var failingDeletes = UserDefaults.standard.integer(forKey: "exerlyTestFailNextDeletes")
    private struct TestDeleteFailure: Error {}
    #endif

    static let unfinished = "Undo didn't finish. Those foods are still logged. Try again."

    /// An Undo of `logged`, a confirmation's or a failure's Try again: nil
    /// once done. If saving fails nothing is taken back, and the failure
    /// returned offers this same Undo again, new so its time starts over.
    @MainActor static func attempt(_ logged: [FoodEntry], from store: NutritionStore) -> TodayView.Toast? {
        do {
            try remove(logged, from: store)
            return nil
        } catch {
            return TodayView.Toast(message: unfinished, undo: .remove(logged), failed: true)
        }
    }
}
