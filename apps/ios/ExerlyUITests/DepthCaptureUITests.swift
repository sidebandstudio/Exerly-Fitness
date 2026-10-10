import XCTest

/// Screens for amounts typed in search, choosing several foods on Today,
/// hiding a suggestion and duplicating a food. Steps a build doesn't have
/// are skipped, so the same walk captures before and after.
final class DepthCaptureUITests: ExerlyUITestCase {
    func testDepthCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else { throw XCTSkip("Opt-in visual review") }
        try await control([:])
        let person = try await createAccount(prefix: "depth-capture", units: "imperial")
        try await seedWeek(token: person.token)
        let bar = SeedFood(name: "Synthetic protein bar", per100g: ["energy": 380, "protein": 33, "carbohydrate": 40, "fat": 12])
        let payload: [String: Any] = ["id": bar.id, "name": bar.name, "source": "custom", "per100g": bar.per100g,
                                      "servings": [["name": "1 bar", "grams": 60.0]], "favorite": true, "createdAt": "2026-10-01T12:00:00.000Z"]
        _ = try await request("PUT", "/v1/documents/saved_food/\(bar.id)", body: ["base_revision": 0, "payload": payload], token: person.token)
        // Today's food goes in Lunch: the week's habit makes now Breakfast,
        // and Log again only shows while that meal is empty.
        let meal = "Lunch"
        let banana = SeedFood(name: "Synthetic banana", per100g: ["energy": 89, "protein": 1.1, "carbohydrate": 22.8, "fat": 0.3])
        let coffee = SeedFood(name: "Synthetic coffee", per100g: ["energy": 2, "protein": 0.1, "carbohydrate": 0, "fat": 0])
        for (food, grams) in [(bar, 60.0), (banana, 118), (coffee, 300)] {
            try await seedEntry(food, grams: grams, daysAgo: 0, meal: meal, minutes: 5, token: person.token)
        }
        let app = launch(resetSession: true)
        signIn(app, email: person.email)

        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log."))
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        _ = chips.firstMatch.waitForExistence(timeout: 20)
        capture(app, "01-today-log-again")
        if chips.firstMatch.exists {
            let name = String(chips.firstMatch.label.dropFirst("Log ".count).prefix { $0 != "," })
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "\(name),", "today.suggestion"))
                .firstMatch.press(forDuration: 1.0)
            capture(app, "02-chip-long-press")
            if app.buttons["Don't suggest this"].waitForExistence(timeout: 2) {
                app.buttons["Don't suggest this"].tap()
                capture(app, "03-chip-hidden")
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            }
        }

        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.entry.", "Synthetic banana"))
            .firstMatch
        reveal(entry, in: app)
        capture(app, "04-meals")
        if app.buttons["today.select"].exists {
            tap(app.buttons["today.select"], in: app)
            tap(entry, in: app)
            tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "nutrition.entry.", "Synthetic coffee"))
                .firstMatch, in: app)
            capture(app, "05-meals-selecting")
            tap(app.buttons["today.copySelected"], in: app)
            capture(app, "06-copy-destination")
            tap(app.buttons["today.confirmDestination"], in: app)
            capture(app, "07-copied")
        }

        app.swipeDown(); app.swipeDown()
        tap(app.buttons["nutrition.addFood"], in: app)
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        capture(app, "08-search-empty")
        for (step, query, id) in [("09-search-grams", "500 g ground beef", "usda:2705853"),
                                  ("10-search-can", "1 can kidney beans", "off:0041000000016"),
                                  ("11-search-count", "2 eggs", "usda:2707152")] {
            replace(app.searchFields.firstMatch, with: query, in: app)
            _ = app.buttons["nutrition.quickLog.\(id)"].waitForExistence(timeout: 10)
            try await Task.sleep(for: .seconds(1))
            capture(app, step)
        }
        tap(app.buttons["nutrition.closePicker"], in: app)

        openFoodLibrary(app)
        capture(app, "12-library")
        app.swipeUp()
        capture(app, "13-library-end")
        app.swipeDown()
        tap(app.buttons["nutrition.libraryFood.\(bar.id)"], in: app)
        tap(app.buttons["nutrition.libraryActions"], in: app)
        capture(app, "14-library-actions")
        if app.buttons["nutrition.libraryDuplicate"].exists {
            tap(app.buttons["nutrition.libraryDuplicate"], in: app)
            capture(app, "15-duplicate-editor")
        }
    }
}
