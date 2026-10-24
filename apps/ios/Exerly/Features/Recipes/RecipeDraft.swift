import Combine
import ExerlyCore
import Foundation

/// A recipe being built or edited. Totals come from ExerlyCore's
/// `Food.recipe`, rebuilt from the draft as it changes.
@MainActor
final class RecipeDraft: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        var ingredient: RecipeIngredient
        /// The food it was added from, with every named serving; the
        /// snapshot keeps only the one used.
        var food: ExerlyCore.Food?
        /// False while it sits at a default amount no one has looked at.
        var checked = true
        /// True while an imported volume waits for a weight: its amount only
        /// holds the place, so the totals leave it out.
        var needsWeight = false
        /// The line of an imported recipe it came from.
        var line: String?

        /// The ingredient as a diary entry, so the portion editor can open it.
        var entry: FoodEntry {
            FoodEntry(id: id, date: LocalDate(Date(timeIntervalSince1970: 0), in: .gmt), meal: "Recipe",
                      loggedAt: Date(timeIntervalSince1970: 0), food: ingredient.food, grams: ingredient.grams,
                      serving: ingredient.serving, quantity: ingredient.quantity)
        }
    }

    @Published var name: String
    @Published private(set) var rows: [Row]
    /// In the person's units: grams, or ounces for pounds.
    @Published var cookedWeight: NutritionNumberField
    @Published var servings: NutritionNumberField
    @Published var preparation: String
    @Published private(set) var errors: [String] = []
    /// Lines of an imported recipe no food matched, each to search for or skip.
    @Published private(set) var unmatched: [String] = []
    /// The page an imported recipe came from.
    @Published private(set) var sourceURL: String?
    let unit: MassUnit
    let isNew: Bool
    private let store: NutritionStore
    private let template: ExerlyCore.Food
    private var original: ExerlyCore.Food?
    private let initialCooked: NutritionNumberField
    private let initialServings: NutritionNumberField

    /// Edits a saved recipe, or starts a new one, empty, from `start` (a
    /// meal, or a copy of another recipe) or from an imported recipe.
    init(store: NutritionStore, unit: MassUnit, editing: ExerlyCore.Food? = nil, start: ExerlyCore.Food? = nil,
         imported: RecipeImport? = nil) {
        self.store = store
        self.unit = unit
        original = editing
        isNew = editing == nil
        let food = editing ?? start ?? ExerlyCore.Food.recipe(name: "", ingredients: [], servingCount: 1)
        template = food
        name = food.name
        rows = (food.ingredients ?? []).map { Row(id: UUID(), ingredient: $0) }
        let cooked = NutritionNumberField(food.yieldGrams.map { unit == .pounds ? USUnits.ounces(grams: $0) : $0 })
        cookedWeight = cooked
        initialCooked = cooked
        let count = NutritionNumberField(food.servingCount ?? 1)
        servings = count
        initialServings = count
        preparation = food.preparation ?? ""
        sourceURL = food.sourceURL
        if let imported { apply(imported) }
    }

    /// Fills the draft from an imported recipe: its name unless one is
    /// typed, its ingredients after any here (those at a guessed amount
    /// marked to check), the lines it couldn't match, its yield, its steps
    /// unless some are written, and its source.
    func apply(_ imported: RecipeImport) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = imported.name }
        rows += imported.ingredients.map {
            Row(id: UUID(), ingredient: $0.ingredient, food: $0.food, checked: $0.exact, needsWeight: $0.needsWeight, line: $0.line)
        }
        unmatched = imported.unmatched
        if let count = imported.servingCount { servings = NutritionNumberField(count) }
        if let grams = imported.yieldGrams { cookedWeight = NutritionNumberField(unit == .pounds ? USUnits.ounces(grams: grams) : grams) }
        if let steps = imported.preparation, preparation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preparation = steps }
        sourceURL = imported.sourceURL
        errors = []
    }

    /// Takes a line off the unmatched list: skipped, or found by search.
    func settle(_ line: String) {
        if let index = unmatched.firstIndex(of: line) { unmatched.remove(at: index) }
        errors = []
    }

    var hasChanges: Bool {
        (isNew && !rows.isEmpty) || !unmatched.isEmpty || sourceURL != template.sourceURL || name != template.name
            || rows.map(\.ingredient) != (template.ingredients ?? [])
            || cookedWeight != initialCooked || servings != initialServings || preparation != (template.preparation ?? "")
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !rows.isEmpty }

    /// The recipe as it stands, for live totals; nil while a number is unreadable.
    var preview: ExerlyCore.Food? { try? recipe() }

    func recipe(locale: Locale = .current) throws -> ExerlyCore.Food {
        let typed = try cookedWeight.value(named: "the cooked weight", locale: locale)
        let cooked = cookedWeight == initialCooked ? template.yieldGrams : typed.map { unit == .pounds ? USUnits.grams(ounces: $0) : $0 }
        guard let count = try servings.value(named: "servings", locale: locale) else {
            throw NutritionDraftError.input("Enter how many servings it makes.")
        }
        var food = template.withIngredients(rows.filter { !$0.needsWeight }.map(\.ingredient), yieldGrams: cooked)
        food.source = .recipe
        food.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        food.servingCount = count
        let note = preparation.trimmingCharacters(in: .whitespacesAndNewlines)
        food.preparation = note.isEmpty ? nil : note
        food.sourceURL = sourceURL
        return food
    }

    /// Adds a food at the amount chosen for it, or else at the portion one
    /// tap would log it: the amount the person logs it at, or its default.
    /// A default left unchecked stays marked until they look at it.
    @discardableResult
    func add(_ food: ExerlyCore.Food, amount: FoodPickAmount = .usual) -> Bool {
        guard food.id != template.id else { errors = ["A recipe can't include itself."]; return false }
        let ingredient: RecipeIngredient
        var checked = true
        if case .chosen(let amount, let snapshot) = amount {
            ingredient = RecipeIngredient(food: snapshot, grams: amount.grams, serving: amount.serving, quantity: amount.quantity)
        } else if let portion = store.quickPortion(for: food, unit: unit) {
            ingredient = RecipeIngredient(food: portion.food, grams: portion.grams, serving: portion.serving, quantity: portion.quantity)
            if case .unchecked = amount { checked = false }
        } else {
            errors = ["\(food.name) has no weight, so it can't be an ingredient."]
            return false
        }
        rows.append(Row(id: UUID(), ingredient: ingredient, food: food, checked: checked))
        errors = []
        return true
    }

    func update(_ id: UUID, to amount: LoggedAmount, food: FoodSnapshot) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].ingredient = RecipeIngredient(food: food, grams: amount.grams, serving: amount.serving, quantity: amount.quantity)
        rows[index].checked = true
        rows[index].needsWeight = false
    }

    /// The first ingredient still at a default amount, to look at before saving.
    var unchecked: Row? { rows.first { !$0.checked } }

    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }

    func move(from source: IndexSet, to destination: Int) { rows.move(fromOffsets: source, toOffset: destination) }

    @discardableResult
    func save(locale: Locale = .current) -> ExerlyCore.Food? {
        errors = []
        if let line = unmatched.first {
            errors = ["Search for \u{201C}\(line)\u{201D} or skip it before saving."]
            return nil
        }
        if let unchecked {
            errors = [unchecked.needsWeight
                ? "Enter how much \(unchecked.ingredient.food.name) weighs before saving. Its line gives a volume Exerly can't weigh."
                : "Check the amount of \(unchecked.ingredient.food.name) before saving. It came in at a default."]
            return nil
        }
        guard store.food(template.id) == original else {
            errors = ["This recipe changed while you were editing. Your draft is still here. Reopen the recipe to review the latest version."]
            return nil
        }
        do {
            let food = try recipe(locale: locale)
            try store.saveFood(food)
            original = food
            return food
        } catch { errors = NutritionDraftError.messages(error) }
        return nil
    }
}
