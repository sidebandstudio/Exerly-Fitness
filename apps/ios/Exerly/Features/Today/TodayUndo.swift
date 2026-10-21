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
}
