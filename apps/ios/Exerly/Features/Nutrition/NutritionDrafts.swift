import Combine
import ExerlyCore
import Foundation

/// The text shown for an existing value may be rounded, but leaving it alone
/// must not round the stored value as a side effect of editing another field.
struct NutritionNumberField: Equatable {
    var text: String
    private let initialText: String
    private let original: Double?

    init(_ value: Double? = nil) {
        original = value
        text = value.map(TrainingFormat.number) ?? ""
        initialText = text
    }

    func value(named name: String, locale: Locale) throws -> Double? {
        if text == initialText { return original }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let value = TrainingInput.number(text, locale: locale) else {
            throw NutritionDraftError.input("Enter a number for \(name), or leave it blank if unknown.")
        }
        return value
    }
}

enum NutritionDraftError: LocalizedError {
    case input(String)
    var errorDescription: String? {
        switch self {
        case .input(let message): message
        }
    }

    static func messages(_ error: Error) -> [String] {
        if case NutritionStore.StoreError.invalid(let messages) = error { return messages }
        if let error = error as? NutritionDraftError { return [error.localizedDescription] }
        return ["Could not save. Your draft is still here. Try again."]
    }
}

struct NutritionServingFields: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var grams: NutritionNumberField

    init(_ serving: Serving? = nil) {
        name = serving?.name ?? ""
        grams = NutritionNumberField(serving?.grams)
    }

    func value(locale: Locale) throws -> Serving {
        guard let amount = try grams.value(named: "serving weight", locale: locale) else {
            throw NutritionDraftError.input("Enter the serving's weight in grams.")
        }
        return Serving(name.trimmingCharacters(in: .whitespacesAndNewlines), grams: amount)
    }
}

@MainActor
final class NutritionFoodDraft: ObservableObject {
    enum Basis: String, CaseIterable { case per100g = "Per 100 g", perServing = "Per serving" }
    @Published var name: String
    @Published var brand: String
    @Published var nutrients: [Nutrient: NutritionNumberField]
    @Published var servings: [NutritionServingFields]
    @Published var basis = Basis.per100g
    @Published var labelGrams = NutritionNumberField()
    @Published var favorite: Bool
    @Published private(set) var errors: [String] = []
    private let store: NutritionStore
    private var original: ExerlyCore.Food?
    private let template: ExerlyCore.Food
    private let initialNutrients: [Nutrient: NutritionNumberField]
    private let initialServings: [NutritionServingFields]

    /// `start` begins a new food from another's label, as a duplicate does.
    init(store: NutritionStore, editing: ExerlyCore.Food? = nil, start: ExerlyCore.Food? = nil) {
        self.store = store
        original = editing
        let food = editing ?? start ?? ExerlyCore.Food(name: "", per100g: NutrientAmounts())
        template = food
        name = food.name
        brand = food.brand ?? ""
        favorite = food.favorite
        let fields = Dictionary(uniqueKeysWithValues: Nutrient.allCases.map { ($0, NutritionNumberField(food.per100g[$0])) })
        nutrients = fields
        initialNutrients = fields
        let portions = food.servings.map { NutritionServingFields($0) }
        servings = portions
        initialServings = portions
    }

    convenience init(store: NutritionStore, label: LabelReading) {
        self.init(store: store)
        nutrients = Dictionary(uniqueKeysWithValues: Nutrient.allCases.map { ($0, NutritionNumberField(label.amounts[$0])) })
        basis = label.basis == .per100g ? .per100g : .perServing
        if label.basis == .serving { labelGrams = NutritionNumberField(label.servingGrams) }
        if let grams = label.servingGrams, label.basis != .per100ml {
            servings = [NutritionServingFields(Serving(label.servingText ?? "Label serving", grams: grams))]
        }
    }

    var hasChanges: Bool {
        name != template.name || brand != (template.brand ?? "") || favorite != template.favorite ||
            nutrients != initialNutrients || servings != initialServings || basis != .per100g || !labelGrams.text.isEmpty
    }

