import AppIntents
import XCTest
@testable import Exerly

/// What Siri learnt from an account's intents goes with it at sign-out.
@MainActor
final class IntentDonationsTests: XCTestCase {
    /// Every account intent's donations are deleted, and a refusal is tried again.
    func testEveryAccountIntentsDonationsGoAndARefusalIsTriedAgain() async {
        var asked = 0, refusals = 1
        let result = await IntentDonations.clear(pause: .zero) { _ in
            asked += 1
            if refusals > 0 {
                refusals -= 1
                throw CancellationError()
            }
            return []
        }
        XCTAssertEqual(asked, IntentDonations.accountTypes.count + 1)
        XCTAssertEqual(result.failed, 0)
        let stuck = await IntentDonations.clear(attempts: 2, pause: .zero) { _ in throw CancellationError() }
        XCTAssertEqual(stuck.failed, IntentDonations.accountTypes.count, "Reported, never dropped silently")
    }

    /// Against the system's donations: an intent's donation made before
    /// sign-out, then sign-out's cleanup, which the system accepts for every
    /// account intent. The simulator's donation store reports nothing
    /// deleted, even straight after a donation, so that the donation is gone
    /// can only be seen on a device.
    func testSignOutsCleanupIsAcceptedForADonationMadeBeforeIt() async throws {
        _ = try await IntentDonationManager.shared.donate(intent: CaloriesLeftIntent())
        let result = await IntentDonations.clear()
        XCTAssertEqual(result.failed, 0)
    }
}
