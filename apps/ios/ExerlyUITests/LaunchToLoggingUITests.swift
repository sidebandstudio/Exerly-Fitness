import XCTest

/// Cold launch to logging (PARITY B03), for docs/TAP_BUDGETS.md. A signed-in
/// person with a week of food relaunches the app 20 times from terminated.
/// Each launch records the app's own interval (LaunchTiming: from the app's
/// start to Today on screen with Log again, one tap from a logged food) with
/// XCTOSSignpostMetric, and the time to its first responsive frame with
/// XCTApplicationLaunchMetric. Simulator figures, not a phone's: the local
/// full suite runs it, CI's shared runners don't.
@MainActor
final class LaunchToLoggingUITests: ExerlyUITestCase {
    /// The simulator ceiling for the app's interval at p50, above today's
    /// 1.23 s (Debug, iPhone 17 Pro Max simulator on an M1 Max), so a slower
    /// launch fails. PARITY B03's target is under 1 s on a phone.
    static let ceiling = 1.5

    func testColdLaunchToLoggingStaysUnderItsCeiling() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "launch", units: "imperial")
        try await seedWeek(token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        settleAfterSignIn(app)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.suggestion.log.")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        // Later launches keep the session and the saved food, as on a phone.
        app.launchArguments.removeAll { $0 == "--ui-testing" }

        RecordedSignpostMetric.values = []
        let ready = RecordedSignpostMetric(subsystem: "com.exerly.fitness", category: "launch", name: "LaunchToLogging")
        let options = XCTMeasureOptions()
        options.iterationCount = 20
        // Each run ends once Today is up, so its interval ends inside the run.
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), ready], options: options) {
            app.launch()
            XCTAssertTrue(chip.waitForExistence(timeout: 10), "Signed in, on Today, with Log again")
        }

        let sorted = RecordedSignpostMetric.values.sorted()
        XCTAssertGreaterThanOrEqual(sorted.count, 20, "One interval for each launch")
        guard !sorted.isEmpty else { return }
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        let report = String(format: "Launch to logging over %d cold launches: p50 %.3f s, p95 %.3f s; all %@", sorted.count, p50, p95,
                            sorted.map { String(format: "%.3f", $0) }.joined(separator: " "))
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "launch-to-logging"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(p50, Self.ceiling, report)
    }
}

/// The app's signpost interval, keeping the durations it reports so the
/// test can assert on them. `measure` copies the metric for each run.
private final class RecordedSignpostMetric: XCTOSSignpostMetric {
    nonisolated(unsafe) static var values: [Double] = []

    override func reportMeasurements(from startTime: XCTPerformanceMeasurementTimestamp,
                                     to endTime: XCTPerformanceMeasurementTimestamp) throws -> [XCTPerformanceMeasurement] {
        let measurements = try super.reportMeasurements(from: startTime, to: endTime)
        Self.values += measurements.filter { $0.identifier.hasSuffix(".duration") }.compactMap { measurement in
            (measurement.value.unit as? UnitDuration).map {
                Measurement(value: measurement.value.value, unit: $0).converted(to: .seconds).value
            }
        }
        return measurements
    }
}