    func food(locale: Locale = .current) throws -> ExerlyCore.Food {
        var amounts = NutrientAmounts()
        for nutrient in Nutrient.allCases {
            amounts[nutrient] = try nutrients[nutrient]?.value(named: nutrient.name, locale: locale)
        }
        if basis == .perServing {
            guard let weight = try labelGrams.value(named: "label serving weight", locale: locale) else {
                throw NutritionDraftError.input("Enter the weight for the label's serving.")
            }
            amounts = try ExerlyCore.Food.per100g(fromLabel: amounts, servingGrams: weight)
        }
        var food = template
        food.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        food.brand = cleanBrand.isEmpty ? nil : cleanBrand
        food.per100g = amounts
        food.servings = try servings.map { try $0.value(locale: locale) }
        food.favorite = favorite
        return food
    }

    @discardableResult
    func save(locale: Locale = .current) -> ExerlyCore.Food? {
        errors = []
        guard store.food(template.id) == original else {
            errors = ["This food changed while you were editing. Your draft is still here. Reopen the food to review the latest version."]
            return nil
        }
        do {
            let food = try food(locale: locale)
            try store.saveFood(food)
            original = food
            return food
        } catch { errors = NutritionDraftError.messages(error) }
        return nil
    }
}

@MainActor
final class NutritionEntryDraft: ObservableObject {
    @Published var amount: NutritionNumberField { didSet { if !convertingAmount { amountIsDefault = false } } }
    /// True while a new food's amount is still its default, before the
    /// person enters one: choosing a named serving then means one of it.
    private(set) var amountIsDefault: Bool
    private var convertingAmount = false
    @Published private(set) var measure: NutritionPortionMeasure
    @Published var date: LocalDate
    /// Choosing another meal moves a time no one has set to that meal's usual time.
    @Published var meal: String { didSet { if meal != oldValue { followMeal() } } }
    @Published var loggedAt: Date
    @Published private(set) var snapshot: FoodSnapshot
    @Published private(set) var errors: [String] = []
    /// The food as logged; `addServing` gives it a serving.
    @Published private(set) var food: ExerlyCore.Food
    private let store: NutritionStore
    private let timeZone: TimeZone
    /// The time last set for the person rather than by them.
    private var suggestedTime: Date
    private var original: FoodEntry?
    private let entryID: UUID
    private let initialAmount: NutritionNumberField
    private let initialMeasure: NutritionPortionMeasure
    private let initialDate: LocalDate
    private let initialMeal: String
    private let initialTime: Date
    private let initialSnapshot: FoodSnapshot
    private let preferredUnit: MassUnit
    private let initialAnchor: PortionAnchor?
    private var anchor: PortionAnchor?

    private struct PortionAnchor {
        let measure: NutritionPortionMeasure
        let amount: NutritionNumberField
        let grams: Double
        let serving: Serving?
        let quantity: Double?
    }

