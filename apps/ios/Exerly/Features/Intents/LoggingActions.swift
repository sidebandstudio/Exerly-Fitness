import ExerlyCore
import Foundation
import SwiftData
import WidgetKit

/// Why a logging intent couldn't run, in words that can be read aloud.
enum LoggingIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case signedOut
    case unavailable
    case invalid(String)

    init(_ error: Error) {
        if let error = error as? LoggingIntentError {
            self = error
        } else if case NutritionStore.StoreError.invalid(let problems) = error {
            let text = problems.joined(separator: "; ")
            self = .invalid(text.prefix(1).uppercased() + text.dropFirst() + ".")
        } else {
            self = .invalid("Nothing was saved. Open Exerly and try again.")
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Open Exerly and sign in first."
        case .unavailable: "Your saved data couldn't open. Open Exerly and try again."
        case .invalid(let message): "\(message)"
        }
    }
}

/// The signed-in account's data for an intent. Intents run in the app's
/// process, which may have been launched in the background just for them.
/// With the account's screens open, the change goes through their workspace
/// and syncs as theirs do. Otherwise the account's workspace is opened for it
/// and closed again, and the change syncs when Exerly next opens, like one
/// made offline.
@MainActor
struct IntentAccess {
    struct Account {
        let workspace: TrainingWorkspace
        let unit: MassUnit
        let timeZone: TimeZone
        var store: NutritionStore { workspace.nutrition }
    }

    var screens: TrainingWorkspace? = WorkoutActivityActions.account?.training
    var token: String? = KeychainService.shared.getToken()
    var root: URL?
    var widgets: URL? = WidgetSnapshot.defaultURL
    var unit: MassUnit = .saved
    var defaults: UserDefaults = .standard

    func perform<T>(changing: Bool = true, _ body: (Account) throws -> T) async throws -> T {
        guard let token, let accountID = APIClient.accountID(in: token) else { throw LoggingIntentError.signedOut }
        let timeZone = timeZone(for: token)
        if let screens, screens.accountID == accountID {
            do {
                let result = try body(Account(workspace: screens, unit: unit, timeZone: timeZone))
                if changing { Task { await screens.synchronize() } }
                return result
            } catch { throw LoggingIntentError(error) }
        }
        // Everything up to closing runs without suspending, so the screens
        // can't open the same database mid-change.
        guard let workspace = try? TrainingWorkspace(accountID: accountID, root: root) else { throw LoggingIntentError.unavailable }
        let result = Result { try body(Account(workspace: workspace, unit: unit, timeZone: timeZone)) }
        // The screens' writer keeps the widgets current; without them, this does once.
        if changing, case .success = result,
           (try? WidgetSnapshotWriter(workspace: workspace, unit: unit, timeZone: timeZone).snapshot(at: .now).write(to: widgets)) == true {
            WidgetCenter.shared.reloadAllTimelines()
        }
        await workspace.close()
        return try result.mapError(LoggingIntentError.init).get()
    }

    /// The account's time zone as the screens use it, from the profile saved
    /// at sign-in; the device's before there is one.
    private func timeZone(for token: String) -> TimeZone {
        guard let data = defaults.data(forKey: APIClient.accountCacheKey(token)),
              let user = try? JSONDecoder().decode(UserDTO.self, from: data) else { return .current }
        return TimeZone(identifier: user.timezone ?? "UTC") ?? .gmt
    }
}

/// What each logging intent does to the account's data and says back. Each
/// makes the same store call as the screen it stands in for.
@MainActor
enum LoggingActions {
    // MARK: Weight

