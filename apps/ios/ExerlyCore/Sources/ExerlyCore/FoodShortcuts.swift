import Foundation

extension NutritionStore {
    /// The person's own food with a barcode typed or read, so a shortcut can
    /// log it without the scanner: a saved food carrying the barcode, else a
    /// database food logged before ("off:<barcode>"). Leading zeros, and a
    /// UPC-E for its UPC-A, don't matter. Nil when none matches, or for
    /// digits that aren't a barcode.
    public func ownFoodID(barcode text: String) -> String? {
        let wanted = Set(GTIN.candidates(typed: text))
        guard !wanted.isEmpty else { return nil }
        func matches(_ code: String?) -> Bool { code.flatMap { GTIN($0) }.map(wanted.contains) ?? false }
        func database(_ id: String) -> String? { id.hasPrefix("off:") ? String(id.dropFirst(4)) : nil }
        if let saved = foods.first(where: { $0.archivedAt == nil && (matches($0.barcode) || matches(database($0.id))) }) {
            return saved.id
        }
        return recentFoods(limit: 500).first { matches(database($0.foodID)) }?.foodID
    }
}