    init(store: NutritionStore, food: ExerlyCore.Food, date: LocalDate, meal: String,
         editing: FoodEntry? = nil, repeating: FoodEntry? = nil, now: Date = Date(), preferredUnit: MassUnit = .pounds,
         timeZone: TimeZone = .current) {
        self.store = store
        self.preferredUnit = preferredUnit
        self.timeZone = timeZone
        var loggingFood = editing.map { $0.food.foodForLogging(serving: $0.serving) } ?? food
        if let editing {
            // The food it came from, saved or just found, offers its other servings.
            let sources = [food] + [store.food(editing.food.foodID)].compactMap { $0 }
            for serving in sources.flatMap({ $0.servings + $0.recipePortions }) where !loggingFood.servings.contains(serving) {
                loggingFood.servings.append(serving)
            }
        }
        self.food = loggingFood
        original = editing
        entryID = editing?.id ?? UUID()
        let previous = editing ?? repeating.flatMap { $0.food.foodID == food.id ? $0 : nil }
        var entrySnapshot = editing?.food ?? food.snapshot
        if editing == nil, previous?.food.edited == true, previous?.food.per100g == food.per100g {
            entrySnapshot.edited = true
        }
        snapshot = entrySnapshot
        initialSnapshot = entrySnapshot
        // A new food starts where one tap on its row would: Core's default portion.
        let fallback = previous == nil ? NutritionStore.defaultPortion(loggingFood, unit: preferredUnit) : nil
        let measure: NutritionPortionMeasure
        let entered: Double
        if let previous {
            measure = NutritionPortionMeasure.saved(previous.serving, food: loggingFood)
            entered = previous.serving.map { previous.quantity ?? $0.quantity(grams: previous.grams) } ?? previous.grams
        } else if let fallback {
            measure = NutritionPortionMeasure.saved(fallback.serving, food: loggingFood)
            entered = fallback.quantity
        } else {
            measure = NutritionPortionMeasure.preferred(for: loggingFood, unit: preferredUnit)
            entered = measure.initialAmount
        }
        self.measure = measure
        initialMeasure = measure
        let field = NutritionNumberField(entered)
        amount = field
        initialAmount = field
        amountIsDefault = previous == nil
        let serving = measure.portion(in: loggingFood)
        let preview = try? NutritionStore.preview(loggingFood, grams: serving == nil ? entered : nil,
                                                  serving: serving, quantity: serving == nil ? nil : entered)
        let grams = previous?.grams ?? preview?.grams
        let initialAnchor = grams.map { PortionAnchor(measure: measure, amount: field, grams: $0,
            serving: previous?.serving ?? serving, quantity: previous.map(\.quantity) ?? preview?.quantity) }
        self.initialAnchor = initialAnchor
        anchor = initialAnchor
        self.date = editing?.date ?? date
        initialDate = editing?.date ?? date
        self.meal = editing?.meal ?? meal
        initialMeal = editing?.meal ?? meal
        loggedAt = editing?.loggedAt ?? now.roundedToMilliseconds
        initialTime = editing?.loggedAt ?? now.roundedToMilliseconds
        suggestedTime = editing?.loggedAt ?? now.roundedToMilliseconds
    }

    private func followMeal() {
        guard loggedAt == suggestedTime else { return }
        let meal = meal.trimmingCharacters(in: .whitespacesAndNewlines)
        loggedAt = meal != initialMeal ? store.usualTime(of: meal, on: date, timeZone: timeZone)
            : date == initialDate ? initialTime : NutritionFormat.sameTime(initialTime, on: date, timeZone: timeZone)
        suggestedTime = loggedAt
    }

    /// When it was eaten, on its diary day. The sheet sets both with one
    /// control, so moving the day keeps the time of day.
    var eatenAt: Date {
        get { NutritionFormat.sameTime(loggedAt, on: date, timeZone: timeZone) }
        set {
            // A time set for the person still follows the meal when only the day moved.
            let follows = loggedAt == suggestedTime
                && NutritionFormat.clock(newValue, timeZone: timeZone) == NutritionFormat.clock(eatenAt, timeZone: timeZone)
            date = LocalDate(newValue, in: timeZone)
            loggedAt = newValue.roundedToMilliseconds
            if follows { suggestedTime = loggedAt }
        }
    }

    var hasChanges: Bool {
        amount != initialAmount || measure != initialMeasure || date != initialDate || meal != initialMeal ||
            loggedAt != initialTime || snapshot != initialSnapshot
    }

    var serving: Serving? { measure.portion(in: food) }

    var availableMeasures: [NutritionPortionMeasure] {
        var measures = NutritionPortionMeasure.available(for: food, unit: preferredUnit)
        if !measures.contains(measure) { measures.append(measure) }
        return measures
    }

    var publishedServings: [Serving] {
        guard snapshot.unweighed != true else { return [] }
        return (food.servings + food.recipePortions + food.kitchenMeasures).reduce(into: []) { result, serving in
            // Reopened entries also carry a synthetic oz/ml/fl oz serving.
            // Those are measures, not portions supplied by the food label.
            guard case .serving = NutritionPortionMeasure.saved(serving, food: food) else { return }
            if !result.contains(serving) { result.append(serving) }
        }
    }