    /// Today's weigh-in sheet, saved without changing the number: a reading
    /// in the person's unit, now. Then the trend, once there is one.
    static func logWeight(_ value: Double, in account: IntentAccess.Account, now: Date = .now) throws -> String {
        let store = account.store, unit = account.unit
        let range = WeightRuler.range(for: unit)
        guard range.contains(value) else {
            throw LoggingIntentError.invalid("Enter a weight from \(BodyFormat.number(range.lowerBound, digits: 0)) to "
                + "\(BodyFormat.number(range.upperBound, digits: 0)) \(unit.rawValue).")
        }
        let entry = try store.logWeight(Mass((value * 100).rounded() / 100, unit), at: now, timeZone: account.timeZone)
        var text = "Logged \(BodyFormat.reading(entry.weight, unit))."
        let today = LocalDate(now, in: account.timeZone)
        if store.weights.count > 1,
           let summary = WeightTrend.summary(BodyEstimates.shared.estimates(store, through: today), through: today) {
            text += " Trend \(BodyFormat.weight(summary.trend, unit))"
            if let week = summary.weekChange { text += ", \(BodyCopy.spokenWeekChange(week, unit))" }
            text += "."
        }
        return text
    }

    // MARK: Food

    /// Today's Quick add sheet: calories and any macros, to the meal given or
    /// the one usually logged at this time.
    static func quickAdd(calories: Double, protein: Double?, carbs: Double?, fat: Double?, meal: String?,
                         in account: IntentAccess.Account, now: Date = .now) throws -> String {
        let store = account.store, today = LocalDate(now, in: account.timeZone)
        let meal = meal ?? store.suggestedMeal(at: now, timeZone: account.timeZone)
        var amounts = NutrientAmounts()
        amounts[.energy] = calories
        amounts[.protein] = protein
        amounts[.carbohydrate] = carbs
        amounts[.fat] = fat
        let entry = try store.quickAdd(amounts, name: "", on: today, meal: meal)
        return sentences("Logged \(FoodFormat.kcal(entry.nutrients.energy)) kcal to \(meal).", left(store, today))
    }

    /// Today's usual foods for this time, then recent ones, each with the
    /// portion one tap logs, as Today's chips and the food picker list them.
    static func usualFoods(in account: IntentAccess.Account, now: Date = .now) -> [QuickPortion] {
        let usual = suggested(account, now: now).map(QuickPortion.init)
        let ids = Set(usual.map(\.id))
        return usual + account.store.recentPortions(limit: 30).filter { !ids.contains($0.id) }
    }

    /// Foods on this device matching a search, as the food picker finds them
    /// offline: history first, then saved foods.
    static func foods(matching text: String, in account: IntentAccess.Account) -> [QuickPortion] {
        let store = account.store, term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return usualFoods(in: account) }
        func matches(_ name: String, _ brand: String?) -> Bool {
            name.localizedCaseInsensitiveContains(term) || (brand?.localizedCaseInsensitiveContains(term) ?? false)
        }
        let history = store.recentPortions(limit: 200).filter { matches($0.food.name, $0.food.brand) }
        let saved = store.foods.filter { $0.archivedAt == nil && matches($0.name, $0.brand) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { store.quickPortion(for: $0, unit: account.unit) }
        var seen = Set<String>()
        return (history + saved).filter { seen.insert($0.id).inserted }.prefix(12).map { $0 }
    }

    /// The portion one tap logs for a food: as suggested at this time of day,
    /// else as last logged, else a saved food's first serving.
    static func portion(of foodID: String, in account: IntentAccess.Account, now: Date = .now) -> QuickPortion? {
        let store = account.store
        if let usual = suggested(account, now: now).first(where: { $0.food.foodID == foodID }) { return QuickPortion(usual) }
        if let recent = store.recentPortions(limit: 500).first(where: { $0.id == foodID }) { return recent }
        return store.food(foodID).flatMap { $0.archivedAt == nil ? store.quickPortion(for: $0, unit: account.unit) : nil }
    }

    /// The person's own foods, for Spotlight: recently logged, then saved
    /// foods and recipes, each once with the portion one tap logs.
    static func ownFoods(in account: IntentAccess.Account) -> [QuickPortion] {
        let store = account.store
        let saved = store.foods.filter { $0.archivedAt == nil }.compactMap { store.quickPortion(for: $0, unit: account.unit) }
        var seen = Set<String>()
        return (store.recentPortions(limit: 100) + saved).filter { seen.insert($0.id).inserted }
    }

