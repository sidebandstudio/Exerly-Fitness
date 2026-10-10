import Combine
import ExerlyCore
import Foundation

@MainActor
final class NutritionPlateDraft: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let food: ExerlyCore.Food
        let amount: LoggedAmount
        /// False while it sits at a default amount no one has looked at.
        var checked = true

        func entry(on date: LocalDate, meal: String, at time: Date) -> FoodEntry {
            FoodEntry(id: id, date: date, meal: meal, loggedAt: time, food: food.snapshot,
                      grams: amount.grams, serving: amount.serving, quantity: amount.quantity)
        }

        var item: NutritionStore.PlateItem {
            NutritionStore.PlateItem(food, grams: amount.grams, serving: amount.serving, quantity: amount.quantity)
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var summary: NutritionSummary?
    @Published private(set) var progress: DayProgress?
    @Published private(set) var error: String?
    @Published var date: LocalDate
    /// Choosing another meal moves a time no one has set to that meal's usual time.
    @Published var meal: String { didSet { if meal != oldValue { followMeal() } } }
    @Published var loggedAt: Date
    let unit: MassUnit
    private let store: NutritionStore
    private let previewDate: LocalDate
    private let timeZone: TimeZone
    private let initialMeal: String
    private let initialTime: Date
    private var suggestedTime: Date
    private var saved: [FoodEntry]?

    init(store: NutritionStore, date: LocalDate, meal: String, unit: MassUnit = .pounds, now: Date = Date(),
         timeZone: TimeZone = .current) {
        self.store = store
        self.date = date
        self.meal = meal
        self.unit = unit
        self.previewDate = date
        self.timeZone = timeZone
        initialMeal = meal
        loggedAt = now.roundedToMilliseconds
        initialTime = now.roundedToMilliseconds
        suggestedTime = now.roundedToMilliseconds
    }

    private func followMeal() {
        guard loggedAt == suggestedTime else { return }
        let meal = meal.trimmingCharacters(in: .whitespacesAndNewlines)
        loggedAt = meal != initialMeal ? store.usualTime(of: meal, on: date, timeZone: timeZone)
            : date == previewDate ? initialTime : NutritionFormat.sameTime(initialTime, on: date, timeZone: timeZone)
        suggestedTime = loggedAt
    }

    /// When it was eaten, on its diary day, as the portion sheet sets it.
    var eatenAt: Date {
        get { NutritionFormat.sameTime(loggedAt, on: date, timeZone: timeZone) }
        set {
            let follows = loggedAt == suggestedTime
                && NutritionFormat.clock(newValue, timeZone: timeZone) == NutritionFormat.clock(eatenAt, timeZone: timeZone)
            date = LocalDate(newValue, in: timeZone)
            loggedAt = newValue.roundedToMilliseconds
            if follows { suggestedTime = loggedAt }
        }
    }

    /// Adds a food at the amount chosen for it, or else at the amount the
    /// person logs it at, or its default. A default left unchecked stays
    /// marked until they look at it.
    @discardableResult
    func add(_ food: ExerlyCore.Food, amount chosen: FoodPickAmount = .usual) -> Bool {
        if case .chosen(let amount, _) = chosen { return stage(food, amount: amount) }
        let draft = NutritionEntryDraft(store: store, food: food, date: date, meal: meal,
                                       repeating: store.rememberedEntry(for: food.id), preferredUnit: unit)
        guard let entry = draft.reviewNutrition() else { error = draft.errors.joined(separator: " "); return false }
        do {
            let amount = try NutritionStore.preview(food, grams: entry.grams, serving: entry.serving,
                quantity: entry.quantity ?? entry.serving?.quantity(grams: entry.grams))
            if case .unchecked = chosen { return stage(food, amount: amount, checked: false) }
            return stage(food, amount: amount)
        } catch { self.error = NutritionDraftError.messages(error).joined(separator: " "); return false }
    }

    @discardableResult
    func stage(_ food: ExerlyCore.Food, amount: LoggedAmount, replacing reviewed: Row? = nil, checked: Bool = true) -> Bool {
        guard saved == nil else { error = "This meal is already logged. Start a new meal to add more foods."; return false }
        let row = Row(id: reviewed?.id ?? UUID(), food: food, amount: amount, checked: checked)
        var updated = rows
        if let reviewed {
            guard let index = rows.firstIndex(of: reviewed) else {
                error = "This portion changed after you opened it. Reopen it to review the current amount."
                return false
            }
            updated[index] = row
        } else { updated.append(row) }
        return update(updated)
    }

    @discardableResult
    func remove(_ row: Row) -> Bool {
        guard saved == nil, rows.contains(row) else {
            error = "This meal changed. Review the current foods before removing a portion."
            return false
        }
        return update(rows.filter { $0.id != row.id })
    }

    /// The first food still at a default amount, to look at before logging.
    var unchecked: Row? { rows.first { !$0.checked } }

    @discardableResult
    func save() -> [FoodEntry]? {
        if let saved { return saved }
        error = nil
        guard !rows.isEmpty else { error = "Add at least one food to your meal."; return nil }
        if let unchecked {
            error = "Check the amount of \(unchecked.food.name) before logging. It came in at a default."
            return nil
        }
        do {
            let entries = try store.log(rows.map(\.item), on: date,
                                        meal: meal.trimmingCharacters(in: .whitespacesAndNewlines), at: loggedAt)
            saved = entries
            return entries
        } catch { self.error = NutritionDraftError.messages(error).joined(separator: " "); return nil }
    }

    private func update(_ proposed: [Row]) -> Bool {
        do {
            // Core validates and totals the complete draft without writing any
            // account records. Reuse the same path that will log the final meal.
            let preview = try NutritionStore(persistence: InMemoryTrainingPersistence())
            try preview.log(proposed.map(\.item), on: previewDate, meal: "Meal preview")
            rows = proposed
            summary = preview.summary(on: previewDate)
            progress = preview.progress(on: previewDate)
            error = nil
            return true
        } catch { self.error = NutritionDraftError.messages(error).joined(separator: " "); return false }
    }
}