    /// Choosing a label portion replaces the amount. Switching its measure
    /// below preserves the current amount instead.
    @discardableResult
    func selectPortion(_ serving: Serving, quantity: Double = 1) -> Bool {
        errors = []
        do {
            guard publishedServings.contains(serving) else {
                throw NutritionDraftError.input("Choose a portion provided for this food.")
            }
            let portion = try NutritionStore.preview(snapshot.foodForLogging(serving: serving), serving: serving, quantity: quantity)
            let selected = NutritionPortionMeasure.saved(serving, food: food)
            let field = NutritionNumberField(quantity)
            anchor = PortionAnchor(measure: selected, amount: field, grams: portion.grams,
                                   serving: portion.serving, quantity: portion.quantity)
            measure = selected
            convertingAmount = true
            amount = field
            convertingAmount = false
            return true
        } catch { errors = NutritionDraftError.messages(error); return false }
    }

    /// Whether the person can name a serving of this food here: it is their
    /// own saved food, not a recipe, and has no serving to count it by.
    var canAddServing: Bool {
        guard snapshot.unweighed != true, let saved = store.food(food.id), saved.archivedAt == nil,
              [.custom, .imported].contains(saved.source), saved.ingredients == nil else { return false }
        return publishedServings.allSatisfy(food.kitchenMeasures.contains)
    }

    /// Saves a serving such as "1 slice" (a name without a count gets "1 ")
    /// with the person's food, then switches to `count` of it, so the next
    /// "1 slice toast" logs in one tap.
    @discardableResult
    func addServing(named name: String, grams text: String, count: Double = 1, locale: Locale = .current) -> Bool {
        errors = []
        do {
            var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw NutritionDraftError.input("Name the serving, as in 1 slice.") }
            if trimmed.first?.isNumber != true { trimmed = "1 \(trimmed)" }
            guard let grams = TrainingInput.number(text, locale: locale), grams.isFinite, grams > 0 else {
                throw NutritionDraftError.input("Enter the serving's weight in grams.")
            }
            guard var saved = store.food(food.id) else { throw NutritionDraftError.input("Only your own foods can be given a serving.") }
            let serving = Serving(trimmed, grams: grams)
            saved.servings.append(serving)
            try store.saveFood(saved)
            food.servings.append(serving)
            return selectPortion(serving, quantity: count / serving.count)
        } catch { errors = NutritionDraftError.messages(error); return false }
    }

    @discardableResult
    func selectMeasure(_ selected: NutritionPortionMeasure, locale: Locale = .current) -> Bool {
        guard selected != measure else { return true }
        errors = []
        do {
            guard availableMeasures.contains(selected) else {
                throw NutritionDraftError.input("This food has no weight for that measure.")
            }
            let current = try preview(locale: locale)
            let serving = selected.portion(in: food)
            let quantity = serving?.quantity(grams: current.grams)
            let field: NutritionNumberField
            if let initialAnchor, initialAnchor.measure == selected, initialAnchor.grams == current.grams {
                field = initialAnchor.amount
                anchor = initialAnchor
            } else {
                field = NutritionNumberField(quantity ?? current.grams)
                anchor = PortionAnchor(measure: selected, amount: field, grams: current.grams,
                                       serving: serving, quantity: quantity)
            }
            measure = selected
            convertingAmount = true
            amount = field
            convertingAmount = false
            return true
        } catch { errors = NutritionDraftError.messages(error); return false }
    }

    func preview(locale: Locale = .current) throws -> LoggedAmount {
        let currentFood = snapshot.foodForLogging(serving: serving)
        guard let value = try amount.value(named: serving == nil ? "grams" : "quantity", locale: locale) else {
            throw NutritionDraftError.input("Enter an amount to log.")
        }
        if let anchor, amount == anchor.amount, measure == anchor.measure {
            return try NutritionStore.preview(currentFood, grams: anchor.grams, serving: anchor.serving, quantity: anchor.quantity)
        }
        return try NutritionStore.preview(currentFood, grams: serving == nil ? value : nil,
                                          serving: serving, quantity: serving == nil ? nil : value)
    }

    func reviewNutrition(locale: Locale = .current) -> FoodEntry? {
        errors = []
        do { return try stagedEntry(locale: locale) } catch {
            errors = NutritionDraftError.messages(error)
            return nil
        }
    }

    func applyNutrition(_ corrected: FoodEntry, reviewed: FoodEntry, locale: Locale = .current) throws {
        guard try stagedEntry(locale: locale) == reviewed else {
            throw NutritionDraftError.input("The portion changed while you were editing nutrition. Reopen nutrition to review its amounts.")
        }
        snapshot = corrected.food
        errors = []
    }

    private func stagedEntry(locale: Locale) throws -> FoodEntry {
        let portion = try preview(locale: locale)
        var entry = FoodEntry(id: entryID, date: date, meal: meal.trimmingCharacters(in: .whitespacesAndNewlines),
                              loggedAt: loggedAt.roundedToMilliseconds, food: snapshot,
                              grams: portion.grams, serving: portion.serving, quantity: portion.quantity)
        if let anchor, amount == anchor.amount, measure == anchor.measure {
            entry.grams = anchor.grams
            entry.serving = anchor.serving
            entry.quantity = anchor.quantity
        }
        return entry
    }

    /// Logs this portion of a recipe as its ingredients, each scaled to it,
    /// instead of as one entry.
    func saveIngredients(of recipe: ExerlyCore.Food, locale: Locale = .current) -> [FoodEntry]? {
        errors = []
        do {
            let portion = try preview(locale: locale)
            return try store.logIngredients(of: recipe, grams: portion.grams, on: date,
                                            meal: meal.trimmingCharacters(in: .whitespacesAndNewlines), at: loggedAt)
        } catch { errors = NutritionDraftError.messages(error) }
        return nil
    }

    @discardableResult
    func save(locale: Locale = .current) -> FoodEntry? {
        errors = []
        guard store.entries.first(where: { $0.id == entryID }) == original else {
            errors = ["This entry changed while you were editing. Your draft is still here. Reopen the entry to review the latest version."]
            return nil
        }
        do {
            let entry = try stagedEntry(locale: locale)
            try store.saveEntry(entry)
            // As saved: a changed amount is marked there.
            let saved = store.entries.first { $0.id == entry.id } ?? entry
            original = saved
            return saved
        } catch { errors = NutritionDraftError.messages(error) }
        return nil
    }
}

