import ExerlyCore
import UserNotifications
import XCTest
@testable import Exerly

/// What reminders' buttons do and say, and what Spotlight holds: the meal a
/// reminder's time names, typed weights, confirmations, and accounts that
/// can't log.
@MainActor
final class ReminderActionsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    private var today: LocalDate { LocalDate(Date(), in: zone) }
    private typealias Notice = ReminderActions.Notice

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// `hour`:`minute` in the account's time zone, `daysAgo` days before today.
    private func time(_ hour: Int, _ minute: Int = 0, daysAgo: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func snapshot(_ values: [String: Exerly.JSONValue]) -> PreferencesSnapshot {
        PreferencesSnapshot(schemaVersion: 1, accountID: "a", revision: 1, values: values,
                            user: UserDTO(id: "a", email: "reminders@exerly.test"))
    }

    /// A button's access to the signed-in account "reminders", whose screens are open.
    private func access(_ screens: TrainingWorkspace, unit: MassUnit = .kilograms) throws -> IntentAccess {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": screens.accountID, "sid": "session"])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).signature"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try JSONEncoder().encode(UserDTO(id: screens.accountID, email: "reminders@exerly.test", timezone: zone.identifier)),
                     forKey: APIClient.accountCacheKey(token))
        return IntentAccess(screens: screens, token: token, root: nil, widgets: nil, unit: unit, defaults: defaults)
    }

    private func reminder(_ kind: String, of accountID: String = "reminders") -> String {
        ReminderPlan.prefix(namespace: "test", accountID: accountID) + kind
    }

    private func setTargets(_ store: NutritionStore) throws {
        try store.savePlan(NutritionPlan(startDate: today, goal: NutritionGoal(.maintain), mode: .manual,
                                         targets: Array(repeating: DailyTargets(energy: 2300, protein: 160, fat: 70, carbohydrate: 250), count: 7)),
                           timeZone: zone)
    }

    // MARK: Reminders

    func testMealRemindersAreNamedForTheirTimeAndTheWeighInAsksForTheUnit() throws {
        var values: [String: Exerly.JSONValue] = [
            "timezone": .string(zone.identifier), "unitSystem": .string("imperial"), "workoutDays": .array([.string("monday")]),
            "reminders": .object(["meals": .bool(true), "workouts": .bool(true), "weighIn": .bool(true)]),
            "reminderTimes": .object(["meals": .array(["07:30", "11:00", "15:30", "19:00"].map(Exerly.JSONValue.string)),
                                      "workout": .string("17:30"), "weighIn": .string("06:45")]),
        ]
        let plan = try ReminderPlan.make(snapshot(values), namespace: "test")
        let meals = plan.reminders.filter { $0.id.contains(".meal.") }
        XCTAssertEqual(meals.map(\.title), ["Breakfast", "Lunch", "Snacks", "Dinner"], "By the clock without the account's data")
        XCTAssertEqual(meals.map(\.category), ["Breakfast", "Lunch", "Snacks", "Dinner"].map(ReminderActions.mealCategory))
        XCTAssertEqual(meals[0].info, ["meal": "Breakfast", "time": "07:30"])
        XCTAssertEqual(plan.reminders.first { $0.id.hasSuffix(".workout.2") }?.category, ReminderActions.workoutCategory)
        let weighIn = try XCTUnwrap(plan.reminders.first { $0.id.hasSuffix(".weighIn") })
        XCTAssertEqual([weighIn.title, weighIn.body, weighIn.category],
                       ["Weigh-in", "Press and hold to type today's weight in lb.", ReminderActions.weighInCategory])
        XCTAssertEqual([weighIn.components.hour, weighIn.components.minute], [6, 45])
        XCTAssertTrue(plan.reminders.allSatisfy { $0.id.hasPrefix(ReminderPlan.prefix(namespace: "test", accountID: "a")) })
        let words = ["Apple", "iPhone", "iPad", "Watch", "Siri", "Health", "Shortcuts", "Spotlight"]
        let texts = plan.reminders.flatMap { [$0.title, $0.body] } + ReminderActions.categories.flatMap { $0.actions.map(\.title) }
        XCTAssertFalse(texts.contains { text in words.contains { text.contains($0) } }, "\(texts)")

        // A habit wins over the clock, as on Today: breakfast around 11 on three days.
        let workspace = try TrainingWorkspace(accountID: "a", root: temporaryRoot())
        let eggs = ExerlyCore.Food(name: "Synthetic eggs", per100g: NutrientAmounts([.energy: 155]))
        for day in 1...3 {
            try workspace.nutrition.log(eggs, grams: 100, on: today.adding(days: -day), meal: "Breakfast", at: time(11, 10, daysAgo: day))
        }
        XCTAssertEqual(try ReminderPlan.make(snapshot(values), namespace: "test", meals: workspace.nutrition).reminders
            .filter { $0.id.contains(".meal.") }.map(\.title), ["Breakfast", "Breakfast", "Snacks", "Dinner"])

        values["reminderTimes"] = .object([:])
        values["reminders"] = .object(["weighIn": .bool(true)])
        let missing = try ReminderPlan.make(snapshot(values), namespace: "test")
        XCTAssertEqual(missing.missing, ["Choose a weigh-in reminder time."])
        XCTAssertTrue(missing.reminders.isEmpty)
    }

    /// Reminders' screen lists what iOS holds in words, by time of day, in the
    /// person's locale; workout days share one line.
    func testScheduledRemindersReadAsPlainWords() throws {
        let values: [String: Exerly.JSONValue] = [
            "timezone": .string(zone.identifier), "unitSystem": .string("imperial"),
            "workoutDays": .array(["friday", "monday", "wednesday"].map(Exerly.JSONValue.string)),
            "reminders": .object(["meals": .bool(true), "workouts": .bool(true), "sleep": .bool(true), "weighIn": .bool(true)]),
            "reminderTimes": .object(["meals": .array(["12:30"].map(Exerly.JSONValue.string)), "workout": .string("18:00"),
                                      "sleep": .string("22:15"), "weighIn": .string("07:30")]),
        ]
        let plan = try ReminderPlan.make(snapshot(values), namespace: "test")
        let us = Locale(identifier: "en_US"), space = "\u{202F}"
        XCTAssertEqual(ReminderWords.lines(plan.reminders, locale: us), [
            "Weigh-in · every day at 7:30\(space)AM", "Lunch · every day at 12:30\(space)PM",
            "Workout · Mon, Wed, and Fri at 6:00\(space)PM", "Sleep · every day at 10:15\(space)PM",
        ])
        XCTAssertEqual(ReminderWords.lines(plan.reminders, locale: Locale(identifier: "en_GB")).last, "Sleep · every day at 22:15")
        XCTAssertEqual(ReminderWords.lines([]), [])
    }

    /// Pickers show a saved "HH:mm" as a time of day and save it back unchanged.
    func testReminderTimesRoundTripThroughThePicker() throws {
        for text in ["00:00", "07:30", "12:05", "23:59"] {
            XCTAssertEqual(ReminderClock.text(try XCTUnwrap(ReminderClock.date(text))), text)
        }
        XCTAssertNil(ReminderClock.date("7:30"))
        XCTAssertNil(ReminderClock.date("24:00"))
        XCTAssertEqual(ReminderClock.display(hour: 19, minute: 5, locale: Locale(identifier: "en_US")), "7:05\u{202F}PM")
    }

    func testEachButtonAsksForItsAction() throws {
        let categories = Dictionary(uniqueKeysWithValues: ReminderActions.categories.map { ($0.identifier, $0) })
        XCTAssertEqual(categories["exerly.meal.Breakfast"]?.actions.map(\.title), ["Log usual breakfast", "Repeat yesterday's breakfast", "Search"])
        XCTAssertEqual(categories["exerly.meal.Snacks"]?.actions.map(\.title), ["Log usual snack", "Repeat yesterday's snacks", "Search"])
        XCTAssertEqual(categories["exerly.workout"]?.actions.map(\.title), ["Start workout"])
        let weight = try XCTUnwrap(categories["exerly.weighIn"]?.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual([weight.title, weight.textInputButtonTitle], ["Log weight", "Log"])
        for action in categories.values.flatMap(\.actions) {
            XCTAssertEqual(action.options, ["search", "startWorkout"].contains(action.identifier) ? .foreground : .authenticationRequired,
                           "Logging asks for an unlocked phone; \(action.identifier)")
        }

        let meal = ["meal": "Breakfast", "time": "07:30"], breakfast = ReminderActions.mealCategory("Breakfast")
        func action(_ id: String, _ category: String, _ info: [String: String], text: String? = nil) -> ReminderActions.Action? {
            ReminderActions.action(id, category: category, info: info, text: text)
        }
        XCTAssertEqual(action("logUsual", breakfast, meal), .logUsual(meal: "Breakfast", time: "07:30"))
        XCTAssertEqual(action("repeat", breakfast, meal), .repeatMeal("Breakfast"))
        XCTAssertEqual(action("search", breakfast, meal), .open(ExerlyLinks.search))
        XCTAssertEqual(action("startWorkout", ReminderActions.workoutCategory, [:]), .open(ExerlyLinks.startWorkout))
        XCTAssertEqual(action("logWeight", ReminderActions.weighInCategory, [:], text: "182.4"), .logWeight("182.4"))
        XCTAssertEqual(action(UNNotificationDefaultActionIdentifier, ReminderActions.weighInCategory, [:]), .open(ExerlyLinks.weighIn),
                       "Tapping a weigh-in reminder opens a weigh-in")
        XCTAssertNil(action(UNNotificationDefaultActionIdentifier, breakfast, meal), "Tapping a meal reminder just opens the app")
        XCTAssertNil(action(UNNotificationDismissActionIdentifier, breakfast, meal))
        XCTAssertNil(action("logUsual", breakfast, [:]), "Without its meal, nothing is logged")
        XCTAssertEqual(ReminderActions.today(at: "07:30", now: time(9), timeZone: zone), time(7, 30))
        XCTAssertEqual(ReminderActions.today(at: "", now: time(9), timeZone: zone), time(9))
    }

    func testATypedWeightIsReadInThePersonsUnit() throws {
        XCTAssertEqual(try ReminderActions.weight("182.4", unit: .pounds), 182.4)
        XCTAssertEqual(try ReminderActions.weight(" 182.4 lb\n", unit: .pounds), 182.4)
        XCTAssertEqual(try ReminderActions.weight("182 LBS", unit: .pounds), 182)
        XCTAssertEqual(try ReminderActions.weight("82,5", unit: .kilograms), 82.5, "Either decimal mark")
        XCTAssertEqual(try ReminderActions.weight("82.5kg", unit: .kilograms), 82.5)
        for text in ["", "heavy", "82 kg", "1,234.5", "nan", "inf"] {
            XCTAssertThrowsError(try ReminderActions.weight(text, unit: .pounds), text) { error in
                XCTAssertEqual(error as? LoggingIntentError, .invalid("Enter a number."), text)
            }
        }
    }

    // MARK: Logging

    func testLogUsualLogsTodaysFirstSuggestionForTheRemindersTimeIntoItsMeal() async throws {
        let screens = try TrainingWorkspace(accountID: "reminders", root: temporaryRoot())
        let store = screens.nutrition
        try setTargets(store)
        let yogurt = ExerlyCore.Food(name: "Synthetic yogurt", per100g: NutrientAmounts([.energy: 73]))
        let toast = ExerlyCore.Food(name: "Synthetic toast", per100g: NutrientAmounts([.energy: 265]))
        for day in 1...3 { try store.log(yogurt, grams: 170, on: today.adding(days: -day), meal: "Breakfast", at: time(7, 45, daysAgo: day)) }
        try store.log(toast, grams: 60, on: today.adding(days: -1), meal: "Snacks", at: time(8, daysAgo: 1))
        let access = try access(screens)
        func logUsual() async -> Notice? {
            await ReminderActions.perform(.logUsual(meal: "Breakfast", time: "07:30"), reminder: reminder("meal.07:30"),
                                          access: access, namespace: "test", now: time(9, 30))
        }

        var notice = await logUsual()
        let entry = try XCTUnwrap(store.entries(on: today).first)
        XCTAssertEqual(notice, Notice(body: "Logged Synthetic yogurt, \(NutritionFormat.portion(entry, unit: .kilograms)), to Breakfast. 2,176 kcal left today."))
        XCTAssertEqual([entry.food.name, entry.meal], ["Synthetic yogurt", "Breakfast"])
        // Then the next chip, as on Today once one is used; the meal is the reminder's.
        notice = await logUsual()
        XCTAssertEqual(Set(store.entries(on: today).map(\.food.name)), ["Synthetic yogurt", "Synthetic toast"])
        XCTAssertEqual(Set(store.entries(on: today).map(\.meal)), ["Breakfast"])
        XCTAssertEqual(notice?.title, "")
        notice = await logUsual()
        XCTAssertEqual(notice, Notice(title: "Nothing was logged", body: "There's no usual breakfast to log. Search for it in Exerly."))
        XCTAssertEqual(store.entries(on: today).count, 2)
    }

    func testRepeatCopiesOnlyYesterdaysMeal() async throws {
        let screens = try TrainingWorkspace(accountID: "reminders", root: temporaryRoot())
        let store = screens.nutrition, access = try access(screens)
        let salmon = ExerlyCore.Food(name: "Synthetic salmon", per100g: NutrientAmounts([.energy: 208]))
        try store.log(salmon, grams: 200, on: today.adding(days: -3), meal: "Dinner")
        func repeatDinner() async -> Notice? {
            await ReminderActions.perform(.repeatMeal("Dinner"), reminder: reminder("meal.19:00"), access: access, namespace: "test", now: time(19))
        }
        var notice = await repeatDinner()
        XCTAssertEqual(notice, Notice(body: "There's no dinner from yesterday to repeat."), "The button promises yesterday's")
        XCTAssertTrue(store.entries(on: today).isEmpty)

        try store.log(salmon, grams: 150, on: today.adding(days: -1), meal: "Dinner")
        notice = await repeatDinner()
        XCTAssertEqual(notice, Notice(body: "Repeated yesterday's dinner: 1 food, 312 kcal."))
        XCTAssertEqual(store.entries(on: today).map(\.grams), [150])
        notice = await repeatDinner()
        XCTAssertEqual(notice, Notice(body: "Dinner already has food today, so nothing was repeated."))
    }

    func testAWeightTypedInTheReminderIsLoggedInTheirUnitOrSaysWhyNot() async throws {
        let screens = try TrainingWorkspace(accountID: "reminders", root: temporaryRoot())
        let access = try access(screens, unit: .pounds)
        func logWeight(_ text: String) async -> Notice? {
            await ReminderActions.perform(.logWeight(text), reminder: reminder("weighIn"), access: access, namespace: "test", now: time(7))
        }
        var notice = await logWeight("181,4")
        XCTAssertEqual(notice, Notice(body: "Logged 181.4 lb."))
        XCTAssertEqual(screens.nutrition.weights.map(\.weight), [.lb(181.4)])
        notice = await logWeight("heavy")
        XCTAssertEqual(notice, Notice(title: "Nothing was logged", body: "Enter a number."))
        notice = await logWeight("1000")
        XCTAssertEqual(notice?.title, "Nothing was logged")
        XCTAssertTrue(notice?.body.hasPrefix("Enter a weight from ") == true, "As the weigh-in sheet says: \(notice?.body ?? "")")
        XCTAssertEqual(screens.nutrition.weights.count, 1)
    }

    func testSignedOutOrAnotherAccountsReminderLogsNothing() async throws {
        let root = temporaryRoot()
        let nobody = IntentAccess(screens: nil, token: nil, root: root, widgets: nil)
        for action in [ReminderActions.Action.logUsual(meal: "Lunch", time: "12:00"), .repeatMeal("Lunch"), .logWeight("80")] {
            let notice = await ReminderActions.perform(action, reminder: reminder("meal.12:00"), access: nobody, namespace: "test")
            XCTAssertEqual(notice, Notice(title: "Nothing was logged", body: "Open Exerly and sign in first."), "\(action)")
        }

        let screens = try TrainingWorkspace(accountID: "reminders", root: root)
        let access = try access(screens)
        let notice = await ReminderActions.perform(.logWeight("80"), reminder: reminder("weighIn", of: "someone-else"),
                                                   access: access, namespace: "test")
        XCTAssertEqual(notice, Notice(title: "Nothing was logged", body: "That reminder was for another account. Open Exerly to log."))
        XCTAssertTrue(screens.nutrition.weights.isEmpty)
    }

    func testOpeningButtonsHandTheAppTheirLink() async throws {
        ExerlyLinkRouter.install()
        defer {
            ExerlyLinkHandler.open = nil
            ExerlyLinkRouter.shared.pending = nil
        }
        let nobody = IntentAccess(screens: nil, token: nil, root: temporaryRoot(), widgets: nil)
        for link in [ExerlyLinks.startWorkout, ExerlyLinks.search, ExerlyLinks.weighIn] {
            let notice = await ReminderActions.perform(.open(link), reminder: "exerly.reminder.any", access: nobody)
            XCTAssertNil(notice)
            XCTAssertEqual(ExerlyLinkRouter.shared.pending, link)
        }
    }

    // MARK: Spotlight

    func testSpotlightHoldsTheirOwnFoodsAndRecipesAndOpensOnesPortion() async throws {
        let workspace = try TrainingWorkspace(accountID: "reminders", root: temporaryRoot())
        let store = workspace.nutrition
        let account = IntentAccess.Account(workspace: workspace, unit: .kilograms, timeZone: zone)
        let oats = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]), servings: [Serving("cup", grams: 80)])
        let archived = ExerlyCore.Food(name: "Synthetic old cereal", per100g: NutrientAmounts([.energy: 370]))
        let bowl = ExerlyCore.Food.recipe(name: "Synthetic oat bowl", ingredients: [RecipeIngredient(food: oats.snapshot, grams: 80)],
                                          servingCount: 2)
        for food in [oats, archived, bowl] { try store.saveFood(food) }
        try store.archiveFood(archived.id)
        // Logged from the food database, never saved: recent, so theirs.
        let pear = ExerlyCore.Food(name: "Synthetic pear", source: .usda, per100g: NutrientAmounts([.energy: 57]))
        try store.log(pear, grams: 180, on: today, meal: "Snacks")

        let foods = LoggingActions.ownFoods(in: account)
        XCTAssertEqual(foods.first?.food.name, "Synthetic pear", "Recent first")
        XCTAssertEqual(Set(foods.map(\.food.name)), ["Synthetic pear", "Synthetic oats", "Synthetic oat bowl"], "Archived foods leave Spotlight")
        XCTAssertEqual(foods.first { $0.id == oats.id }?.serving?.name, "cup", "With the portion choosing it starts from")
        let entity = FoodEntity(try XCTUnwrap(foods.first { $0.id == bowl.id }), unit: .kilograms)
        XCTAssertEqual(entity.attributeSet.title, "Synthetic oat bowl")
        XCTAssertEqual(entity.attributeSet.contentDescription, entity.portion)

        ExerlyLinkRouter.install()
        defer {
            ExerlyLinkHandler.open = nil
            ExerlyLinkRouter.shared.pending = nil
        }
        var open = OpenFoodIntent()
        open.target = entity
        _ = try await open.perform()
        XCTAssertEqual(ExerlyLinkRouter.shared.pending, ExerlyLinks.food(bowl.id))
        XCTAssertEqual(ExerlyLinks.foodID(in: ExerlyLinks.food("a b&c/d")), "a b&c/d")
        XCTAssertNil(ExerlyLinks.foodID(in: ExerlyLinks.search))
    }

    // MARK: Preferences

    func testADraftSavedBeforeTheWeighInReminderExistedStillOpens() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let base = snapshot(["timezone": .string(zone.identifier)])
        var fields = PreferenceFields.fields(base)
        fields["name"] = "Draft name"
        fields["reminders.weighIn"] = nil
        fields["reminderTimes.weighIn"] = nil
        let draft = PreferencesDraft(version: 1, accountID: "a", base: base, fields: fields, heightCM: nil, pending: nil)
        defaults.set(try JSONEncoder().encode(draft), forKey: "preferences.draft.v1.\(APIClient.shared.storageNamespace).a")
        let store = PreferencesStore(accountID: "a", storage: DefaultsPreferencesStorage(defaults: defaults), ownerIsActive: { true })
        XCTAssertTrue(store.isReadable, store.error ?? "")
        XCTAssertEqual(store.draft?.fields["name"], "Draft name")
        XCTAssertEqual(store.draft?.fields["reminders.weighIn"], "false", "A new field starts as saved")
        XCTAssertEqual(try PreferenceFields.changes(try XCTUnwrap(store.draft)).keys.sorted(), ["name"])
    }
}
