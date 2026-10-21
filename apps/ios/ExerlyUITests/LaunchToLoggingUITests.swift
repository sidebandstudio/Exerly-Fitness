import XCTest

/// Cold launch to logging (PARITY B03), for docs/TAP_BUDGETS.md. A signed-in
/// person with a week of food relaunches the app 20 times from terminated.
/// The gate is end to end: from the process starting (the kernel's clock,
/// so loading the app's code counts) to the first frame drawn with Today and
/// Log again, which the app reports to the fixture (LaunchTiming); and Log
/// again's chip, one tap from a logged food, must be hittable by the time the
/// launch returns. Reported beside it: XCTApplicationLaunchMetric's launch to
/// a responsive first frame (in the log), the app's own interval from its
/// start (XCTOSSignpostMetric), and the wall clock from asking for the launch
/// to the chip being hittable, which includes XCTest's own setup. Simulator
/// figures, not a phone's: the local full suite runs it, CI's shared runners
/// don't.
@MainActor
final class LaunchToLoggingUITests: ExerlyUITestCase {
    /// The p50 ceiling, in seconds, from the process starting to Today's first
    /// frame with Log again, on an iPhone 17 Pro Max simulator (Debug, M1
    /// Max). Measured back to back on 2026-10-20: 2.67 s before Today opened
    /// from the cache and drew its top first, 2.41 to 2.46 s after. PARITY
    /// B03's target is under 1 s on a phone.
    static let ceiling = 2.55

    func testColdLaunchToLoggingStaysUnderItsCeiling() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "launch", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        let chip = logAgain(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        // Later launches keep the session and the saved food, as on a phone.
        app.launchArguments.removeAll { $0 == "--ui-testing" }

        _ = try await request("DELETE", "/__test/launch-timings")
        RecordedSignpostMetric.values = []
        var wallClock: [Double] = []
        var hittableAtLaunch = 0
        let clock = ContinuousClock()
        let options = XCTMeasureOptions()
        options.iterationCount = 20
        let launchMetric = XCTApplicationLaunchMetric(waitUntilResponsive: true)
        let ready = RecordedSignpostMetric(subsystem: "com.exerly.fitness", category: "launch", name: "LaunchToLogging")
        measure(metrics: [launchMetric, ready], options: options) {
            let started = clock.now
            app.launch()
            if chip.exists && chip.isHittable { hittableAtLaunch += 1 }
            XCTAssertTrue(chip.waitForExistence(timeout: 10) && chip.isHittable, "Signed in, on Today, with Log again")
            wallClock.append(Self.seconds(started.duration(to: clock.now)))
        }

        let timings = try await request("GET", "/__test/launch-timings")["timings"] as? [[String: Any]] ?? []
        let endToEnd = Self.percentiles(timings.compactMap { $0["processToReadyMs"] as? Double }.map { $0 / 1000 })
        let report = "Cold launch over \(timings.count) launches. Process start to Today's first frame with Log again: \(endToEnd.text). "
            + "App start to that frame (signpost): \(Self.percentiles(RecordedSignpostMetric.values).text). "
            + "Asking for the launch to Log again hittable, with XCTest's setup: \(Self.percentiles(wallClock).text). "
            + "Log again hittable as the launch returned: \(hittableAtLaunch) of \(wallClock.count)."
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "launch-to-logging"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(timings.count, 20, "One report per launch")
        XCTAssertEqual(hittableAtLaunch, wallClock.count, "Log again is ready when the launch returns: \(report)")
        XCTAssertLessThan(endToEnd.p50, Self.ceiling, report)
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
        let chip = logAgain(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 60))
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        // The first sync brings the years down in pages; relaunch until all of it is on the device.
        var onDevice = 0
        for _ in 0..<20 where onDevice < entries {
            try await Task.sleep(for: .seconds(20))
            onDevice = try await coldLaunches(app, chip: chip, count: 1).timings.last?["entries"] as? Int ?? 0
        }
        XCTAssertGreaterThanOrEqual(onDevice, entries, "All \(entries) entries on the device")
        let (timings, hittable) = try await coldLaunches(app, chip: chip, count: 10)
        let endToEnd = Self.percentiles(timings.compactMap { $0["processToReadyMs"] as? Double }.map { $0 / 1000 })
        let report = "Three years, \(onDevice) food entries: process start to Today's first frame with Log again over "
            + "\(timings.count) cold launches: \(endToEnd.text); Log again hittable as the launch returned: \(hittable) of \(timings.count)."
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "launch-three-years"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(hittable, timings.count, report)
        XCTAssertLessThan(endToEnd.p50, Self.yearsCeiling, report)
    }

    /// The p50 ceiling with three years on the device; see the test above.
    static let yearsCeiling = 3.5

    /// Today customized with the logging cards last: launch still draws them,
    /// and Log again, in its first frame, never a frame later.
    func testColdLaunchDrawsTheLoggingCardsInACustomizedOrder() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "launch-custom", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        let account = try XCTUnwrap(Self.accountID(in: person.token))
        app.launchArguments += ["-today.layout.v1.\(account)", "meals,water,weight,training,quickActions,nutrition"]
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        let chip = logAgain(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--ui-testing" }
        let (timings, hittable) = try await coldLaunches(app, chip: chip, count: 5)
        XCTAssertEqual(timings.count, 5, "Each launch reported the frame with Log again")
        XCTAssertEqual(hittable, 5, "Log again was reachable as each launch returned")
    }

    private func logAgain(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
    }

    /// Launches from terminated `count` times: the app's reports, and how many
    /// launches returned with the chip already reachable.
    private func coldLaunches(_ app: XCUIApplication, chip: XCUIElement, count: Int) async throws -> (timings: [[String: Any]], hittable: Int) {
        _ = try await request("DELETE", "/__test/launch-timings")
        var hittable = 0
        for _ in 0..<count {
            app.terminate()
            app.launch()
            if chip.exists && chip.isHittable { hittable += 1 }
            XCTAssertTrue(chip.waitForExistence(timeout: 20))
        }
        // A report is posted as its frame shows; give the last one a moment.
        try await Task.sleep(for: .seconds(2))
        return (try await request("GET", "/__test/launch-timings")["timings"] as? [[String: Any]] ?? [], hittable)
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

/// The durations a metric reports, in seconds.
private func recordedSeconds(_ measurements: [XCTPerformanceMeasurement]) -> [Double] {
    measurements.filter { $0.identifier.hasSuffix(".duration") }.compactMap { measurement in
        (measurement.value.unit as? UnitDuration).map { Measurement(value: measurement.value.value, unit: $0).converted(to: .seconds).value }
    }
}

/// The app's signpost interval, keeping what it reports to `measure` so the
/// report can include it. `measure` copies the metric for every run.
private final class RecordedSignpostMetric: XCTOSSignpostMetric {
    nonisolated(unsafe) static var values: [Double] = []

    override func reportMeasurements(from startTime: XCTPerformanceMeasurementTimestamp,
                                     to endTime: XCTPerformanceMeasurementTimestamp) throws -> [XCTPerformanceMeasurement] {
        let measurements = try super.reportMeasurements(from: startTime, to: endTime)
        Self.values += recordedSeconds(measurements)
        return measurements
    }
}
