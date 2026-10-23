import XCTest

/// Cold launch to logging (PARITY B03), for docs/TAP_BUDGETS.md. A signed-in
/// person with a week of food relaunches the app from terminated, each launch
/// paired with one of a signed-in account with no food, in the same run.
/// Timed end to end: from the process starting (the kernel's clock, so
/// loading the app's code counts) to the commit of the first frame that lays
/// out Today's logging controls, once the main run loop is free again (the
/// render server shows it at the next refresh), which the app reports to the
/// fixture with where it laid them out (LaunchTiming). For the week, that
/// place must hold Log again's chip in the accessibility tree, and the chip,
/// one tap from a logged food, must be hittable as the launch returns.
/// Simulator figures, not a phone's: the local full suite runs it, CI's
/// shared runners don't.
@MainActor
final class LaunchToLoggingUITests: ExerlyUITestCase {
    /// The gate is the median, over the pairs, of the week's launch over the
    /// empty account's. Both launch the same app on the same machine
    /// seconds apart, and the order alternates, so the machine's load and its
    /// drift cancel out, and what's left is what a week of food adds to a
    /// launch. A slowdown of every launch alike passes the ratio, so the
    /// week's own p50 has a ceiling too (`weekCeiling`). Eight runs of 20 pairs on 2026-10-23, on
    /// an iPhone 17 Pro Max simulator (Debug, M1 Max, load averages 20 to
    /// 142), had medians of 1.002 to 1.032; the ceiling leaves a week of food
    /// about 0.17 s more than that (docs/TAP_BUDGETS.md). PARITY B03's target
    /// is under 1 s on a phone.
    static let ratioCeiling = 1.10
    static let pairs = 20

    // Changing anything below takes a deliberate commit, with the new
    // measurements in docs/TAP_BUDGETS.md and PARITY B03: these are what the
    // absolute ceiling was set against, not values to tune until a run passes.

    /// The week's p50 ceiling in seconds, process start to Today's first frame
    /// with Log again, so a slowdown of every launch alike fails too: about
    /// 0.8 s over the week's p50 when it was set, room for a busy machine.
    static let weekCeiling = 3.25
    /// The empty account's and the week's p50 when the ceiling was set: the
    /// medians of the eight runs above.
    static let setAgainst = (empty: 2.357, week: 2.428)
    /// The simulator those were measured on. Elsewhere the ratio still gates,
    /// but the seconds only report: another device's times aren't comparable.
    static let configuration = (model: "iPhone18,2", name: "iPhone 17 Pro Max", os: "26.2", build: "Debug", host: "M1 Max")

    private struct Launch {
        let process: Double, app: Double, wallClock: Double
        let placed: Bool, hittable: Bool
        /// Where the chip was as the launch returned, and where the app reported it.
        let place: String
    }