    /// A food chosen in Spotlight: a usual or recent one is logged with its
    /// remembered portion and Today opens on its confirmation, with Undo;
    /// another opens its portion sheet.
    static func open(_ foodID: String, in account: IntentAccess.Account, now: Date = .now) throws -> URL {
        guard usualFoods(in: account, now: now).contains(where: { $0.id == foodID }) else { return ExerlyLinks.food(foodID) }
        let entry = try logEntry(foodID, servings: nil, in: account, now: now)
        return ExerlyLinks.logged(entry.id, accountID: account.workspace.accountID)
    }

    /// Today's first Log again chip for a time of day, logged into `meal`:
    /// a meal reminder's Log usual button.
    static func logUsual(_ meal: String, at time: Date, in account: IntentAccess.Account) throws -> String {
        guard let usual = suggested(account, now: time).first else {
            throw LoggingIntentError.invalid("There's no usual \(meal == "Snacks" ? "snack" : meal.lowercased()) to log. Search for it in Exerly.")
        }
        return try logFood(usual.food.foodID, servings: nil, meal: meal, in: account, now: time)
    }

    /// A usual food's one-tap log, into the meal given or the one for this
    /// time. Servings count the food's serving when it was logged by one,
    /// else multiples of the usual amount.
    static func logFood(_ foodID: String, servings: Double?, meal: String? = nil, in account: IntentAccess.Account,
                        now: Date = .now) throws -> String {
        try loggedFood(foodID, servings: servings, meal: meal, in: account, now: now).text
    }

    /// `logFood`, with the entry, for the answer's Undo.
    static func loggedFood(_ foodID: String, servings: Double?, meal: String? = nil, in account: IntentAccess.Account,
                           now: Date = .now) throws -> (text: String, entry: FoodEntry) {
        let entry = try logEntry(foodID, servings: servings, meal: meal, in: account, now: now)
        return (sentences("Logged \(entry.food.name), \(NutritionFormat.portion(entry, unit: account.unit)), to \(entry.meal).",
                          left(account.store, entry.date)), entry)
    }

    /// Takes back an entry a shortcut logged, if it's this account's and
    /// still logged; again, it does nothing. True when it took it back.
    @discardableResult
    static func undo(entry id: UUID, accountID: String, in account: IntentAccess.Account) throws -> Bool {
        guard account.workspace.accountID == accountID, account.store.entries.contains(where: { $0.id == id }) else { return false }
        try account.store.deleteEntry(id)
        return true
    }

    /// What the answer's snippet shows for an entry a shortcut logged: what
    /// and where, or nil once it's been taken back or isn't this account's.
    static func logged(entry id: UUID, accountID: String, in account: IntentAccess.Account) -> FoodEntry? {
        guard account.workspace.accountID == accountID else { return nil }
        return account.store.entries.first { $0.id == id }
    }

    private static func logEntry(_ foodID: String, servings: Double?, meal: String? = nil, in account: IntentAccess.Account,
                                 now: Date) throws -> FoodEntry {
        guard var portion = portion(of: foodID, in: account, now: now) else {
            throw LoggingIntentError.invalid("That food isn't in your recent or saved foods. Search for it in Exerly.")
        }
        if let servings {
            guard servings.isFinite, servings > 0 else { throw LoggingIntentError.invalid("Enter more than 0 servings.") }
            if let serving = portion.serving {
                portion.quantity = servings
                portion.grams = serving.grams * servings
            } else {
                portion.grams *= servings
            }
        }
        let store = account.store, today = LocalDate(now, in: account.timeZone)
        let meal = meal ?? store.suggestedMeal(at: now, timeZone: account.timeZone)
        return try store.log(portion, on: today, meal: meal)
    }