@MainActor
final class NutritionLibraryActions: ObservableObject {
    @Published private(set) var error: String?
    private let store: NutritionStore

    init(store: NutritionStore) { self.store = store }

    func clearError() { error = nil }

    @discardableResult
    func keepFavorite(_ food: ExerlyCore.Food, reviewed saved: ExerlyCore.Food?) -> Bool {
        error = nil
        guard saved == nil || saved?.id == food.id, store.food(food.id) == saved else {
            error = "This food changed. Review the saved label before changing its favorite status."
            return false
        }
        do {
            var favorite = saved ?? food
            favorite.favorite = true
            try store.saveFood(favorite)
            return true
        } catch { self.error = NutritionDraftError.messages(error).joined(separator: " "); return false }
    }

    @discardableResult
    func setFavorite(_ favorite: Bool, reviewed food: ExerlyCore.Food) -> Bool {
        perform(reviewed: food) { try store.setFavorite(food.id, favorite) }
    }

    @discardableResult
    func archive(reviewed food: ExerlyCore.Food) -> Bool {
        perform(reviewed: food) { try store.archiveFood(food.id) }
    }

    @discardableResult
    func restore(reviewed food: ExerlyCore.Food) -> Bool {
        perform(reviewed: food) {
            var restored = food
            restored.archivedAt = nil
            try store.saveFood(restored)
        }
    }

    private func perform(reviewed food: ExerlyCore.Food, action: () throws -> Void) -> Bool {
        error = nil
        guard store.food(food.id) == food else {
            error = "This food changed after you opened the review. Review the latest label before trying again."
            return false
        }
        do { try action(); return true } catch {
            self.error = NutritionDraftError.messages(error).joined(separator: " ")
            return false
        }
    }
}

@MainActor
final class NutritionDiaryActions: ObservableObject {
    @Published private(set) var deleted: FoodEntry?
    @Published private(set) var error: String?
    private let store: NutritionStore

    init(store: NutritionStore) { self.store = store }

    func clearError() { error = nil }