    func testColdLaunchToLoggingStaysUnderItsCeiling() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "launch", units: "imperial")
        try await seedWeek(token: person.token)
        let nobody = try await createAccount(prefix: "launch-empty", units: "imperial")
        // Two installs' worth of state side by side: each launch(…) has its own store.
        let empty = launch(resetSession: true)
        signIn(empty, email: nobody.email)
        settleAfterSignIn(empty)
        let shortcut = empty.buttons["today.weighIn"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 20))
        empty.terminate()
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        let chip = logAgain(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        // Later launches keep the session and the saved food, as on a phone.
        for each in [app, empty] { each.launchArguments.removeAll { $0 == "--ui-testing" } }

        _ = try await request("DELETE", "/__test/launch-timings")
        var week: [Launch] = [], baseline: [Launch] = []
        for pair in 0..<Self.pairs {
            for weekFirst in pair.isMultiple(of: 2) ? [true, false] : [false, true] {
                if weekFirst {
                    week += try await timedLaunch(app, chip: chip, control: "logAgain", after: empty)
                } else {
                    baseline += try await timedLaunch(empty, chip: shortcut, control: "shortcuts", after: app)
                }
            }
        }

        let ratios = Self.percentiles(zip(week, baseline).map { $0.process / $1.process })
        let weekTimes = Self.percentiles(week.map(\.process)), emptyTimes = Self.percentiles(baseline.map(\.process))
        let environment = ProcessInfo.processInfo.environment
        let measuredHere = environment["SIMULATOR_MODEL_IDENTIFIER"] == Self.configuration.model
            && environment["SIMULATOR_RUNTIME_VERSION"] == Self.configuration.os
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        let report = "Cold launch, \(week.count) week-of-food launches paired with \(baseline.count) of an empty account. "
            + "Week over empty, the gate: median \(String(format: "%.3f", ratios.p50)), p95 \(String(format: "%.3f", ratios.p95)). "
            + "Process start to Today's first frame with Log again: \(weekTimes.text) (ceiling \(Self.weekCeiling) s"
            + (measuredHere ? "" : ", not checked: measured on an \(Self.configuration.name) on iOS \(Self.configuration.os)") + "); "
            + "the empty account's, with its shortcuts: \(emptyTimes.text), against \(Self.setAgainst.empty) s when the ceiling was set. "
            + "App start to that frame: \(Self.percentiles(week.map(\.app)).text). "
            + "Asking for the launch to Log again hittable, with XCTest's setup: \(Self.percentiles(week.map(\.wallClock)).text). "
            + "Log again hittable as the launch returned: \(week.filter(\.hittable).count) of \(week.count)."
            + week.enumerated().filter { !$0.element.placed }.map { " Launch \($0.offset + 1) misplaced: \($0.element.place)." }.joined()
            + String(format: " Load average %.0f, %.0f, %.0f.", load[0], load[1], load[2])
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "launch-to-logging"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(week.count, Self.pairs, "One report per week launch: \(report)")
        XCTAssertEqual(baseline.count, Self.pairs, "One report per empty launch: \(report)")
        XCTAssertEqual(week.filter(\.placed).count, week.count, "Each launch reported Log again where it was on screen: \(report)")
        XCTAssertEqual(week.filter(\.hittable).count, week.count, "Log again is ready when the launch returns: \(report)")
        XCTAssertLessThan(ratios.p50, Self.ratioCeiling, report)
        if measuredHere { XCTAssertLessThan(weekTimes.p50, Self.weekCeiling, report) }
    }

    /// One cold launch of `app`, after `other` is stopped: what it reported,
    /// or nothing if no report came.
    private func timedLaunch(_ app: XCUIApplication, chip: XCUIElement, control: String,
                             after other: XCUIApplication) async throws -> [Launch] {
        let before = try await request("GET", "/__test/launch-timings")["timings"] as? [[String: Any]] ?? []
        other.terminate()
        app.terminate()
        let clock = ContinuousClock(), started = clock.now
        app.launch()
        let seen = chip.exists ? chip.frame : nil
        let hittable = seen != nil && chip.isHittable
        XCTAssertTrue(chip.waitForExistence(timeout: 20) && chip.isHittable, "Signed in, on Today, with \(control)")
        let wallClock = Self.seconds(started.duration(to: clock.now))
        // A report is posted as its frame shows; give it a moment.
        var timings = before
        for _ in 0..<20 where timings.count <= before.count {
            try await Task.sleep(for: .milliseconds(250))
            timings = try await request("GET", "/__test/launch-timings")["timings"] as? [[String: Any]] ?? []
        }
        guard timings.count == before.count + 1, let timing = timings.last,
              let process = timing["processToReadyMs"] as? Double, let start = timing["initToReadyMs"] as? Double else { return [] }
        let place = (timing["frames"] as? [String: [Double]])?[control]
        var placed = false
        if let seen, let place, place.count == 4 {
            placed = seen.minY >= place[1] - 1 && seen.maxY <= place[1] + place[3] + 1
        }
        var detail = "seen at y \(seen.map { "\($0.minY)-\($0.maxY)" } ?? "none"), reported \(place.map { "\($0)" } ?? "none")"
        if !placed {
            // What moved it: Today as it settled, beside the run's other output.
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "misplaced launch"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["EXERLY_SCREEN_DIR"] {
                let file = URL(fileURLWithPath: directory).appendingPathComponent("misplaced-launch-\(UUID().uuidString.prefix(8)).png")
                if (try? shot.pngRepresentation.write(to: file)) != nil { detail += ", screenshot \(file.lastPathComponent)" }
            }
        }
        return [Launch(process: process / 1000, app: start / 1000, wallClock: wallClock, placed: placed, hittable: hittable,
                       place: detail)]
    }

    /// Three years of meals, workouts and weigh-ins on the device: launch
    /// still reaches Log again, the history read off the main actor.
    func testColdLaunchWithThreeYearsOfHistory() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "launch-years", units: "imperial")
        try await deleteSetupWeight(token: person.token)
        let entries = try await seedYearsOfHistory(token: person.token, days: 3 * 365)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        // Log again offers usual foods only at the hours this history eats
        // them; the shortcuts, which also end launch, are there at any hour.
        let usual = logAgain(app)
        let (chip, control) = usual.waitForExistence(timeout: 60) ? (usual, "logAgain") : (app.buttons["today.weighIn"], "shortcuts")
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        // The first sync brings the years down in pages; relaunch until all of it is on the device.
        var onDevice = 0
        for _ in 0..<20 where onDevice < entries {
            try await Task.sleep(for: .seconds(20))
            onDevice = try await coldLaunches(app, chip: chip, control: control, count: 1).timings.last?["entries"] as? Int ?? 0
        }
        XCTAssertGreaterThanOrEqual(onDevice, entries, "All \(entries) entries on the device")
        let (timings, hittable, placed) = try await coldLaunches(app, chip: chip, control: control, count: 10)
        let endToEnd = Self.percentiles(timings.compactMap { $0["processToReadyMs"] as? Double }.map { $0 / 1000 })
        let report = "Three years, \(onDevice) food entries: process start to Today's first frame with \(control) over "
            + "\(timings.count) cold launches: \(endToEnd.text); hittable as the launch returned: \(hittable) of \(timings.count), "
            + "where the launch reported it: \(placed)."
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "launch-three-years"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(hittable, timings.count, report)
        XCTAssertEqual(placed, timings.count, report)
        XCTAssertLessThan(endToEnd.p50, Self.yearsCeiling, report)
    }

    /// The p50 ceiling with three years on the device; see the test above.
    static let yearsCeiling = 3.5

    /// Today customized two ways: with the logging cards last, and with water,
    /// a card the first frame could leave for later, above the ring and Log
    /// again. Launch still draws them, and Log again, in its first frame,
    /// never a frame later, where it stays. Below the fold there, Log again
    /// isn't hittable without a scroll, so each launch must report the place
    /// the accessibility tree has it in as the launch returns.
    func testColdLaunchDrawsTheLoggingCardsInACustomizedOrder() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "launch-custom", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        let account = try XCTUnwrap(Self.accountID(in: person.token))
        let key = "-today.layout.v1.\(account)"
        app.launchArguments += [key, "meals,water,weight,training,quickActions,nutrition"]
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        let chip = logAgain(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        for order in ["meals,water,weight,training,quickActions,nutrition", "training,quickActions,weight,water,nutrition,meals"] {
            let at = try XCTUnwrap(app.launchArguments.firstIndex(of: key))
            app.launchArguments[at + 1] = order
            let (timings, hittable, placed) = try await coldLaunches(app, chip: chip, count: 5)
            let endToEnd = Self.percentiles(timings.compactMap { $0["processToReadyMs"] as? Double }.map { $0 / 1000 })
            print("Today as \(order): \(endToEnd.text) over \(timings.count) cold launches; Log again hittable as the launch returned: "
                  + "\(hittable), where the launch reported it: \(placed).")
            XCTAssertEqual(timings.count, 5, "Each launch reported the frame with Log again (\(order))")
            XCTAssertEqual(placed, 5, "Each launch reported Log again where it was drawn, not a frame early (\(order))")
        }

        // With the meal being eaten now logged and the shortcuts hidden, Log
        // again is the rest of yesterday on its own row, and launch ends there.
        let toast = SeedFood(name: "Wholegrain toast", per100g: ["energy": 250, "protein": 10, "carbohydrate": 43, "fat": 3.5])
        try await seedEntry(toast, grams: 60, daysAgo: 0, meal: "Breakfast", minutes: 1, token: person.token)
        let at = try XCTUnwrap(app.launchArguments.firstIndex(of: key))
        app.launchArguments[at + 1] = "-quickActions"
        let rest = app.buttons["today.repeatDay"]
        app.terminate()
        app.launch()
        XCTAssertTrue(rest.waitForExistence(timeout: 20), "The rest of yesterday stands alone once breakfast has food")
        let (timings, hittable, placed) = try await coldLaunches(app, chip: rest, count: 5)
        let endToEnd = Self.percentiles(timings.compactMap { $0["processToReadyMs"] as? Double }.map { $0 / 1000 })
        print("Today without shortcuts, the rest of the day alone: \(endToEnd.text) over \(timings.count) cold launches; "
              + "hittable as the launch returned: \(hittable), where the launch reported it: \(placed).")
        XCTAssertEqual(timings.count, 5, "Each launch reported the frame with the rest of the day")
        XCTAssertEqual(placed, 5, "Each launch reported the rest of the day where it was drawn")
    }

    private func logAgain(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
    }

    /// Launches from terminated `count` times: the app's reports, how many
    /// launches returned with the chip already hittable, and how many reported
    /// its `control` (Log again or the shortcuts) where the accessibility tree
    /// has the chip as the launch returned, so the time reported is the frame
    /// that placed it there.
    private func coldLaunches(_ app: XCUIApplication, chip: XCUIElement, control: String = "logAgain",
                              count: Int) async throws -> (timings: [[String: Any]], hittable: Int, placed: Int) {
        _ = try await request("DELETE", "/__test/launch-timings")
        var hittable = 0, placed = 0
        var timings: [[String: Any]] = []
        for launch in 0..<count {
            app.terminate()
            app.launch()
            let seen = chip.exists ? chip.frame : nil
            if seen != nil && chip.isHittable { hittable += 1 }
            XCTAssertTrue(chip.waitForExistence(timeout: 20))
            // A report is posted as its frame shows; give it a moment.
            for _ in 0..<20 where timings.count <= launch {
                timings = try await request("GET", "/__test/launch-timings")["timings"] as? [[String: Any]] ?? []
                if timings.count <= launch { try await Task.sleep(for: .milliseconds(250)) }
            }
            let frames = timings.count > launch ? timings[launch]["frames"] as? [String: [Double]] : nil
            if let seen, let reported = frames?[control], reported.count == 4,
               seen.minY >= reported[1] - 1, seen.maxY <= reported[1] + reported[3] + 1 { placed += 1 }
        }
        return (timings, hittable, placed)
    }

    private static func accountID(in token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var body = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["sub"] as? String
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func percentiles(_ values: [Double]) -> (p50: Double, p95: Double, text: String) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return (.infinity, .infinity, "none") }
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        return (p50, p95, String(format: "p50 %.3f s, p95 %.3f s", p50, p95))
    }
}
