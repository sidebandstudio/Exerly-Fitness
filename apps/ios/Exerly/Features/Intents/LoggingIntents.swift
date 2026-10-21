import AppIntents
import CoreSpotlight
import ExerlyCore
import Foundation

// Logging without opening Exerly. These run in the app's process, launched in
// the background if needed; see IntentAccess. The intents that open the app
// are in Shared, so the controls in the widget extension can use them.

/// One of the meals Today lists.
enum IntentMeal: String, AppEnum {
    case breakfast = "Breakfast", lunch = "Lunch", dinner = "Dinner", snacks = "Snacks"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"
    static let caseDisplayRepresentations: [IntentMeal: DisplayRepresentation] = [
        .breakfast: "Breakfast", .lunch: "Lunch", .dinner: "Dinner",
        .snacks: DisplayRepresentation(title: "Snacks", synonyms: ["Snack"]),
    ]
}

/// A food the person logs: usual at this time of day, recent, or saved.
/// Their own foods are in Spotlight too (see FoodSpotlight).
struct FoodEntity: IndexedEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Food"
    static let defaultQuery = FoodEntityQuery()

    let id: String
    let name: String
    /// What logging it records: "1 cup (80 g) · 300 kcal".
    let portion: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(portion)") }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = portion
        return attributes
    }

    init(_ portion: QuickPortion, unit: MassUnit) {
        id = portion.id
        name = portion.food.name
        self.portion = [portion.food.brand, FoodFormat.portion(portion, unit: unit), "\(FoodFormat.kcal(portion.nutrients.energy)) kcal"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct FoodEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FoodEntity] {
        try await IntentAccess().perform(changing: false) { account in
            identifiers.compactMap { LoggingActions.portion(of: $0, in: account).map { FoodEntity($0, unit: account.unit) } }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [FoodEntity] {
        try await IntentAccess().perform(changing: false) { account in
            LoggingActions.usualFoods(in: account).map { FoodEntity($0, unit: account.unit) }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [FoodEntity] {
        try await IntentAccess().perform(changing: false) { account in
            LoggingActions.foods(matching: string, in: account).map { FoodEntity($0, unit: account.unit) }
        }
    }
}

/// A food chosen in Spotlight that the Log a food shortcut doesn't offer,
/// such as a saved food or recipe never logged: its portion sheet on Today,
/// so the portion is checked before one tap logs it. (Spotlight shows usual
/// and recent foods as that shortcut, which logs the remembered portion.)
struct OpenFoodIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a food"
    static let description = IntentDescription("Opens one of your foods, ready to log with the portion you last had.")

    @Parameter(title: "Food") var target: FoodEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        ExerlyLinkHandler.open?(ExerlyLinks.food(target.id))
        return .result()
    }
}

/// Keeps the person's own foods in Spotlight: recently logged and saved
/// ones, recipes included, never the food database.
@MainActor
enum FoodSpotlight {
    /// Indexes the account's foods on every change until the calling task is
    /// cancelled. The first pass replaces whatever an earlier run left.
    static func follow(_ account: IntentAccess.Account) async {
        let index = CSSearchableIndex.default()
        var indexed: [FoodEntity]?
        for await foods in Observations({ @MainActor in LoggingActions.ownFoods(in: account).map { FoodEntity($0, unit: account.unit) } })
        where foods != indexed {
            if let indexed {
                let gone = Set(indexed.map(\.id)).subtracting(foods.map(\.id))
                if !gone.isEmpty { try? await index.deleteAppEntities(identifiedBy: Array(gone), ofType: FoodEntity.self) }
            } else { await clear() }
            try? await index.indexAppEntities(foods)
            indexed = foods
        }
    }

    /// At sign-out or account deletion.
    static func clear() async {
        try? await CSSearchableIndex.default().deleteAppEntities(ofType: FoodEntity.self)
    }
}

struct LogFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a food"
    static let description = IntentDescription("Logs one of your usual or recent foods with the portion you last had.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Food", requestValueDialog: "Which food?") var food: FoodEntity
    @Parameter(title: "Servings", description: "Leave empty for your usual portion.") var servings: Double?

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$food)") { \.$servings } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform { try LoggingActions.logFood(food.id, servings: servings, in: $0) }
        return .result(dialog: "\(text)")
    }
}

