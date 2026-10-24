import Foundation

/// Amounts on the scanner's tray: the same pack scanned again, and the ±
/// one serving buttons beside each food.
public enum ScanTrayAmount {
    /// One more pack on top of what's there: counts add when both are in the
    /// same serving, else the weights do.
    public static func adding(_ more: LoggedAmount, to amount: LoggedAmount, of food: Food) throws -> LoggedAmount {
        if let serving = amount.serving, serving == more.serving {
            return try NutritionStore.preview(food, serving: serving, quantity: (amount.quantity ?? 1) + (more.quantity ?? 1))
        }
        return try NutritionStore.preview(food, grams: amount.grams + more.grams)
    }

    /// One `portion` more or fewer: one more bar, or another 100 ml where
    /// that's what's usually logged, never one millilitre. Nil when fewer
    /// would leave nothing.
    public static func stepping(_ amount: LoggedAmount, by portion: LoggedAmount, of food: Food, more: Bool) -> LoggedAmount? {
        if more { return try? adding(portion, to: amount, of: food) }
        if let serving = amount.serving, serving == portion.serving {
            let quantity = (amount.quantity ?? 1) - (portion.quantity ?? 1)
            return quantity > 1e-9 ? try? NutritionStore.preview(food, serving: serving, quantity: quantity) : nil
        }
        let grams = amount.grams - portion.grams
        return grams > 1e-6 ? try? NutritionStore.preview(food, grams: grams) : nil
    }
}