    /// The first of their foods matching a name, as Log a food finds it
    /// when the name is typed or spoken, logged with its usual portion.
    static func logFood(named name: String, servings: Double?, meal: String?, in account: IntentAccess.Account,
                        now: Date = .now) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let food = foods(matching: name, in: account).first else {
            throw LoggingIntentError.invalid("None of your foods is called \(name). Search for it in Exerly.")
        }
        return try logFood(food.id, servings: servings, meal: meal, in: account, now: now)
    }

    /// One of their foods by the digits under its barcode, with its usual
    /// portion. A barcode never logged before isn't looked up: its portion is
    /// checked in the scanner first.
    static func logBarcode(_ digits: String, servings: Double?, meal: String?, in account: IntentAccess.Account,
                           now: Date = .now) throws -> String {
        guard !GTIN.candidates(typed: digits).isEmpty else {
            throw LoggingIntentError.invalid("Enter the 8 to 14 digits under the barcode.")
        }
        guard let foodID = account.store.ownFoodID(barcode: digits) else {
            throw LoggingIntentError.invalid("That barcode isn't one of your foods yet. Scan it once in Exerly, and after that this logs it.")
        }
        return try logFood(foodID, servings: servings, meal: meal, in: account, now: now)
    }

    /// A food from another app's shortcut, in the "Log by JSON" format,
    /// into the meal given or the one for this time.
    static func logJSON(_ text: String, meal: String?, in account: IntentAccess.Account, now: Date = .now) throws -> String {
        let store = account.store, today = LocalDate(now, in: account.timeZone)
        let meal = meal ?? store.suggestedMeal(at: now, timeZone: account.timeZone)
        let data = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) != nil else {
            throw LoggingIntentError.invalid("Nothing was logged: that isn't JSON.")
        }
        let entry: FoodEntry
        do {
            entry = try store.logShortcutFood(data, on: today, meal: meal, at: now)
        } catch let problem as ShortcutsJSON.Problem {
            throw LoggingIntentError.invalid("Nothing was logged: \(problem).")
        }
        return sentences("Logged \(entry.food.name), \(FoodFormat.kcal(entry.nutrients.energy)) kcal, to \(meal).", left(store, today))
    }

    /// Today's consumption and what remains of each goal, as JSON for another
    /// app's shortcut.
    static func todaySummary(in account: IntentAccess.Account, now: Date = .now) throws -> String {
        String(bytes: try account.store.todaySummaryJSON(on: LocalDate(now, in: account.timeZone)), encoding: .utf8) ?? "{}"
    }

    /// Today's repeat button: the last time in the past week (or `days`
    /// days) the meal was logged, copied to today. Like Today, only into a
    /// meal still empty, so running it twice doesn't log the meal twice.
    static func repeatMeal(_ meal: String?, within days: Int = 7, in account: IntentAccess.Account, now: Date = .now) throws -> String {
        let store = account.store, zone = account.timeZone, today = LocalDate(now, in: zone)
        let meal = meal ?? store.suggestedMeal(at: now, timeZone: zone)
        guard !store.entries(on: today).contains(where: { $0.meal == meal }) else {
            return "\(meal) already has food today, so nothing was repeated."
        }
        guard let repeated = store.repeatable(meal, for: today, within: days) else {
            return "There's no \(meal.lowercased()) \(days == 1 ? "from yesterday" : "in the last week") to repeat."
        }
        let copied = try store.apply(repeated, to: today)
        let foods = copied.count == 1 ? "1 food" : "\(copied.count) foods"
        return sentences("Repeated \(day(repeated.source, today: today, zone: zone))'s \(meal.lowercased()): \(foods), "
            + "\(FoodFormat.kcal(repeated.energy)) kcal.", left(store, today))
    }

    /// Today's repeat-the-day button: the latest day in the past week with
    /// food, all of it copied to today. Only into an empty day, so running it
    /// twice doesn't log the day twice.
    static func repeatDay(within days: Int = 7, in account: IntentAccess.Account, now: Date = .now) throws -> String {
        let store = account.store, zone = account.timeZone, today = LocalDate(now, in: zone)
        guard store.entries(on: today).isEmpty else { return "Today already has food, so nothing was repeated." }
        guard let repeated = store.repeatable(nil, for: today, within: days) else {
            return "There's no day with food in the last week to repeat."
        }
        let copied = try store.apply(repeated, to: today)
        let foods = copied.count == 1 ? "1 food" : "\(copied.count) foods"
        let source = day(repeated.source, today: today, zone: zone)
        return sentences("Repeated \(source == "yesterday" ? source : source + "'s food"): \(foods), \(FoodFormat.kcal(repeated.energy)) kcal.",
                         left(store, today))
    }

    /// "yesterday", else the weekday.
    private static func day(_ source: LocalDate, today: LocalDate, zone: TimeZone) -> String {
        guard source != today.adding(days: -1) else { return "yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = zone
        return NutritionFormat.pickerDate(source, timeZone: zone).formatted(style)
    }

    /// Today's calories against the target, and protein.
    static func caloriesLeft(in account: IntentAccess.Account, now: Date = .now) -> String {
        let progress = account.store.progress(on: LocalDate(now, in: account.timeZone))
        let energy = progress.energy, eaten = FoodFormat.kcal(energy.consumed)
        var text: String
        if let target = energy.target, let remaining = energy.remaining, let over = energy.over {
            text = over >= 0.5
                ? "You've eaten \(eaten) kcal, \(FoodFormat.kcal(over)) over your target of \(FoodFormat.kcal(target))."
                : "You've eaten \(eaten) kcal and have \(FoodFormat.kcal(remaining)) left of \(FoodFormat.kcal(target))."
        } else {
            text = "You've eaten \(eaten) kcal today. You have no calorie target set."
        }
        let protein = FoodFormat.grams(progress.protein.consumed)
        text += progress.protein.target.map { " Protein \(protein) of \(FoodFormat.grams($0)) g." } ?? " Protein \(protein) g."
        return text
    }

    // MARK: Water

    /// Today's water row: a glass, or an amount in the person's units, added
    /// to today through the row's queue, so it syncs as the row's does. The
    /// queue is opened for the signed-in account when no screen has.
    static func logWater(_ amount: Double?, sync: SyncEngine? = nil, container: ModelContainer? = nil,
                         token: String? = KeychainService.shared.getToken(), defaults: UserDefaults = .standard) async throws -> String {
        guard let token, let accountID = APIClient.accountID(in: token) else { throw LoggingIntentError.signedOut }
        let sync = sync ?? .shared
        let container = container ?? SyncEngine.launchContainer
        let user = defaults.data(forKey: APIClient.accountCacheKey(token)).flatMap { try? JSONDecoder().decode(UserDTO.self, from: $0) }
        if !sync.isConfigured(for: accountID) {
            guard let container else { throw LoggingIntentError.unavailable }
            sync.configure(container: container, accountID: accountID, timeZone: user?.timezone)
        }
        let imperial = user?.unitSystem != "metric"
        var milliliters = WaterServing.glass.milliliters(imperial: imperial)
        if let amount {
            guard let typed = WaterDisplay.milliliters(amount, imperial: imperial) else {
                throw LoggingIntentError.invalid(imperial ? "Enter 0.1 to 169 fl oz." : "Enter a whole number from 1 to 5,000 ml.")
            }
            milliliters = typed
        }
        let today = sync.today
        let current = (try? await sync.diary(for: today, cachedOnly: true))?.water ?? WaterDayDTO(entry_date: today.rawValue, ml: 0, revision: 0)
        do { try sync.addWater(current, milliliters: milliliters) } catch { throw LoggingIntentError.invalid("Nothing was saved. Open Exerly and try again.") }
        let total = (try? await sync.diary(for: today, cachedOnly: true))?.waterMl ?? current.ml + milliliters
        let words = { (ml: Int) in WaterDisplay.amount(ml, imperial: imperial) }
        var text = "Logged \(words(milliliters)) of water. \(words(total)) today"
        if let goal = user?.waterGoalMl { text += total >= goal ? ", your goal reached." : ", \(words(goal - total)) to go." } else { text += "." }
        return text
    }

    // MARK: Helpers

    private static func suggested(_ account: IntentAccess.Account, now: Date) -> [FoodSuggestion] {
        account.store.suggestions(at: now, timeZone: account.timeZone, limit: 10).filter { $0.food.unweighed != true }
    }

    /// "1,820 kcal left today." against the target; nil without one.
    private static func left(_ store: NutritionStore, _ day: LocalDate) -> String? {
        let energy = store.progress(on: day).energy
        guard let remaining = energy.remaining, let over = energy.over else { return nil }
        return over >= 0.5 ? "\(FoodFormat.kcal(over)) kcal over today." : "\(FoodFormat.kcal(remaining)) kcal left today."
    }

    private static func sentences(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " ") }
}
