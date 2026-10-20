import XCTest

/// The targets screen: the first plan, a new version, and the weekly
/// check-in with Accept and Undo, all on ExerlyCore's nutrition plans.
@MainActor
final class TargetsUITests: ExerlyUITestCase {
    private var designCapture: Bool { ProcessInfo.processInfo.environment["EXERLY_DESIGN_CAPTURE"] == "1" }

    // MARK: Regression

    /// With no plan, Today offers targets; setup starts from the profile's
    /// formula, and saving makes the first version.
    func testFirstPlanStartsFromTheProfileAndSaves() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "targets-setup", units: "metric")
        try await withoutLegacyTargets(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)

        tap(app.buttons["today.setTargets"], in: app)
        tap(app.buttons["targets.setup"], in: app)
        let preview = app.descendants(matching: .any)["planEditor.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        // Setup's answers: female, 34, 167.5 cm, 72.25 kg, lightly active, maintaining.
        // Mifflin–St Jeor: 10 × 72.25 + 6.25 × 167.5 − 5 × 34 − 161 = 1438 kcal × 1.375.
        XCTAssertTrue((preview.value as? String ?? "").hasPrefix("1,978 kilocalories a day"), preview.value as? String ?? "")
        tap(app.buttons["Lose"], in: app)
        // Round amounts a week: 0.75 kg is over 1 % of 72.25 kg, so two presets.
        XCTAssertEqual(app.buttons["planEditor.rate.0"].label, "0.25 kilograms a week")
        XCTAssertFalse(app.buttons["planEditor.rate.2"].exists)
        tap(app.buttons["planEditor.rate.1"], in: app)
        XCTAssertEqual(app.buttons["planEditor.rate.1"].label, "0.50 kilograms a week")
        tap(app.buttons["planEditor.save"], in: app)

        let energy = app.descendants(matching: .any)["targets.today.energy"]
        XCTAssertTrue(energy.waitForExistence(timeout: 10))
        // 1978 − 0.5 × 7700 / 7 = 1428 kcal.
        XCTAssertEqual(energy.value as? String, "1,428 kilocalories")
        let plans = try await waitForDocuments("nutrition_plan", token: person.token) { $0.contains { $0["mode"] as? String == "coached" } }
        let plan = try XCTUnwrap(plans.first { $0["mode"] as? String == "coached" })
        XCTAssertEqual(plan["startDate"] as? String, Self.day(0).date)
        XCTAssertEqual((plan["goal"] as? [String: Any])?["direction"] as? String, "lose")
        XCTAssertEqual((plan["goal"] as? [String: Any])?["weeklyRate"] as? Double, 0.0069204, "0.5 kg of 72.25 kg")
        XCTAssertEqual((plan["basis"] as? [String: Any])?["expenditure"] as? Double, 1978)
        XCTAssertEqual((plan["targets"] as? [[String: Any]])?.first?["energy"] as? Double, 1428)
    }

    /// Targets set up offline are saved on the device, survive a relaunch and
    /// reach the server once it's back.
    func testAPlanSavedOfflineSurvivesARelaunchAndSyncs() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "targets-offline", units: "metric")
        try await withoutLegacyTargets(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        try await control(["offline": true])
        openTargets(app)
        tap(app.buttons["targets.setup"], in: app)
        tap(app.buttons["planEditor.save"], in: app)
        let energy = app.descendants(matching: .any)["targets.today.energy"]
        XCTAssertTrue(energy.waitForExistence(timeout: 10))
        let saved = energy.value as? String
        XCTAssertEqual(saved, "1,978 kilocalories", "Maintaining at the formula's expenditure")

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        openTargets(app)
        XCTAssertTrue(energy.waitForExistence(timeout: 10))
        XCTAssertEqual(energy.value as? String, saved, "The plan is still on the device")

        try await control([:])
        app.terminate()
        app.launch()
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        let plans = try await waitForDocuments("nutrition_plan", token: person.token) { !$0.isEmpty }
        XCTAssertEqual((plans.first?["targets"] as? [[String: Any]])?.first?["energy"] as? Double, 1978)
    }

    /// Changing the plan adds a version from today and leaves the old one.
    func testEditingAPlanStartsANewVersionToday() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "targets-edit", units: "imperial")
        let old = try await seedPlan(token: person.token, startOffset: -30, mode: "manual")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openTargets(app)
        capture(app, "targets-manual-no-error")
        XCTAssertFalse(app.staticTexts["The ± is one standard deviation: about a 2 in 3 chance the true value is in the range."].exists,
                       "Manual targets show no ±, so nothing explains one")
        XCTAssertFalse(app.buttons["targets.editPlan"].exists, "One Edit, in the toolbar")

        XCTAssertEqual(app.staticTexts["targets.checkIn.title"].label, "Off for manual targets")
        tap(app.buttons["targets.checkIn.coach"], in: app)
        XCTAssertTrue(app.buttons["planEditor.mode.coached"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planEditor.mode.coached"].isSelected)
        tap(app.buttons["planEditor.rate.faster"], in: app)
        tap(app.buttons["planEditor.save"], in: app)
        XCTAssertTrue(app.staticTexts["targets.checkIn.title"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.staticTexts["targets.checkIn.title"].label, "Off for manual targets")

        let plans = try await waitForDocuments("nutrition_plan", token: person.token) { $0.count == 2 }
        let kept = try XCTUnwrap(plans.first { $0["id"] as? String == old })
        XCTAssertEqual(kept["mode"] as? String, "manual", "The old version is unchanged")
        let new = try XCTUnwrap(plans.first { $0["id"] as? String != old })
        XCTAssertEqual(new["mode"] as? String, "coached")
        XCTAssertEqual(new["startDate"] as? String, Self.day(0).date)
    }

    /// Goal weight on Targets works as on Progress: a goal the trend has
    /// passed says Goal reached, the editor offers Gain or Maintain in Save's
    /// place until the goal can be reached, and Add opens the field ready to type.
    func testAGoalWeightReachedOnTargetsIsReplacedFromAdd() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "targets-goal-weight", units: "imperial")
        try await deleteSetupWeight(token: person.token)
        // A loss toward 190 lb from a trend of 84 kg (185.2 lb).
        let old = try await seedPlan(token: person.token, startOffset: -14, goalWeight: 190)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openTargets(app)
        let eta = app.descendants(matching: .any)["targets.eta"]
        reveal(eta, in: app)
        XCTAssertTrue(eta.label.hasPrefix("Goal reached"), eta.label)
        capture(app, "targets-goal-reached")

        tap(app.buttons["targets.edit"], in: app)
        let gain = app.buttons["planEditor.redirect"]
        XCTAssertTrue(gain.waitForExistence(timeout: 5))
        XCTAssertEqual(gain.label, "Gain to 190 lb")
        XCTAssertTrue(app.buttons["planEditor.redirect.maintain"].exists)
        XCTAssertFalse(app.buttons["planEditor.save"].exists, "Gain or Maintain takes Save's place")
        capture(app, "targets-goal-redirect")
        tap(app.buttons["Remove goal weight"], in: app)
        let save = app.buttons["planEditor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5) && save.isEnabled)
        XCTAssertFalse(gain.exists)
        tap(save, in: app)

        let add = app.buttons["targets.addGoalWeight"]
        reveal(add, in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        tapCount = 0
        tap(add, in: app)
        let field = app.textFields["planEditor.goalWeight"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["planEditor.addGoalWeight"].exists, "No second Add (run 7 tapped it twice)")
        await fulfillment(of: [expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)], timeout: 5)
        capture(app, "targets-goal-add")
        field.typeText("175")
        let editorETA = app.descendants(matching: .any)["planEditor.eta"]
        XCTAssertTrue(editorETA.label.hasPrefix("Around"), editorETA.label)
        dismissKeyboard(app)
        tap(save, in: app)
        XCTAssertEqual(tapCount, 2, "Add and Save; the goal weight is typed")
        reveal(eta, in: app)
        XCTAssertTrue(eta.waitForExistence(timeout: 10))
        XCTAssertTrue(eta.label.hasPrefix("Around"), eta.label)
        capture(app, "targets-goal-set")

        let plans = try await waitForDocuments("nutrition_plan", token: person.token) { $0.count == 3 }
        let kept = try XCTUnwrap(plans.first { $0["id"] as? String == old })
        XCTAssertEqual(((kept["goal"] as? [String: Any])?["goalWeight"] as? [String: Any])?["value"] as? Double, 190)
        let goals = plans.compactMap { ($0["goal"] as? [String: Any])?["goalWeight"] as? [String: Any] }
        XCTAssertTrue(goals.contains { $0["value"] as? Double == 175 && $0["unit"] as? String == "lb" }, "\(goals)")
    }

    /// A due check-in shows its change and evidence; Accept starts the new
    /// targets and Undo brings the old ones back, on the device and the server.
    func testAWeeklyCheckInIsAcceptedAndUndone() async throws {
        let (app, person) = try await signedInWithCheckIn(prefix: "targets-checkin")
        openTargets(app)
        let accept = app.buttons["targets.checkIn.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 30), app.debugDescription)
        let before = try XCTUnwrap(todayEnergy(app))
        let change = app.descendants(matching: .any)["targets.checkIn.energy"]
        XCTAssertTrue((change.value as? String ?? "").hasPrefix("From \(Self.grouped(before)) to "), change.value as? String ?? "")
        XCTAssertTrue(app.staticTexts["targets.checkIn.falsifier"].label.contains(" lb a week"), "The falsifier is in pounds")

        tap(accept, in: app)
        XCTAssertTrue(app.buttons["targets.checkIn.undo"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["targets.checkIn.title"].label, "Targets updated")
        let after = try XCTUnwrap(todayEnergy(app))
        XCTAssertGreaterThan(after, before, "Eight weeks of logs measure more expenditure than the plan's guess")
        let accepted = try await waitForDocuments("proposal", token: person.token) { $0.contains { $0["status"] as? String == "accepted" } }
        XCTAssertEqual(accepted.first?["author"].flatMap { ($0 as? [String: Any])?["name"] as? String }, "Exerly check-in")
        _ = try await waitForDocuments("nutrition_plan", token: person.token) { $0.count == 2 }

        tap(app.buttons["targets.checkIn.undo"], in: app)
        XCTAssertTrue(app.staticTexts["Check-in undone"].waitForExistence(timeout: 5))
        XCTAssertEqual(todayEnergy(app), before)
        _ = try await waitForDocuments("proposal", token: person.token) { $0.contains { $0["status"] as? String == "undone" } }
        _ = try await waitForDocuments("nutrition_plan", token: person.token) { $0.count == 1 }
    }

    /// A collaborative plan's check-in can be changed before it's accepted,
    /// and is accepted as the check-in with the change.
    func testACollaborativeCheckInIsAdjustedBeforeAccepting() async throws {
        let (app, person) = try await signedInWithCheckIn(prefix: "targets-adjust", mode: "collaborative")
        openTargets(app)
        let adjust = app.buttons["targets.checkIn.adjust"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 30), app.debugDescription)
        tap(adjust, in: app)
        XCTAssertEqual(app.buttons["planEditor.save"].label, "Accept adjusted targets")
        XCTAssertFalse(app.buttons["planEditor.mode.coached"].exists, "The check-in keeps its coaching mode")
        tap(app.buttons["Low carb"], in: app)
        tap(app.buttons["planEditor.save"], in: app)
        XCTAssertTrue(app.buttons["targets.checkIn.undo"].waitForExistence(timeout: 5))
        let proposals = try await waitForDocuments("proposal", token: person.token) { $0.contains { $0["status"] as? String == "accepted" } }
        XCTAssertTrue((proposals.first?["title"] as? String ?? "").hasPrefix("New targets, adjusted: "))
        let plans = try await waitForDocuments("nutrition_plan", token: person.token) { $0.count == 2 }
        XCTAssertTrue(plans.contains { $0["diet"] as? String == "lowCarb" && $0["mode"] as? String == "collaborative" })
    }

    // MARK: Captures

    func testTargetsCapture() async throws {
        guard designCapture else { throw XCTSkip("Opt-in visual review of the targets screen") }
        let (app, _) = try await signedInWithCheckIn(prefix: "targets-capture", weights: [1.15, 1, 1, 1, 1, 1.1, 1.15],
                                                     goalWeight: 172)
        openTargets(app)
        XCTAssertTrue(app.buttons["targets.checkIn.accept"].waitForExistence(timeout: 30))
        capture(app, "targets-01-checkin-due")
        let screen = app.scrollViews["targets.screen"]
        screen.swipeUp()
        capture(app, "targets-02-checkin-evidence")
        screen.swipeUp()
        capture(app, "targets-03-week-goal")
        screen.swipeUp()
        capture(app, "targets-04-basis-plan")
        screen.swipeUp(); screen.swipeUp()
        capture(app, "targets-05-versions")
        screen.swipeDown(); screen.swipeDown(); screen.swipeDown(); screen.swipeDown(); screen.swipeDown()
        tap(app.buttons["targets.checkIn.accept"], in: app)
        XCTAssertTrue(app.buttons["targets.checkIn.undo"].waitForExistence(timeout: 5))
        capture(app, "targets-06-accepted")

        tap(app.buttons["targets.edit"], in: app)
        XCTAssertTrue(app.buttons["planEditor.save"].waitForExistence(timeout: 5))
        capture(app, "targets-07-editor-goal")
        let editor = app.scrollViews["planEditor.screen"]
        editor.swipeUp()
        capture(app, "targets-08-editor-coaching")
        editor.swipeUp()
        capture(app, "targets-09-editor-macros")
        editor.swipeUp(); editor.swipeUp()
        capture(app, "targets-10-editor-weekdays")
        editor.swipeDown(); editor.swipeDown(); editor.swipeDown()
        tap(app.buttons["planEditor.mode.manual"], in: app)
        editor.swipeUp()
        capture(app, "targets-11-editor-manual")
        tap(app.buttons["planEditor.cancel"], in: app)
    }

    func testTargetsSetupCapture() async throws {
        guard designCapture else { throw XCTSkip("Opt-in visual review of first-time targets") }
        try await control([:])
        let person = try await createAccount(prefix: "targets-setup-capture", units: "imperial")
        try await withoutLegacyTargets(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openTargets(app)
        XCTAssertTrue(app.buttons["targets.setup"].waitForExistence(timeout: 10))
        capture(app, "targets-20-setup")
        tap(app.buttons["targets.setup"], in: app)
        XCTAssertTrue(app.buttons["planEditor.save"].waitForExistence(timeout: 5))
        tap(app.buttons["Lose"], in: app)
        tap(app.buttons["planEditor.addGoalWeight"], in: app)
        capture(app, "targets-21-setup-editor")
    }

    // MARK: Helpers

    private func openTargets(_ app: XCUIApplication) {
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.targets"], in: app)
        XCTAssertTrue(app.scrollViews["targets.screen"].waitForExistence(timeout: 10))
    }

    private func todayEnergy(_ app: XCUIApplication) -> Double? {
        let element = app.descendants(matching: .any)["targets.today.energy"]
        reveal(element, in: app)
        return (element.value as? String).flatMap { Double($0.filter(\.isNumber)) }
    }

    private static func grouped(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    /// A check-in waiting for a decision shows on Today, outside the day's
    /// numbers, and opens in one tap; its numbers say what day they're as of.
    func testAWaitingCheckInShowsOnTodayAndOpensInOneTap() async throws {
        let (app, _) = try await signedInWithCheckIn(prefix: "targets-today")
        let banner = app.buttons["today.checkIn"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(banner.label.hasPrefix("Weekly check-in"), banner.label)
        tapCount = 0
        tap(banner, in: app)
        XCTAssertEqual(tapCount, 1)
        let accept = app.buttons["targets.checkIn.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "The check-in comes first in Targets")
        let dated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "As of ")).firstMatch
        XCTAssertTrue(dated.exists, "The expenditure says the day it's as of")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " in the week to ")).firstMatch.exists)
        capture(app, "today-checkin-open")
        tap(accept, in: app)
        XCTAssertTrue(app.buttons["targets.checkIn.undo"].waitForExistence(timeout: 5))
        tap(app.navigationBars.buttons["Today"], in: app)
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5), "Decided, it leaves Today")
    }

    /// An account with eight weeks of logs and weigh-ins, and a coached plan
    /// from two weeks ago whose check-in falls today, started from a guess
    /// of expenditure well under what the logs show.
    private func signedInWithCheckIn(prefix: String, mode: String = "coached", weights: [Double] = Array(repeating: 1, count: 7),
                                     goalWeight: Double? = nil) async throws -> (XCUIApplication, (email: String, token: String)) {
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "imperial")
        try await deleteSetupWeight(token: person.token)
        try await seedHistory(token: person.token)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        _ = try await seedPlan(token: person.token, startOffset: -14, mode: mode, checkInDay: calendar.component(.weekday, from: Date()),
                               weights: weights, goalWeight: goalWeight)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        return (app, person)
    }

    /// The server turns an account's setup targets into a plan the first time
    /// the app asks, unless the account has ever had one. A deleted plan
    /// leaves the account with none.
    private func withoutLegacyTargets(token: String) async throws {
        let id = try await seedPlan(token: token, startOffset: -1, mode: "manual")
        _ = try await request("DELETE", "/v1/documents/nutrition_plan/\(id)?base_revision=1", token: token)
    }

    /// A plan losing 0.5 % a week, its targets worked out as ExerlyCore does.
    @discardableResult
    private func seedPlan(token: String, startOffset: Int, mode: String = "coached", checkInDay: Int = 2,
                          weights: [Double] = Array(repeating: 1, count: 7), goalWeight: Double? = nil,
                          expenditure: Double = 2300, trend: Double = 84) async throws -> String {
        let id = UUID().uuidString
        let rate = 0.005
        let week = ((expenditure - rate * trend * 7700 / 7) * 7).rounded()
        let sum = weights.reduce(0, +)
        let protein = (1.8 * trend).rounded()
        let targets: [[String: Any]] = weights.map { weight in
            let energy = (week * weight / sum).rounded()
            let fat = max(0.3 * energy / 9, 0.6 * trend).rounded()
            return ["energy": energy, "protein": protein, "fat": fat, "carbohydrate": ((energy - protein * 4 - fat * 9) / 4).rounded(.down)]
        }
        var goal: [String: Any] = ["direction": "lose", "weeklyRate": rate]
        if let goalWeight { goal["goalWeight"] = ["value": goalWeight, "unit": "lb"] }
        var payload: [String: Any] = [
            "id": id, "startDate": Self.day(startOffset).date, "createdAt": Self.iso(Self.day(startOffset).at), "goal": goal,
            "mode": mode, "diet": "balanced", "protein": "moderate", "weekdayWeights": weights, "checkInDay": checkInDay,
            "allowBelowFloor": false, "targets": targets,
        ]
        if mode != "manual" { payload["basis"] = ["expenditure": expenditure, "expenditureError": 300, "trendWeight": trend] }
        _ = try await request("PUT", "/v1/documents/nutrition_plan/\(id)", body: ["base_revision": 0, "payload": payload], token: token)
        return id
    }
}
