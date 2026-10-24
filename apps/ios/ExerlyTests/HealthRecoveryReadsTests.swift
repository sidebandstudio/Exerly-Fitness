import ExerlyCore
import XCTest
@testable import Exerly

/// The sleep, heart rate variability and resting heart rate switches: each
/// asks for and reads only its own type, per account, and says when Health
/// has nothing.
@MainActor
final class HealthRecoveryReadsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private var defaults: UserDefaults!
    private var client: FakeRecoveryClient!
    private let watch = "com.apple.health.81E5A1B0"

    override func setUp() {
        defaults = UserDefaults(suiteName: "recovery-\(UUID().uuidString)")
        client = FakeRecoveryClient()
    }

    private var current = "account-a"

    private func model(_ account: String = "account-a", now: Date) -> HealthRecoveryModel {
        HealthRecoveryModel(accountID: account, timeZone: zone, client: client, namespace: "test", defaults: defaults, now: { now },
                            isCurrent: { $0 == self.current })
    }

    private func at(_ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testEachSwitchAsksForAndReadsOnlyItsOwnType() async {
        let now = at(15, 9)
        client.samples.sleep = [HealthSleepReading(start: at(14, 23), end: at(15, 6), kind: .asleep, source: watch)]
        client.samples.hrv = [HealthHeartReading(at: at(15, 4), value: 48, source: watch)]
        let recovery = model(now: now)
        await recovery.refresh()
        XCTAssertTrue(client.reads.isEmpty, "Nothing is read while every switch is off")
        XCTAssertNil(recovery.recovery)

        await recovery.setEnabled(.sleep, true)
        XCTAssertEqual(client.requested, [.sleep])
        XCTAssertEqual(client.reads.last, [.sleep])
        XCTAssertEqual(recovery.latest(.sleep)?.value, 7)
        XCTAssertEqual(recovery.latest(.sleep)?.date, LocalDate("2026-10-15"))
        XCTAssertEqual(recovery.coverage(.sleep), 1)
        XCTAssertNil(recovery.latest(.hrv), "HRV isn't read without its own switch, though Health has it")
        XCTAssertEqual(recovery.recovery?.count, HealthRecoveryModel.days)

        await recovery.setEnabled(.hrv, true)
        XCTAssertEqual(client.requested, [.sleep, .hrv])
        XCTAssertEqual(client.reads.last, [.sleep, .hrv])
        XCTAssertEqual(recovery.latest(.hrv)?.value, 48)

        await recovery.setEnabled(.sleep, false)
        XCTAssertEqual(client.reads.last, [.hrv])
        XCTAssertNil(recovery.latest(.sleep))

        XCTAssertEqual(model(now: now).enabled, [.hrv], "Kept for the account")
        XCTAssertTrue(model("account-b", now: now).enabled.isEmpty, "Each account chooses its own")
    }

    func testMissingDataIsShownAsMissingNotZero() async {
        let recovery = model(now: at(15, 9))
        await recovery.setEnabled(.restingHeartRate, true)
        XCTAssertNotNil(recovery.recovery)
        XCTAssertNil(recovery.latest(.restingHeartRate))
        XCTAssertEqual(recovery.coverage(.restingHeartRate), 0)
        XCTAssertTrue(RecoveryStatus.Signal.restingHeartRate.missing.hasPrefix("No resting heart rate in Health this week."))
    }

    func testUnavailableOrRefusedAccessLeavesTheSwitchOffAndSaysWhy() async {
        let recovery = model(now: at(15, 9))
        client.available = false
        await recovery.setEnabled(.sleep, true)
        XCTAssertTrue(recovery.enabled.isEmpty)
        XCTAssertEqual(recovery.messages[.sleep], "Apple Health isn't available on this device.")
        client.available = true
        client.failRequests = true
        await recovery.setEnabled(.sleep, true)
        XCTAssertTrue(recovery.enabled.isEmpty)
        XCTAssertEqual(recovery.messages[.sleep], "Health access couldn't open. Try again.")
        XCTAssertTrue(client.reads.isEmpty)
    }

    /// Review 1: what Health returns after another account opens isn't shown to it.
    func testAReadThatFinishesAfterAnotherAccountOpensShowsNothing() async {
        let now = at(15, 9)
        client.samples.sleep = [HealthSleepReading(start: at(14, 23), end: at(15, 6), kind: .asleep, source: watch)]
        let recovery = model(now: now)
        await recovery.setEnabled(.sleep, true)
        XCTAssertNotNil(recovery.recovery)

        let other = model("account-b", now: now)
        client.onRead = { self.current = "account-b" }
        await recovery.refresh()
        XCTAssertEqual(recovery.recovery?.last?.sleepHours, 7, "The earlier read stays; the late one is dropped")
        client.onRead = nil
        current = "account-a"
        client.onRequest = { self.current = "account-b" }
        await recovery.setEnabled(.hrv, true)
        XCTAssertFalse(recovery.enabled.contains(.hrv), "A switch answered after another account opened stays off")
        XCTAssertTrue(other.enabled.isEmpty)
    }
}

final class FakeRecoveryClient: HealthRecoveryClient, @unchecked Sendable {
    /// Run while Health is asked or read, before it answers.
    var onRead: (@MainActor () -> Void)?
    var onRequest: (@MainActor () -> Void)?
    var available = true
    var failRequests = false
    var samples = HealthRecoverySamples()
    var requested: [RecoveryStatus.Signal] = []
    var reads: [Set<RecoveryStatus.Signal>] = []

    var isAvailable: Bool { available }

    func requestAccess(_ signal: RecoveryStatus.Signal) async throws {
        if failRequests { throw URLError(.cancelled) }
        requested.append(signal)
        await onRequest?()
    }

    func read(_ signals: Set<RecoveryStatus.Signal>, in span: DateInterval) async throws -> HealthRecoverySamples {
        reads.append(signals)
        await onRead?()
        return HealthRecoverySamples(sleep: signals.contains(.sleep) ? samples.sleep : [],
                                     hrv: signals.contains(.hrv) ? samples.hrv : [],
                                     restingHeartRate: signals.contains(.restingHeartRate) ? samples.restingHeartRate : [])
    }
}
