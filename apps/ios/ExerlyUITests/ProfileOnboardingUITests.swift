import XCTest

/// Welcome, sign-in, sign-up, setup and the Profile hub.
final class ProfileOnboardingUITests: ExerlyUITestCase {
    func testProfileOnboardingCapture() async throws {
        guard ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" else {
            throw XCTSkip("Opt-in visual review of first run and Profile")
        }
        try await control([:])
        let app = launch(resetSession: true)
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 10))
        try await Task.sleep(for: .seconds(1.6))
        capture(app, "po-01-welcome")
        tap(app.buttons["I already have an account"], in: app)
        try await Task.sleep(for: .seconds(1))
        capture(app, "po-02-login")
        tap(app.buttons["Back"], in: app)
        tap(app.buttons["Get Started"], in: app)
        try await Task.sleep(for: .seconds(1))
        // Return moves to the next field, which scrolls above the keyboard.
        replace(app.textFields["Name"], with: "Riley Synthetic", in: app)
        app.textFields["Name"].typeText("\n")
        replace(app.textFields["Email"], with: "po-\(UUID().uuidString.prefix(8).lowercased())@exerly.test", in: app)
        app.textFields["Email"].typeText("\n")
        try await Task.sleep(for: .seconds(0.8))
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.frame.maxY < app.keyboards.firstMatch.frame.minY, "The next field scrolls above the keyboard")
        replace(password, with: "Simulator-Test-123!", in: app)
        dismissKeyboard(app)
        tap(app.buttons["I agree to the Terms of Service & Privacy Policy"], in: app)
        capture(app, "po-03-signup")
        tap(app.buttons["Create Account"], in: app)
        XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 15))
        settleAfterSignIn(app)
        replace(app.textFields["Height, feet"], with: "5", in: app)
        replace(app.textFields["Height, inches"], with: "10", in: app)
        replace(app.textFields["Weight, lb"], with: "182.4", in: app)
        try await Task.sleep(for: .seconds(0.8))
        capture(app, "po-04b-setup-typing")
        dismissKeyboard(app)
        tap(app.buttons["Male"], in: app)
        app.swipeDown()
        capture(app, "po-04-setup-about")
        tap(app.buttons["Continue"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lose Weight")).firstMatch, in: app)
        replace(app.textFields["Target weight"], with: "172", in: app)
        dismissKeyboard(app)
        app.swipeDown()
        capture(app, "po-05-setup-goal")
        tap(app.buttons["Continue"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lightly Active")).firstMatch, in: app)
        capture(app, "po-06-setup-activity")
        tap(app.buttons["setup.continueWeek"], in: app)
        tap(app.buttons["setup.workouts.4"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "I train regularly")).firstMatch, in: app)
        capture(app, "po-07-setup-training")
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "At home")).firstMatch, in: app)
        app.swipeUp()
        capture(app, "po-08-setup-training-home")
        tap(app.buttons["setup.continueWeek"], in: app)
        XCTAssertTrue(app.buttons["Finish setup"].waitForExistence(timeout: 15))
        capture(app, "po-09-setup-review")
        app.swipeUp()
        capture(app, "po-10-setup-review-bottom")
        tap(app.buttons["Finish setup"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        settleAfterSignIn(app)
        XCTAssertTrue(app.descendants(matching: .any)["weightCard.trend"].waitForExistence(timeout: 20))
        tap(app.buttons["Profile"], in: app)
        try await Task.sleep(for: .seconds(1))
        capture(app, "po-11-profile-top")
        app.swipeUp()
        capture(app, "po-12-profile-middle")
        app.swipeUp(); app.swipeUp()
        capture(app, "po-13-profile-bottom")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        tap(app.buttons["profile.preferences"], in: app)
        XCTAssertTrue(app.textFields["preferences.name"].waitForExistence(timeout: 15))
        capture(app, "po-14-preferences")
        tap(app.buttons["Done"].firstMatch, in: app)
        tap(app.buttons["profile.password"], in: app)
        capture(app, "po-15-change-password")
    }

    /// The weight typed during setup is the first ExerlyCore weigh-in: Today's
    /// trend card and Profile both show it.
    func testSetupWeightBecomesTheFirstWeighIn() async throws {
        try await control([:])
        let email = "setup-weight-\(UUID().uuidString.prefix(8).lowercased())@exerly.test"
        _ = try await request("POST", "/signup", body: ["email": email, "password": "Simulator-Test-123!", "name": "Weigh Taylor"])
        let app = launch(resetSession: true)
        tap(app.buttons["I already have an account"], in: app)
        replace(app.textFields["Email"], with: email, in: app)
        replace(app.secureTextFields["Password"], with: "Simulator-Test-123!", in: app)
        dismissKeyboard(app)
        tap(app.buttons["Log In"], in: app)
        XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["Your name"].value as? String, "Weigh Taylor", "Setup starts from the name given at sign-up")
        XCTAssertFalse(app.buttons["Previous setup step"].exists, "The first page has no back button")
        tap(app.buttons["Metric"], in: app)
        replace(app.textFields["Height, cm"], with: "172", in: app)
        dismissKeyboard(app)
        replace(app.textFields["Weight, kg"], with: "81.4", in: app)
        let weightField = app.textFields["Weight, kg"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists && weightField.frame.maxY < keyboard.frame.minY,
                      "The field being typed in stays above the keyboard")
        dismissKeyboard(app)
        tap(app.buttons["Continue"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["setup.error"].waitForExistence(timeout: 5),
                      "Continuing without the estimate's sex says what's missing")
        tap(app.buttons["Female"], in: app)
        tap(app.buttons["Continue"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maintain")).firstMatch, in: app)
        tap(app.buttons["Continue"], in: app)
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Moderately Active")).firstMatch, in: app)
        tap(app.buttons["setup.continueWeek"], in: app)
        tap(app.buttons["setup.workouts.3"], in: app)
        tap(app.buttons["setup.continueWeek"], in: app)
        XCTAssertTrue(app.buttons["Finish setup"].waitForExistence(timeout: 15))
        let calories = app.descendants(matching: .any)["setup.calories"]
        XCTAssertTrue(calories.exists, "The review shows the targets before finishing")
        let weighIn = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "First weigh-in")).firstMatch
        reveal(weighIn, in: app)
        XCTAssertTrue(weighIn.label.contains("81.4 kg"), weighIn.label)
        tap(app.buttons["Finish setup"], in: app)
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        settleAfterSignIn(app)
        let trend = app.descendants(matching: .any)["weightCard.trend"]
        reveal(trend, in: app)
        XCTAssertTrue(trend.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(trend.label.contains("81.4 kilograms"), trend.label)
        tap(app.buttons["Profile"], in: app)
        let stat = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Trend weight")).firstMatch
        XCTAssertTrue(stat.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((stat.value as? String ?? "").contains("81.4 kilograms"), stat.value as? String ?? "")
    }

    /// Profile groups what people do, opens each place, and switches units
    /// for the whole account.
    func testProfileHubOpensEachPlaceAndSwitchesUnits() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "profile-hub", units: "metric")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        tap(app.buttons["Profile"], in: app)
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Morgan"].exists)
        let weight = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "Trend weight", "Weight")).firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 10))
        XCTAssertTrue((weight.value as? String ?? "").contains("kilograms"), weight.value as? String ?? "")
        for identifier in ["profile.targets", "profile.foods", "profile.agents", "profile.reminders",
                           "profile.details", "profile.sync", "profile.account", "profile.logout"] {
            reveal(app.buttons[identifier], in: app)
            XCTAssertTrue(app.buttons[identifier].exists, identifier)
        }
        reveal(app.buttons["Apple Health"], in: app)
        XCTAssertTrue(app.buttons["Apple Health"].exists)

        revealAbove(app.buttons["profile.targets"], in: app)
        tap(app.buttons["profile.targets"], in: app)
        XCTAssertTrue(app.scrollViews["targets.screen"].waitForExistence(timeout: 10))
        tap(app.navigationBars.buttons["Profile"], in: app)

        let usUnits = app.descendants(matching: .any)["profile.units"].buttons["U.S."]
        tap(usUnits, in: app)
        await fulfillment(of: [expectation(for: NSPredicate(format: "value CONTAINS %@", "pounds"), evaluatedWith: weight)], timeout: 15)
        XCTAssertTrue(usUnits.isSelected)
        let saved = try await request("GET", "/api/preferences", token: person.token)
        XCTAssertEqual((saved["values"] as? [String: Any])?["unitSystem"] as? String, "imperial")
        tap(app.descendants(matching: .any)["profile.units"].buttons["Metric"], in: app)
        await fulfillment(of: [expectation(for: NSPredicate(format: "value CONTAINS %@", "kilograms"), evaluatedWith: weight)], timeout: 15)
    }

    func testSignInAndSignUpLinkToEachOther() throws {
        let app = launch(resetSession: true)
        tap(app.buttons["I already have an account"], in: app)
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5))
        tap(app.buttons["Show password"], in: app)
        XCTAssertTrue(app.textFields["Password"].waitForExistence(timeout: 2), "Show password reveals the text")
        tap(app.buttons["New to Exerly? Create an account"], in: app)
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create Account"].isEnabled, "Sign-up waits for every answer and the terms")
        tap(app.buttons["Already have an account? Log in"], in: app)
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        tap(app.buttons["Back"], in: app)
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 5))
    }
}
