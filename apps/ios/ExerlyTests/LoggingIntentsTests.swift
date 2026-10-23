import ExerlyCore
import XCTest
@testable import Exerly

/// What the logging intents record and say, and how they reach the signed-in
/// account's data with or without its screens open.
@MainActor
final class LoggingIntentsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    private var today: LocalDate { LocalDate(Date(), in: zone) }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func account(_ unit: MassUnit = .pounds) throws -> IntentAccess.Account {
        IntentAccess.Account(workspace: try TrainingWorkspace(accountID: "intents", root: temporaryRoot()), unit: unit, timeZone: zone)
    }

    /// `hour` o'clock in the account's time zone, `daysAgo` days before today.
    private func time(_ hour: Int, daysAgo: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func setTargets(_ account: IntentAccess.Account) throws {
        try account.store.savePlan(NutritionPlan(startDate: today, goal: NutritionGoal(.maintain), mode: .manual,
                                                 targets: Array(repeating: DailyTargets(energy: 2300, protein: 160, fat: 70, carbohydrate: 250), count: 7)),
                                   timeZone: zone)
    }

    /// Runs a logging action and returns what it said and the entry it added.
    private func logged(_ store: NutritionStore, _ action: () throws -> String) throws -> (text: String, entry: FoodEntry) {
        let before = Set(store.entries.map(\.id))
        let text = try action()
        return (text, try XCTUnwrap(store.entries.first { !before.contains($0.id) }))
    }

    private func invalid(_ error: Error) -> String? {
        if case .invalid(let message) = error as? LoggingIntentError { return message }
        return nil
    }

    // MARK: Weight

    func testLogWeightSavesTheReadingInTheSavedUnitThenTheTrend() throws {
        let account = try account(.pounds)
        XCTAssertEqual(try LoggingActions.logWeight(182.456, in: account, now: time(7, daysAgo: 8)), "Logged 182.46 lb.",
                       "A first reading has no trend to report yet")
        for day in (1...7).reversed() {
            try account.store.logWeight(.lb(182 - Double(8 - day) * 0.2), at: time(7, daysAgo: day), timeZone: zone)
        }
        let text = try LoggingActions.logWeight(180.4, in: account, now: time(7))
        XCTAssertTrue(text.hasPrefix("Logged 180.4 lb. Trend "), text)
        XCTAssertTrue(text.hasSuffix(" pounds this week."), text)
        XCTAssertTrue(text.contains(", down "), "The week's change, in words: \(text)")
        let saved = try XCTUnwrap(account.store.weights.last)
        XCTAssertEqual(saved.weight, .lb(180.4))
        XCTAssertEqual(saved.date, today)
        XCTAssertEqual(saved.at, time(7))

        let metric = try self.account(.kilograms)
        XCTAssertEqual(try LoggingActions.logWeight(81.8, in: metric, now: time(7)), "Logged 81.8 kg.")
        XCTAssertEqual(metric.store.weights.last?.weight, .kg(81.8), "The number is read in the person's unit")
        XCTAssertThrowsError(try LoggingActions.logWeight(5, in: metric, now: time(7))) { error in
            XCTAssertEqual(self.invalid(error), "Enter a weight from 20 to 400 kg.")
        }
        XCTAssertEqual(metric.store.weights.count, 1)
    }

    // MARK: Food

    func testQuickAddLogsToTheMealGivenOrTheOneUsuallyLoggedNow() throws {
        let account = try account()
        try setTargets(account)
        XCTAssertEqual(try LoggingActions.quickAdd(calories: 450, protein: 30, carbs: nil, fat: 12, meal: nil, in: account, now: time(8)),
                       "Logged 450 kcal to Breakfast. 1,850 kcal left today.")
        let entry = try XCTUnwrap(account.store.entries.first)
        XCTAssertEqual(entry.date, today)
        XCTAssertEqual(entry.meal, "Breakfast", "By the clock, without a habit")
        XCTAssertEqual(entry.food.name, "Quick add")
        XCTAssertEqual(entry.food.unweighed, true)
        XCTAssertEqual(entry.nutrients[.protein], 30)
        XCTAssertNil(entry.nutrients[.carbohydrate], "A macro left out isn't counted as zero")

        XCTAssertEqual(try LoggingActions.quickAdd(calories: 2000, protein: nil, carbs: nil, fat: nil, meal: "Dinner", in: account, now: time(8)),
                       "Logged 2,000 kcal to Dinner. 150 kcal over today.")
        XCTAssertThrowsError(try LoggingActions.quickAdd(calories: -5, protein: nil, carbs: nil, fat: nil, meal: nil, in: account, now: time(8)))
        XCTAssertEqual(account.store.entries.count, 2)

        // A habit wins over the clock, as on Today.
        let tea = ExerlyCore.Food(name: "Synthetic tea", per100g: NutrientAmounts([.energy: 1]))
        for day in 1...3 { try account.store.log(tea, grams: 250, on: today.adding(days: -day), meal: "Snacks", at: time(8, daysAgo: day)) }
        XCTAssertEqual(try LoggingActions.quickAdd(calories: 90, protein: nil, carbs: nil, fat: nil, meal: nil, in: account, now: time(8)),
                       "Logged 90 kcal to Snacks. 240 kcal over today.")
    }

    func testLogFoodUsesTheRememberedPortionAndCountsServings() throws {
        let account = try account()
        let store = account.store
        let oats = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380, .protein: 13]),
                                   servings: [Serving("cup", grams: 80)])
        try store.saveFood(oats)
        // A cup at breakfast two days ago, then a cup and a half logged late for yesterday.
        try store.log(oats, serving: oats.servings[0], quantity: 1, on: today.adding(days: -2), meal: "Breakfast", at: time(8, daysAgo: 2))
        try store.log(oats, serving: oats.servings[0], quantity: 1.5, on: today.adding(days: -1), meal: "Breakfast")
        let rice = ExerlyCore.Food(name: "Synthetic rice", per100g: NutrientAmounts([.energy: 130]))
        try store.log(rice, grams: 150, on: today.adding(days: -1), meal: "Lunch")

        XCTAssertEqual(LoggingActions.usualFoods(in: account, now: time(8)).map(\.food.name), ["Synthetic oats", "Synthetic rice"],
                       "Usual at this time first, then recent")
        XCTAssertEqual(LoggingActions.foods(matching: " OAT", in: account).map(\.id), [oats.id])
        XCTAssertEqual(LoggingActions.foods(matching: "rice", in: account).map(\.id), [rice.id])
        XCTAssertTrue(LoggingActions.foods(matching: "pear", in: account).isEmpty)
        XCTAssertEqual(LoggingActions.portion(of: oats.id, in: account, now: time(8))?.quantity, 1, "As Today's chip suggests it at breakfast")
        XCTAssertEqual(LoggingActions.portion(of: oats.id, in: account, now: time(15))?.quantity, 1.5, "Otherwise as last logged")
        let shown = FoodEntity(try XCTUnwrap(LoggingActions.portion(of: oats.id, in: account, now: time(15))), unit: .pounds)
        XCTAssertEqual(shown.name, "Synthetic oats")
        XCTAssertTrue(shown.portion.hasSuffix(" · 456 kcal"), shown.portion)

        var (text, entry) = try logged(store) { try LoggingActions.logFood(oats.id, servings: nil, in: account, now: time(8)) }
        XCTAssertEqual(text, "Logged Synthetic oats, \(NutritionFormat.portion(entry, unit: .pounds)), to Breakfast.")
        XCTAssertEqual([entry.serving?.name, entry.quantity.map { "\($0)" }, "\(entry.grams)"], ["cup", "1.0", "80.0"])
        XCTAssertEqual(entry.date, today)

        entry = try logged(store) { try LoggingActions.logFood(oats.id, servings: 2, in: account, now: time(15)) }.entry
        XCTAssertEqual([entry.quantity, entry.grams], [2, 160], "Servings count the food's serving")
        (text, entry) = try logged(store) { try LoggingActions.logFood(rice.id, servings: 2, in: account, now: time(13)) }
        XCTAssertEqual(entry.grams, 300, "Without a serving, multiples of the usual amount")
        XCTAssertNil(entry.serving)
        XCTAssertTrue(text.hasSuffix(", to Lunch."), text)

        let count = store.entries.count
        XCTAssertThrowsError(try LoggingActions.logFood(oats.id, servings: 0, in: account, now: time(8))) { error in
            XCTAssertEqual(self.invalid(error), "Enter more than 0 servings.")
        }
        XCTAssertThrowsError(try LoggingActions.logFood("missing", servings: nil, in: account, now: time(8)))
        XCTAssertEqual(store.entries.count, count)
    }

    func testRepeatMealCopiesItsLastTimeOnlyIntoAnEmptyMeal() throws {
        let account = try account()
        let store = account.store
        try setTargets(account)
        let salmon = ExerlyCore.Food(name: "Synthetic salmon", per100g: NutrientAmounts([.energy: 208]))
        let rice = ExerlyCore.Food(name: "Synthetic rice", per100g: NutrientAmounts([.energy: 130]))
        try store.log(salmon, grams: 200, on: today.adding(days: -1), meal: "Dinner")
        try store.log(rice, grams: 150, on: today.adding(days: -1), meal: "Dinner")

        XCTAssertEqual(try LoggingActions.repeatMeal("Dinner", in: account, now: time(19)),
                       "Repeated yesterday's dinner: 2 foods, 611 kcal. 1,689 kcal left today.")
        XCTAssertEqual(store.entries(on: today).map(\.food.name).sorted(), ["Synthetic rice", "Synthetic salmon"])
        XCTAssertEqual(try LoggingActions.repeatMeal("Dinner", in: account, now: time(19)),
                       "Dinner already has food today, so nothing was repeated.")
        XCTAssertEqual(store.entries(on: today).count, 2, "A second run doesn't log the meal twice")
        XCTAssertEqual(try LoggingActions.repeatMeal("Lunch", in: account, now: time(19)), "There's no lunch in the last week to repeat.")

        // Without a meal, the one for this time; an older day is named.
        try store.log(rice, grams: 100, on: today.adding(days: -3), meal: "Breakfast")
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = zone
        let weekday = NutritionFormat.pickerDate(today.adding(days: -3), timeZone: zone).formatted(style)
        XCTAssertEqual(try LoggingActions.repeatMeal(nil, in: account, now: time(8)),
                       "Repeated \(weekday)'s breakfast: 1 food, 130 kcal. 1,559 kcal left today.")
    }

    func testCaloriesLeftAgainstTheTargetOrSaysThereIsNone() throws {
        let account = try account()
        XCTAssertEqual(LoggingActions.caloriesLeft(in: account, now: time(12)),
                       "You've eaten 0 kcal today. You have no calorie target set. Protein 0 g.")
        let oats = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380, .protein: 13]))
        try account.store.log(oats, grams: 100, on: today, meal: "Breakfast")
        XCTAssertEqual(LoggingActions.caloriesLeft(in: account, now: time(12)),
                       "You've eaten 380 kcal today. You have no calorie target set. Protein 13 g.")
        try setTargets(account)
        XCTAssertEqual(LoggingActions.caloriesLeft(in: account, now: time(12)),
                       "You've eaten 380 kcal and have 1,920 left of 2,300. Protein 13 of 160 g.")
        try account.store.quickAdd(NutrientAmounts([.energy: 2000]), on: today, meal: "Lunch")
        XCTAssertEqual(LoggingActions.caloriesLeft(in: account, now: time(12)),
                       "You've eaten 2,380 kcal, 80 over your target of 2,300. Protein 13 of 160 g.")
        XCTAssertEqual(LoggingActions.caloriesLeft(in: account, now: time(12, daysAgo: -1)),
                       "You've eaten 0 kcal and have 2,300 left of 2,300. Protein 0 of 160 g.", "Each day counts on its own")
    }

    func testLogFoodByNameOrBarcodeFindsOnlyTheirOwnFoods() throws {
        let account = try account()
        let store = account.store
        let bar = ExerlyCore.Food(name: "Synthetic protein bar", per100g: NutrientAmounts([.energy: 400]),
                                  servings: [Serving("bar", grams: 60)], barcode: "036000291452")
        try store.saveFood(bar)
        try store.log(bar, serving: bar.servings[0], quantity: 1, on: today.adding(days: -1), meal: "Snacks")

        var (text, entry) = try logged(store) { try LoggingActions.logFood(named: "protein BAR", servings: nil, meal: nil, in: account, now: time(15)) }
        XCTAssertEqual(entry.food.foodID, bar.id)
        XCTAssertEqual(entry.quantity, 1)
        XCTAssertTrue(text.hasPrefix("Logged Synthetic protein bar, "), text)
        (text, entry) = try logged(store) { try LoggingActions.logBarcode("0036000291452", servings: 2, meal: "Lunch", in: account, now: time(15)) }
        XCTAssertEqual(entry.food.foodID, bar.id, "Leading zeros don't matter")
        XCTAssertEqual(entry.meal, "Lunch")
        XCTAssertEqual(entry.grams, 120)

        let count = store.entries.count
        XCTAssertThrowsError(try LoggingActions.logFood(named: "pizza", servings: nil, meal: nil, in: account)) { error in
            XCTAssertEqual(self.invalid(error), "None of your foods is called pizza. Search for it in Exerly.")
        }
        XCTAssertThrowsError(try LoggingActions.logBarcode("4006381333931", servings: nil, meal: nil, in: account)) { error in
            XCTAssertEqual(self.invalid(error), "That barcode isn't one of your foods yet. Scan it once in Exerly, and after that this logs it.")
        }
        XCTAssertThrowsError(try LoggingActions.logBarcode("12ab", servings: nil, meal: nil, in: account)) { error in
            XCTAssertEqual(self.invalid(error), "Enter the 8 to 14 digits under the barcode.")
        }
        XCTAssertEqual(store.entries.count, count, "Nothing else was logged")
    }

    /// PARITY I17: a usual food chosen in Spotlight logs in one tap; a saved
    /// food never logged opens its portion sheet.
    func testAFoodChosenInSpotlightLogsIfUsualElseOpensItsPortion() throws {
        let account = try account()
        let store = account.store
        let oats = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]))
        let soup = ExerlyCore.Food(name: "Synthetic soup", per100g: NutrientAmounts([.energy: 60]), servings: [Serving("bowl", grams: 300)])
        try store.saveFood(oats)
        try store.saveFood(soup)
        try store.log(oats, grams: 80, on: today.adding(days: -1), meal: "Breakfast")

        let before = Set(store.entries.map(\.id))
        let link = try LoggingActions.open(oats.id, in: account, now: time(8))
        let entry = try XCTUnwrap(store.entries.first { !before.contains($0.id) })
        XCTAssertEqual(entry.grams, 80)
        XCTAssertEqual(entry.date, today)
        // Today opens on its confirmation, whose Undo takes back this entry, for this account only.
        let toast = try XCTUnwrap(TodayView.confirmation(for: link, in: account.workspace))
        XCTAssertEqual(toast.message, "Logged Synthetic oats to Breakfast")
        XCTAssertEqual(toast.undo, .remove([entry]))
        XCTAssertNil(TodayView.confirmation(for: ExerlyLinks.logged(entry.id, accountID: "someone-else"), in: account.workspace),
                     "Another account's link says nothing here")
        XCTAssertNil(TodayView.confirmation(for: ExerlyLinks.logged(UUID(), accountID: "intents"), in: account.workspace),
                     "Nor one for an entry that's gone")
        let count = store.entries.count
        XCTAssertEqual(try LoggingActions.open(soup.id, in: account, now: time(8)), ExerlyLinks.food(soup.id))
        XCTAssertEqual(store.entries.count, count, "Its portion is checked first")
    }

    func testRepeatDayCopiesTheLastDayWithFoodOnlyIntoAnEmptyDay() throws {
        let account = try account()
        let store = account.store
        let oats = ExerlyCore.Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380]))
        let rice = ExerlyCore.Food(name: "Synthetic rice", per100g: NutrientAmounts([.energy: 130]))
        try store.log(oats, grams: 100, on: today.adding(days: -2), meal: "Breakfast")
        try store.log(rice, grams: 200, on: today.adding(days: -2), meal: "Dinner")
        try store.log(rice, grams: 100, on: today.adding(days: -9), meal: "Lunch")

        let text = try LoggingActions.repeatDay(in: account, now: time(9))
        XCTAssertTrue(text.hasSuffix("'s food: 2 foods, 640 kcal."), text)
        XCTAssertEqual(Set(store.entries(on: today).map(\.meal)), ["Breakfast", "Dinner"], "Each food into its own meal")
        XCTAssertEqual(try LoggingActions.repeatDay(in: account, now: time(10)), "Today already has food, so nothing was repeated.")
        XCTAssertEqual(store.entries(on: today).count, 2)

        let empty = try self.account()
        XCTAssertEqual(try LoggingActions.repeatDay(in: empty), "There's no day with food in the last week to repeat.")
    }

    func testLogByJSONLogsOnlyValidFoodsAndTheSummaryIsTheirDayAsJSON() throws {
        let account = try account()
        try setTargets(account)
        let store = account.store
        let shake = #"{ "name": "Synthetic shake", "source": "synthetic-app", "nutrients": { "energy": 240, "protein": 48 }, "serving": "one" }"#
        let (text, entry) = try logged(store) { try LoggingActions.logJSON(shake, meal: nil, in: account, now: time(16)) }
        XCTAssertEqual(text, "Logged Synthetic shake, 240 kcal, to Snacks. 2,060 kcal left today.")
        XCTAssertEqual(entry.nutrients[.protein], 48)

        for (bad, reason) in [("{ name: ", "Nothing was logged: that isn't JSON."),
                              (#"{ "name": "X", "nutrients": {}, "serving": "one" }"#,
                               "Nothing was logged: source is required, so entries can be traced to the shortcut.")] {
            XCTAssertThrowsError(try LoggingActions.logJSON(bad, meal: "Lunch", in: account, now: time(16))) { error in
                XCTAssertEqual(self.invalid(error), reason)
            }
        }
        XCTAssertEqual(store.entries.count, 1)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(LoggingActions.todaySummary(in: account, now: time(17)).utf8))
            as? [String: [String: Any]])
        XCTAssertEqual(json["consumed"]?["energy"] as? Double, 240)
        XCTAssertEqual(json["remaining"]?["protein"] as? [String: Double], ["target": 112])
    }

    // MARK: Opening the app

    func testOpenTheAppIntentsHandTheAppTheirLink() async throws {
        ExerlyLinkRouter.install()
        defer {
            ExerlyLinkHandler.open = nil
            ExerlyLinkRouter.shared.pending = nil
        }
        _ = try await SearchFoodsIntent().perform()
        XCTAssertEqual(ExerlyLinkRouter.shared.pending, ExerlyLinks.search)
        _ = try await ScanBarcodeIntent().perform()
        XCTAssertEqual(ExerlyLinkRouter.shared.pending, ExerlyLinks.scan)
        _ = try await WeighInIntent().perform()
        XCTAssertEqual(ExerlyLinkRouter.shared.pending, ExerlyLinks.weighIn)
        _ = try await StartWorkoutIntent().perform()
        XCTAssertEqual(ExerlyLinkRouter.shared.pending, ExerlyLinks.startWorkout)
    }

    // MARK: Access

    /// A token shaped like the server's, naming its account.
    private func token(for accountID: String) throws -> String {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": accountID, "sid": "session"])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).signature"
    }

    func testIntentsNeedASignInAndUseTheScreensWorkspaceOrOpenTheAccountsOwn() async throws {
        let root = temporaryRoot()
        let token = try token(for: "intent-account")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try JSONEncoder().encode(UserDTO(id: "intent-account", email: "intents@exerly.test", timezone: "Asia/Tokyo")),
                     forKey: APIClient.accountCacheKey(token))

        for signedOut in [IntentAccess(screens: nil, token: nil, root: root, widgets: nil),
                          IntentAccess(screens: nil, token: "not-a-session", root: root, widgets: nil)] {
            do {
                _ = try await signedOut.perform { _ in "" }
                XCTFail("Ran without a signed-in account")
            } catch { XCTAssertEqual(error as? LoggingIntentError, .signedOut) }
        }
        XCTAssertEqual(String(localized: LoggingIntentError.signedOut.localizedStringResource), "Open Exerly and sign in first.")

        // Launched for the intent: the account's own workspace, in its time zone, closed afterwards.
        let background = IntentAccess(screens: nil, token: token, root: root, widgets: nil, unit: .kilograms, defaults: defaults)
        let text = try await background.perform { account in
            XCTAssertEqual(account.timeZone.identifier, "Asia/Tokyo", "The account's time zone, not the device's")
            XCTAssertEqual(account.unit, .kilograms)
            return try LoggingActions.quickAdd(calories: 300, protein: nil, carbs: nil, fat: nil, meal: "Lunch", in: account)
        }
        XCTAssertEqual(text, "Logged 300 kcal to Lunch.")
        let screens = try TrainingWorkspace(accountID: "intent-account", root: root)
        XCTAssertEqual(screens.nutrition.entries.map(\.meal), ["Lunch"], "Saved before the workspace closed")

        // With the account's screens open, the change goes through their workspace.
        let open = IntentAccess(screens: screens, token: token, root: root, widgets: nil, defaults: defaults)
        try await open.perform { account in
            XCTAssertTrue(account.workspace === screens)
            try account.store.quickAdd(NutrientAmounts([.energy: 120]), on: LocalDate(Date(), in: account.timeZone), meal: "Snacks")
        }
        XCTAssertEqual(screens.nutrition.entries.count, 2, "The screens see it at once")
        do {
            _ = try await open.perform { try LoggingActions.logWeight(-1, in: $0) }
            XCTFail("Logged an impossible weight")
        } catch { XCTAssertTrue(invalid(error)?.hasPrefix("Enter a weight from") == true, "\(error)") }

        // Another account's screens are never used.
        let other = try TrainingWorkspace(accountID: "someone-else", root: root)
        try await IntentAccess(screens: other, token: token, root: root, widgets: nil, defaults: defaults).perform { account in
            XCTAssertFalse(account.workspace === other)
            XCTAssertEqual(account.workspace.accountID, "intent-account")
        }
    }
}