struct LogFoodNamedIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a food by name"
    static let description = IntentDescription("Logs the first of your recent or saved foods with this name, with the portion you last had.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Name", requestValueDialog: "Which food?") var name: String
    @Parameter(title: "Servings", description: "Leave empty for your usual portion.") var servings: Double?
    @Parameter(title: "Meal", description: "Leave empty for the meal you usually log at this time.") var meal: IntentMeal?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$name)") {
            \.$servings
            \.$meal
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform {
            try LoggingActions.logFood(named: name, servings: servings, meal: meal?.rawValue, in: $0)
        }
        return .result(dialog: "\(text)")
    }
}

struct LogBarcodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a barcode"
    static let description = IntentDescription("Logs one of your foods by the digits under its barcode, with the portion you last had.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Barcode", description: "The 8 to 14 digits under the barcode.", requestValueDialog: "What are the barcode's digits?")
    var digits: String
    @Parameter(title: "Servings", description: "Leave empty for your usual portion.") var servings: Double?
    @Parameter(title: "Meal", description: "Leave empty for the meal you usually log at this time.") var meal: IntentMeal?

    static var parameterSummary: some ParameterSummary {
        Summary("Log barcode \(\.$digits)") {
            \.$servings
            \.$meal
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform {
            try LoggingActions.logBarcode(digits, servings: servings, meal: meal?.rawValue, in: $0)
        }
        return .result(dialog: "\(text)")
    }
}

/// MacroFactor's "Log by JSON", so a shortcut written for it, or another
/// app's, logs to Exerly. The format is checked, and nothing is logged
/// unless all of it is valid.
struct LogJSONIntent: AppIntent {
    static let title: LocalizedStringResource = "Log by JSON"
    static let description = IntentDescription("""
        Logs a food another shortcut describes: name, source, nutrients, and a serving of one, per100Grams, per100ML, \
        {amount, unit} or {amount, label, weight}. Nothing is logged unless all of it is valid.
        """)
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "JSON", inputOptions: String.IntentInputOptions(capitalizationType: .none, multiline: true, autocorrect: false),
               requestValueDialog: "What's the food's JSON?")
    var json: String
    @Parameter(title: "Meal", description: "Leave empty for the meal you usually log at this time.") var meal: IntentMeal?

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$json) to \(\.$meal)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform { try LoggingActions.logJSON(json, meal: meal?.rawValue, in: $0) }
        return .result(dialog: "\(text)")
    }
}

/// Today in the Shortcuts JSON format, for another shortcut to read: what's
/// been eaten, and what remains of each goal's minimum, target and maximum.
struct TodaySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Today summary"
    static let description = IntentDescription("Gives today's food and what's left of each goal as JSON, and says your calories left.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let (json, text) = try await IntentAccess().perform(changing: false) {
            (try LoggingActions.todaySummary(in: $0), LoggingActions.caloriesLeft(in: $0))
        }
        return .result(value: json, dialog: "\(text)")
    }
}

struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick add"
    static let description = IntentDescription("Logs calories, and any macros you know, to a meal.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Calories", requestValueDialog: "How many calories?") var calories: Double
    @Parameter(title: "Protein (g)") var protein: Double?
    @Parameter(title: "Carbs (g)") var carbs: Double?
    @Parameter(title: "Fat (g)") var fat: Double?
    @Parameter(title: "Meal", description: "Leave empty for the meal you usually log at this time.") var meal: IntentMeal?

    static var parameterSummary: some ParameterSummary {
        Summary("Quick add \(\.$calories) kcal to \(\.$meal)") {
            \.$protein
            \.$carbs
            \.$fat
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform {
            try LoggingActions.quickAdd(calories: calories, protein: protein, carbs: carbs, fat: fat, meal: meal?.rawValue, in: $0)
        }
        return .result(dialog: "\(text)")
    }
}

struct RepeatMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Repeat a meal"
    static let description = IntentDescription("Logs the last time you had a meal this week again today.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Meal", description: "Leave empty for the meal you usually log at this time.") var meal: IntentMeal?

    static var parameterSummary: some ParameterSummary { Summary("Repeat \(\.$meal)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform { try LoggingActions.repeatMeal(meal?.rawValue, in: $0) }
        return .result(dialog: "\(text)")
    }
}

