import XCTest

/// Finding and logging food, measured in taps from the home screen. Opening
/// food search counts as one tap: the search tab or the home screen's search
/// button. The simulator has no camera, so typing a barcode's digits stands
/// in for the scan and counts as one action.
@MainActor
final class FoodLoggingUITests: ExerlyUITestCase {
    private var capturing: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }

    func testFoodEatenBeforeLogsInTwoTapsAndCanBeUndone() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-repeat")
        let seeded = try await seedNutritionEntry(token: person.token, nutrients: ["energy": 57, "protein": 0.4, "carbohydrate": 15.2, "fat": 0.1],
                                                  grams: 150)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openSearch(app)
        let add = app.buttons["nutrition.quickLog.\(seeded.foodID)"]
        tap(add, in: app)
        let confirmation = app.descendants(matching: .any).matching(identifier: "nutrition.loggedConfirmation").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertEqual(tapCount, 2, "A food eaten before: open search, then its +")
        // The confirmation floats over the list, outside the shared helper's
        // scrolling area, so tap it where it is.
        let undo = app.buttons["nutrition.undoLog"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2) && undo.isHittable)
        undo.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Add food"].exists, "Logging with + keeps the search open for the next food")

        tap(add, in: app)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.label.contains("Synthetic pear"), confirmation.label)
        XCTAssertTrue(confirmation.label.contains("86 kcal"), "The row's last amount, 150 g, is what one tap logs: \(confirmation.label)")
        tap(app.buttons["nutrition.closePicker"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let pears = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.entry.", "Synthetic pear"))
        XCTAssertEqual(pears.count, 2, "The undone entry is gone and the second one stays")
    }

    /// The portion sheet has one day and time. Moving the day keeps the time
    /// eaten, and the button names the day it logs to.
    /// Run 6 tapped "About this food", half under the portion sheet's Log
    /// button on an SE, and logged the food. The content ends where the
    /// button's bar starts, so nothing under it can take a tap.
    func testNothingInThePortionSheetSitsUnderItsLogButton() async throws {
        let app = try await signedInWithWeek(prefix: "food-footer")
        openSearch(app)
        dismissKeyboard(app)
        let food = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.food.", "Roasted potatoes,"))
            .firstMatch
        tap(food, in: app)
        let save = app.buttons["nutrition.saveEntry"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        let viewport = try XCTUnwrap(scrollViewport(in: app))
        XCTAssertLessThanOrEqual(viewport.maxY, save.frame.minY, "The portion's content ends above its Log button")
        let about = app.buttons["About this food"]
        XCTAssertTrue(about.exists)
        // XCTest's own tap, as the tester's driver made it: it scrolls the row out first if it has to.
        about.tap()
        let opened = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Dates and times use")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "About this food opened")
        XCTAssertTrue(save.exists, "and nothing was logged")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nutrition.loggedConfirmation").firstMatch.exists)
        capture(app, "food-footer-about")
    }

    func testMovingTheDayKeepsTheTimeAndTheButtonNamesTheDay() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-day")
        let seeded = try await seedNutritionEntry(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openSearch(app)
        tap(app.buttons["nutrition.food.\(seeded.foodID)"], in: app)
        let save = app.buttons["nutrition.saveEntry"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.label.contains(" on "), "Today goes unsaid: \(save.label)")
        let eaten = app.datePickers["nutrition.eatenAt"]
        reveal(eaten, in: app)
        XCTAssertFalse(app.datePickers["nutrition.entryDate"].exists, "No separate diary date")
        // Its two halves: the day ("Oct 10, 2026") and the time ("6:28 PM").
        let clock = eaten.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch
        let calendarDay = eaten.buttons.matching(NSPredicate(format: "label CONTAINS ', 20'")).firstMatch
        let time = clock.label
        capture(app, "food-day-today")

        // Tomorrow, or yesterday at the end of a month, so it's in the calendar shown.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        let now = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let day = calendar.component(.month, from: tomorrow) == calendar.component(.month, from: now)
            ? tomorrow : calendar.date(byAdding: .day, value: -1, to: now)!
        var name = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day()
        name.timeZone = Self.newYork
        calendarDay.tap()
        let choice = app.buttons[day.formatted(name)]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertEqual(clock.label, time, "Same time of day, on the new day")
        var short = Date.FormatStyle(locale: Locale(identifier: "en_US")).month(.abbreviated).day().year()
        short.timeZone = Self.newYork
        XCTAssertEqual(calendarDay.label, day.formatted(short))
        XCTAssertTrue(save.label.hasSuffix(" on \(day.formatted(name))"), save.label)
        capture(app, "food-day-moved")
        tap(save, in: app)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = Self.newYork
        formatter.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var logged: [String: Any]?
        for _ in 0..<40 where logged == nil {
            logged = try await entries(token: person.token).first { $0["id"] as? String != seeded.id }
            if logged == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        let entry = try XCTUnwrap(logged, "The entry reached the server")
        XCTAssertEqual(entry["date"] as? String, formatter.string(from: day))
        let at = try XCTUnwrap((entry["loggedAt"] as? String).flatMap(iso.date(from:)))
        XCTAssertEqual(formatter.string(from: at), formatter.string(from: day), "Eaten on the day it counts for")
    }

    /// The account's food entries, from the change feed.
    private func entries(token: String) async throws -> [[String: Any]] {
        var latest: [String: [String: Any]?] = [:]
        var cursor = 0
        while true {
            let page = try await request("GET", "/v1/changes?after=\(cursor)&limit=1000", token: token)
            for change in page["changes"] as? [[String: Any]] ?? [] where change["kind"] as? String == "food_entry" {
                if let id = change["id"] as? String { latest[id] = change["payload"] as? [String: Any] }
            }
            cursor = page["cursor"] as? Int ?? cursor
            guard page["has_more"] as? Bool == true else { break }
        }
        return Array(latest.compactMapValues { $0 }.values)
    }

    /// An amount typed with the food is what one tap logs: the row says so
    /// before the tap, and the search clears for the next food.
    func testAnAmountTypedInTheSearchTabLogsInTwoTaps() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-typed")
        let yogurt = SeedFood(name: "Greek yogurt, plain", per100g: ["energy": 73, "protein": 10, "carbohydrate": 3.9, "fat": 1.9])
        let payload: [String: Any] = ["id": yogurt.id, "name": yogurt.name, "source": "custom", "per100g": yogurt.per100g,
                                      "servings": [["name": "1 cup", "grams": 227.0]], "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z"]
        _ = try await request("PUT", "/v1/documents/saved_food/\(yogurt.id)", body: ["base_revision": 0, "payload": payload], token: person.token)
        try await seedEntry(yogurt, grams: 170, daysAgo: 1, meal: "Breakfast", token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        tap(app.buttons["Log food"], in: app)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { tap(app.searchFields.firstMatch, in: app) }
        let fromTab = tapCount
        app.typeText("200 g greek yogurt")
        let add = app.buttons["nutrition.quickLog.\(yogurt.id)"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.label.hasPrefix("Log 200 g of Greek yogurt, plain"), "Not its usual 170 g: \(add.label)")
        let row = app.buttons["nutrition.food.\(yogurt.id)"]
        XCTAssertTrue(row.label.contains("200 g") && row.label.contains("146 kilocalories"), row.label)
        capture(app, "food-typed-amount")
        tap(add, in: app)
        let confirmation = app.descendants(matching: .any).matching(identifier: "nutrition.loggedConfirmation").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.label.contains("146 kcal"), confirmation.label)
        XCTAssertEqual(tapCount - fromTab + 1, 2, "From the search tab: the tab (with the keyboard up) or the field, then +")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String ?? "", "Search foods, or type 200 g chicken",
                       "The search clears for the next food, and says an amount can lead it")

        tap(app.buttons["Today"], in: app)
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.entry.", "Greek yogurt"))
            .firstMatch
        reveal(entry, in: app)
        XCTAssertEqual(entry.label, "Greek yogurt, plain, 200 g, 146 calories")
    }

    /// A custom food's Duplicate opens an editable copy; saving it keeps both.
    func testDuplicatingACustomFoodOpensAnEditableCopy() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-duplicate")
        let bar = SeedFood(name: "Synthetic protein bar", per100g: ["energy": 380, "protein": 33, "carbohydrate": 40, "fat": 12])
        let payload: [String: Any] = ["id": bar.id, "name": bar.name, "source": "custom", "per100g": bar.per100g,
                                      "servings": [["name": "1 bar", "grams": 60.0]], "favorite": true, "createdAt": "2026-10-01T12:00:00.000Z"]
        _ = try await request("PUT", "/v1/documents/saved_food/\(bar.id)", body: ["base_revision": 0, "payload": payload], token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openFoodLibrary(app)
        tap(app.buttons["nutrition.libraryFood.\(bar.id)"], in: app)
        tapCount = 0
        tap(app.buttons["nutrition.libraryActions"], in: app)
        tap(app.buttons["nutrition.libraryDuplicate"], in: app)
        let name = app.textFields["nutrition.foodName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Synthetic protein bar copy")
        XCTAssertEqual(app.textFields["nutrition.nutrient.energy"].value as? String, "380", "The label comes along")
        capture(app, "food-duplicate-editor")
        replace(name, with: "Synthetic protein bar, chocolate", in: app)
        tap(app.buttons["nutrition.saveFood"], in: app)
        XCTAssertEqual(tapCount, 4, "Actions, Duplicate food, the name to rename it, Save")
        XCTAssertTrue(app.navigationBars["Saved food"].waitForExistence(timeout: 5))
        tap(app.navigationBars.buttons.element(boundBy: 0), in: app)
        let foods = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.libraryFood."))
        XCTAssertTrue(foods.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(foods.count, 2, "The original and its copy")
        XCTAssertTrue(foods.allElementsBoundByIndex.contains { $0.label.contains("Synthetic protein bar, chocolate") })
    }

    /// Foods usually eaten at this hour are headed by the hour, or by "now"
    /// late at night, when an hour like 12 AM reads oddly.
    func testUsualFoodsAreHeadedByTheHourOrNowLateAtNight() async throws {
        let app = try await signedInWithWeek(prefix: "food-usual")
        openSearch(app)
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.group.suggested"].waitForExistence(timeout: 10))
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Usual around")).firstMatch
        XCTAssertTrue(header.exists)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        let hour = calendar.component(.hour, from: Date())
        if hour >= 22 || hour < 4 {
            XCTAssertEqual(header.label, "Usual around now")
        } else {
            XCTAssertNotEqual(header.label, "Usual around now")
        }
        capture(app, "food-usual-header")
    }

    func testBarcodeToLoggedInThreeTaps() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-barcode")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tapCount = 0
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        scanSyntheticBarcode("0012345678905", in: app)
        let log = app.buttons["nutrition.saveEntry"]
        XCTAssertTrue(log.waitForExistence(timeout: 10), "A matched barcode opens its portion directly")
        XCTAssertTrue(app.staticTexts["Synthetic oat bar"].exists)
        XCTAssertEqual(app.textFields["Number of servings"].value as? String, "1", "The default is one of the label's servings")
        if capturing { capture(app, "food-barcode-portion") }
        tap(log, in: app)
        XCTAssertEqual(tapCount, 3, "Scan button, scan, Log")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let bar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.entry.", "Synthetic oat bar"))
        XCTAssertEqual(bar.count, 1)

        // Through food search it is one more tap: search, Barcode, scan, Log.
        openSearch(app)
        tap(app.buttons["nutrition.barcode"], in: app)
        scanSyntheticBarcode("0012345678905", in: app)
        tap(app.buttons["nutrition.saveEntry"], in: app)
        XCTAssertEqual(tapCount, 4)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertEqual(bar.count, 2)
    }

    func testUnknownBarcodeOffersTheLabelAndManualEntry() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-barcode-missing")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["nutrition.scanBarcodeDirect"], in: app)
        scanSyntheticBarcode("0000000000000", in: app)
        XCTAssertTrue(app.staticTexts["nutrition.barcodeNotFound"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["nutrition.scanLabel"].exists)
        XCTAssertTrue(app.buttons["nutrition.barcodeManualFood"].exists)
        if capturing { capture(app, "food-barcode-not-found") }
        tap(app.buttons["nutrition.barcodeManualFood"], in: app)
        XCTAssertTrue(app.navigationBars["Food label"].waitForExistence(timeout: 5))
    }

    func testQuickCaloriesFromSearch() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "food-quick")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openSearch(app)
        tap(app.buttons["nutrition.quickAdd"], in: app)
        // Calories is ready to type the moment quick add opens.
        XCTAssertTrue(app.buttons["exerly.keypadDone"].waitForExistence(timeout: 5))
        let calories = app.textFields["nutrition.quick.energy"]
        calories.typeText("450")
        XCTAssertEqual(calories.value as? String, "450")
        if capturing { capture(app, "food-quick-add-typed") }
        tap(app.buttons["nutrition.quick.save"], in: app)
        XCTAssertEqual(tapCount, 3, "Open search, Quick add, Log; the Calories are typed")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.entry.", "Quick add"))
        XCTAssertEqual(entry.count, 1)
    }

    func testTypingSearchesTheDatabaseOnceAndSavedFoodsStayAvailableOffline() async throws {
        try await control(["resetFoodDatabaseRequests": true])
        let person = try await createAccount(prefix: "food-type-ahead")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openSearch(app)
        let field = app.searchFields.firstMatch
        tap(field, in: app)
        field.typeText("Synthetic oat")
        let add = app.buttons["nutrition.quickLog.off:0012345678905"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Results arrive while typing, without submitting")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Open Database License")).firstMatch.exists,
                      "Open Food Facts attribution stays with its results")
        if capturing { capture(app, "food-search-typing") }
        let requests = try await request("GET", "/__test/food-database-requests")
        let searches = try XCTUnwrap(requests["requests"] as? [[String: Any]]).filter { $0["type"] as? String == "search" }
        XCTAssertEqual(searches.count, 1, "A paused word costs one request, not one per keystroke: \(searches)")
        XCTAssertEqual(searches.first?["query"] as? String, "Synthetic oat")
        tap(add, in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nutrition.loggedConfirmation").firstMatch.waitForExistence(timeout: 5))

        try await control(["offline": true])
        replace(field, with: "oat b", in: app)
        let saved = app.buttons["nutrition.quickLog.off:0012345678905"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "Foods already logged are found offline")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nutrition.group.local").firstMatch.exists)
        XCTAssertTrue(saved.label.hasPrefix("Logged "), "The row keeps its check while search is open: \(saved.label)")
        // Its check takes the food back off, offline too.
        tap(saved, in: app)
        let checked = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "nutrition.quickLog.off:0012345678905", "Logged "))
        XCTAssertTrue(checked.firstMatch.waitForNonExistence(timeout: 5))
        tap(app.buttons["nutrition.closePicker"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "nutrition.entry.", "Synthetic oat bar")).firstMatch.exists)
        try await control([:])
    }

    func testFoodLoggingCapture() async throws {
        guard capturing else { throw XCTSkip("Opt-in visual review of food logging") }
        try await control(["resetFoodDatabaseRequests": true])
        let person = try await createAccount(prefix: "design-food", units: "imperial")
        try await seedFoodHistory(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["nutrition.addFood"], in: app)
        XCTAssertTrue(app.buttons["nutrition.quickLog.\(Self.yogurt)"].waitForExistence(timeout: 10))
        capture(app, "food-01-search-recent")
        tap(app.buttons["nutrition.quickLog.\(Self.yogurt)"], in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nutrition.loggedConfirmation").firstMatch.waitForExistence(timeout: 5))
        capture(app, "food-02-logged-undo")
        chooseList("Favorites", in: app)
        capture(app, "food-03-favorites")
        chooseList("My foods", in: app)
        capture(app, "food-04-my-foods")
        chooseList("Recent", in: app)
        tap(app.buttons["nutrition.food.\(Self.oats)"], in: app)
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 5))
        capture(app, "food-05-portion-sheet")
        tap(app.buttons["nutrition.measure.grams"], in: app)
        capture(app, "food-06-portion-grams")
        tap(app.buttons["nutrition.cancelEntry"], in: app)
        if app.buttons["Discard changes"].waitForExistence(timeout: 2) { tap(app.buttons["Discard changes"], in: app) }
        let field = app.searchFields.firstMatch
        tap(field, in: app)
        field.typeText("Synthetic oat")
        XCTAssertTrue(app.buttons["nutrition.quickLog.off:0012345678905"].waitForExistence(timeout: 10))
        capture(app, "food-07-search-results")
        tap(app.buttons["nutrition.barcode"], in: app)
        XCTAssertTrue(app.textFields["nutrition.barcodeDigits"].waitForExistence(timeout: 5))
        capture(app, "food-08-barcode")
        tap(app.navigationBars.buttons.element(boundBy: 0), in: app)
        tap(app.buttons["nutrition.quickAdd"], in: app)
        XCTAssertTrue(app.navigationBars["Quick add"].waitForExistence(timeout: 5))
        capture(app, "food-09-quick-add")
    }

    // MARK: Helpers

    /// Recent, Favorites or My foods: a segmented choice, or a menu at the
    /// largest text sizes.
    private func chooseList(_ title: String, in app: XCUIApplication) {
        if !app.buttons[title].exists { tap(app.buttons["nutrition.listScope"], in: app) }
        tap(app.buttons[title], in: app)
    }

    /// Opens food search from the home screen and counts it as one tap.
    private func openSearch(_ app: XCUIApplication) {
        tap(app.buttons["nutrition.addFood"], in: app)
        XCTAssertTrue(app.navigationBars["Add food"].waitForExistence(timeout: 10))
        tapCount = 1
    }

    /// Types the digits under a barcode, as the camera would read them, and
    /// counts the scan as one action.
    private func scanSyntheticBarcode(_ digits: String, in app: XCUIApplication) {
        let field = app.textFields["nutrition.barcodeDigits"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Without a camera the digits are ready to type")
        let before = tapCount
        replace(field, with: digits, in: app)
        tap(app.buttons["nutrition.lookupBarcode"], in: app)
        tapCount = before + 1
    }

    static let yogurt = "5E1F0000-0000-4000-8000-000000000001"
    static let oats = "5E1F0000-0000-4000-8000-000000000002"
    static let banana = "5E1F0000-0000-4000-8000-000000000003"
    static let coffee = "5E1F0000-0000-4000-8000-000000000004"
    static let chicken = "5E1F0000-0000-4000-8000-000000000005"
    static let almonds = "5E1F0000-0000-4000-8000-000000000006"

    /// Synthetic history: a breakfast eaten around this time on recent days,
    /// a dinner yesterday, and a favorite.
    private func seedFoodHistory(token: String) async throws {
        struct Seed { let id, name: String; let brand: String?; let source: String; let per100g: [String: Double]; let serving: (String, Double)?; let favorite: Bool }
        let foods = [
            Seed(id: Self.yogurt, name: "Greek yogurt, plain", brand: "Synthetic Dairy Co.", source: "custom",
                 per100g: ["energy": 97, "protein": 9, "carbohydrate": 3.9, "fat": 5], serving: ("1 cup", 227), favorite: false),
            Seed(id: Self.oats, name: "Rolled oats", brand: nil, source: "custom",
                 per100g: ["energy": 379, "protein": 13.2, "carbohydrate": 67.7, "fat": 6.5, "fiber": 10.1], serving: ("1/2 cup", 40), favorite: false),
            Seed(id: Self.banana, name: "Banana, raw", brand: nil, source: "usda",
                 per100g: ["energy": 89, "protein": 1.1, "carbohydrate": 22.8, "fat": 0.3], serving: ("1 medium", 118), favorite: true),
            Seed(id: Self.coffee, name: "Cold brew coffee", brand: "Synthetic Roasters", source: "custom",
                 per100g: ["energy": 2, "protein": 0.1, "carbohydrate": 0, "fat": 0], serving: ("1 bottle (325 ml)", 325), favorite: false),
            Seed(id: Self.chicken, name: "Chicken breast, grilled", brand: nil, source: "custom",
                 per100g: ["energy": 165, "protein": 31, "carbohydrate": 0, "fat": 3.6], serving: nil, favorite: true),
            Seed(id: Self.almonds, name: "Almonds", brand: "Synthetic Orchards", source: "custom",
                 per100g: ["energy": 579, "protein": 21.2, "carbohydrate": 21.6, "fat": 49.9], serving: ("1 oz (28 g)", 28), favorite: true)
        ]
        for food in foods {
            var payload: [String: Any] = ["id": food.id, "name": food.name, "source": food.source, "per100g": food.per100g,
                                          "servings": food.serving.map { [["name": $0.0, "grams": $0.1]] } ?? [],
                                          "favorite": food.favorite, "createdAt": "2026-10-01T12:00:00.000Z"]
            if let brand = food.brand { payload["brand"] = brand }
            _ = try await request("PUT", "/v1/documents/saved_food/\(food.id)", body: ["base_revision": 0, "payload": payload], token: token)
        }
        let newYork = TimeZone(identifier: "America/New_York")!
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = newYork
        day.dateFormat = "yyyy-MM-dd"
        let instant = ISO8601DateFormatter()
        instant.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func entry(_ food: Seed, daysAgo: Double, minutes: Double = 0, meal: String, grams: Double, quantity: Double?) async throws {
            let at = Date().addingTimeInterval(-daysAgo * 86_400 + minutes * 60)
            var snapshot: [String: Any] = ["foodID": food.id, "name": food.name, "source": food.source, "per100g": food.per100g]
            if let brand = food.brand { snapshot["brand"] = brand }
            var payload: [String: Any] = ["id": UUID().uuidString, "date": day.string(from: at), "meal": meal,
                                          "loggedAt": instant.string(from: at), "food": snapshot, "grams": grams]
            if let quantity, let serving = food.serving {
                payload["serving"] = ["name": serving.0, "grams": serving.1]
                payload["quantity"] = quantity
            }
            _ = try await request("PUT", "/v1/documents/food_entry/\(payload["id"]!)", body: ["base_revision": 0, "payload": payload], token: token)
        }
        for daysAgo in 1...4 {
            try await entry(foods[0], daysAgo: Double(daysAgo), meal: "Breakfast", grams: 227, quantity: 1)
            try await entry(foods[1], daysAgo: Double(daysAgo), minutes: 2, meal: "Breakfast", grams: 60, quantity: 1.5)
            try await entry(foods[3], daysAgo: Double(daysAgo), minutes: 5, meal: "Breakfast", grams: 325, quantity: 1)
        }
        try await entry(foods[2], daysAgo: 2, minutes: 4, meal: "Breakfast", grams: 118, quantity: 1)
        try await entry(foods[4], daysAgo: 1, minutes: 600, meal: "Dinner", grams: 170, quantity: nil)
        try await entry(foods[5], daysAgo: 1, minutes: 420, meal: "Snacks", grams: 28, quantity: 1)
    }
}