    @discardableResult
    func setStatus(_ status: DayStatus, reviewed: NutritionDay, entries: [FoodEntry]) -> Bool {
        error = nil
        guard store.day(reviewed.date) == reviewed, store.entries(on: reviewed.date) == entries else {
            error = "This day's log changed after you opened the review. Review the latest entries before changing its status."
            return false
        }
        do {
            try store.setStatus(status, on: reviewed.date)
            return true
        } catch {
            self.error = "Could not change the logging status. Your saved status is unchanged. Try again."
            return false
        }
    }

    @discardableResult
    func delete(_ reviewed: FoodEntry) -> Bool {
        error = nil
        guard store.entries.first(where: { $0.id == reviewed.id }) == reviewed else {
            error = "This entry changed after you opened it. Reopen it to review the latest version before deleting."
            return false
        }
        do {
            try store.deleteEntry(reviewed.id)
            deleted = reviewed
            return true
        } catch {
            self.error = "Could not delete this entry. It is still saved. Try again."
            return false
        }
    }

    @discardableResult
    func undoDeletion() -> Bool {
        error = nil
        guard let deleted else { return false }
        guard !store.entries.contains(where: { $0.id == deleted.id }) else {
            error = "This entry was restored or changed elsewhere. Undo would overwrite it. Review the saved entry instead."
            return false
        }
        do {
            try store.saveEntry(deleted)
            self.deleted = nil
            return true
        } catch {
            self.error = "Could not undo the deletion. Try again."
            return false
        }
    }
}

@MainActor
final class NutritionDayNotesDraft: ObservableObject {
    @Published var text: String
    @Published private(set) var error: String?
    private let store: NutritionStore
    private let date: LocalDate
    private var original: String

    init(store: NutritionStore, date: LocalDate) {
        self.store = store
        self.date = date
        original = store.day(date).notes
        text = original
    }

    var hasChanges: Bool { text != original }

    @discardableResult
    func save() -> Bool {
        error = nil
        guard store.day(date).notes == original else {
            error = "This note changed on another screen or device. Your draft is still here. Reopen the note to review the latest version."
            return false
        }
        do {
            try store.setNotes(text, on: date)
            original = text
            return true
        } catch {
            self.error = "Could not save the note. Your draft is still here. Try again."
            return false
        }
    }
}

@MainActor
final class NutritionCopyDraft: ObservableObject {
    let source: LocalDate
    let sourceMeal: String?
    let entries: [FoodEntry]
    @Published var target: LocalDate
    @Published var targetMeal: String?
    @Published private(set) var error: String?
    @Published private(set) var completed = false
    private let store: NutritionStore

    init(store: NutritionStore, source: LocalDate, meal: String?, target: LocalDate) {
        self.store = store
        self.source = source
        sourceMeal = meal
        self.target = target
        targetMeal = meal
        entries = store.entries(on: source).filter { meal == nil || $0.meal == meal }
    }

    @discardableResult
    func copy() -> [FoodEntry]? {
        guard !completed else { return nil }
        error = nil
        guard store.entries(on: source).filter({ sourceMeal == nil || $0.meal == sourceMeal }) == entries else {
            error = "The source log changed after you opened this review. Reopen Copy to review the latest entries."
            return nil
        }
        guard !entries.isEmpty else { error = "There are no entries to copy."; return nil }
        do {
            let copied = try store.copy(from: source, meal: sourceMeal, to: target, meal: targetMeal)
            completed = true
            return copied
        } catch {
            self.error = "Could not copy these entries. No copies were saved. Try again."
            return nil
        }
    }
}

extension FoodEntry {
    /// An entry not yet logged, for a portion editor to open at `amount`.
    init(starting amount: LoggedAmount, of food: ExerlyCore.Food, on date: LocalDate, meal: String) {
        self.init(date: date, meal: meal, loggedAt: Date(), food: food.snapshot, grams: amount.grams, serving: amount.serving,
                  quantity: amount.quantity)
    }
}

extension ExerlyCore.FoodSnapshot {
    /// Reconstruct the label for a portion editor without dropping its volume basis.
    func foodForLogging(serving: Serving? = nil) -> ExerlyCore.Food {
        var food = ExerlyCore.Food(id: foodID, name: name, brand: brand, source: source,
                                  per100g: per100g, servings: serving.map { [$0] } ?? [])
        food.volume = volume
        return food
    }
}