struct RepeatDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Repeat a day"
    static let description = IntentDescription("Logs the last day you logged food this week again today, if today is still empty.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform { try LoggingActions.repeatDay(in: $0) }
        return .result(dialog: "\(text)")
    }
}

struct LogWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "Log weight"
    static let description = IntentDescription("Logs a weigh-in in the units you use in Exerly.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Weight", description: "In the units you use in Exerly.", requestValueDialog: "What do you weigh?")
    var weight: Double

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$weight) as today's weight") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform { try LoggingActions.logWeight(weight, in: $0) }
        return .result(dialog: "\(text)")
    }
}

struct LogWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Log water"
    static let description = IntentDescription("Adds water to today: a glass, or the amount you give in the units you use in Exerly.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount", description: "In millilitres or fluid ounces, as you use in Exerly. Leave empty for a glass.")
    var amount: Double?

    static var parameterSummary: some ParameterSummary { Summary("Log water") { \.$amount } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await LoggingActions.logWater(amount)
        return .result(dialog: "\(text)")
    }
}

struct CaloriesLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Calories left"
    static let description = IntentDescription("Tells you what you've eaten today, what's left of your target, and your protein.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentAccess().perform(changing: false) { LoggingActions.caloriesLeft(in: $0) }
        return .result(dialog: "\(text)")
    }
}

struct ExerlyShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogFoodIntent(), phrases: [
            "Log \(\.$food) in \(.applicationName)",
            "Log a food in \(.applicationName)",
            "Log my usual food in \(.applicationName)",
        ], shortTitle: "Log a food", systemImageName: "fork.knife")
        AppShortcut(intent: QuickAddIntent(), phrases: [
            "Quick add in \(.applicationName)",
            "Quick add calories in \(.applicationName)",
            "Quick add to \(\.$meal) in \(.applicationName)",
        ], shortTitle: "Quick add", systemImageName: "bolt.fill")
        AppShortcut(intent: LogWeightIntent(), phrases: [
            "Log my weight in \(.applicationName)",
            "Record my weight in \(.applicationName)",
            "Log a weigh-in in \(.applicationName)",
        ], shortTitle: "Log weight", systemImageName: "scalemass.fill")
        AppShortcut(intent: LogWaterIntent(), phrases: [
            "Log water in \(.applicationName)",
            "Log a glass of water in \(.applicationName)",
            "Add water in \(.applicationName)",
        ], shortTitle: "Log water", systemImageName: "drop.fill")
        AppShortcut(intent: CaloriesLeftIntent(), phrases: [
            "How many calories do I have left in \(.applicationName)",
            "Calories left in \(.applicationName)",
            "How much can I still eat in \(.applicationName)",
        ], shortTitle: "Calories left", systemImageName: "flame.fill")
        AppShortcut(intent: RepeatMealIntent(), phrases: [
            "Repeat my \(\.$meal) in \(.applicationName)",
            "Repeat \(\.$meal) in \(.applicationName)",
            "Repeat my meal in \(.applicationName)",
        ], shortTitle: "Repeat a meal", systemImageName: "arrow.counterclockwise")
        AppShortcut(intent: StartWorkoutIntent(), phrases: [
            "Start my workout in \(.applicationName)",
            "Start today's workout in \(.applicationName)",
            "Start a workout in \(.applicationName)",
        ], shortTitle: "Start workout", systemImageName: "figure.strengthtraining.traditional")
        AppShortcut(intent: ScanBarcodeIntent(), phrases: [
            "Scan a barcode in \(.applicationName)",
            "Scan food in \(.applicationName)",
        ], shortTitle: "Scan barcode", systemImageName: "barcode.viewfinder")
        // Ten is the most an app can have. Weigh in and Search foods, which
        // only open screens, stay actions and controls without a phrase.
        AppShortcut(intent: LogNextSetIntent(), phrases: [
            "Log my set in \(.applicationName)",
            "Log the next set in \(.applicationName)",
            "Done with my set in \(.applicationName)",
        ], shortTitle: "Log the next set", systemImageName: "checkmark.circle.fill")
        AppShortcut(intent: RestIntent(), phrases: [
            "Rest in \(.applicationName)",
            "More rest in \(.applicationName)",
            "Start my rest in \(.applicationName)",
        ], shortTitle: "Rest", systemImageName: "timer")
    }
}
