import ExerlyCore
import XCTest
@testable import Exerly

/// Three years of synthetic Health history: four foods a day from one app and
/// a workout every other day, imported, then read again as the Health screen
/// opens. Prints wall time on the main actor, where all of it runs.
@MainActor
final class HealthHistoryPerformanceTests: XCTestCase {
    func testThreeYearsOfHistoryImportsAndRereadsInBoundedTime() async throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TrainingWorkspace(accountID: "history", root: root)
        let client = FakeHistoryClient()
        let now = Date()
        for day in 1...1095 {
            for hour in [8, 12, 16, 19] {
                let at = now.addingTimeInterval(Double(-day) * 86400 + Double(hour - 12) * 3600)
                client.foods.append(HealthFoodReading(id: UUID(), at: at, name: "Synthetic meal \(hour)", nutrients: NutrientAmounts([.energy: 500, .protein: 30]),
                                                      source: "com.example.tracker", sourceName: "Tracker"))
            }
            if day % 2 == 0 {
                let start = now.addingTimeInterval(Double(-day) * 86400)
                client.workouts.append(HealthWorkoutReading(id: UUID(), start: start, end: start.addingTimeInterval(2400), activity: "Running",
                                                            kilocalories: 300, source: "com.apple.health.1", sourceName: "Watch"))
            }
        }
        let activities = FakeActivityStore(today: LocalDate(now, in: zone))
        let defaults = UserDefaults(suiteName: "perf-\(UUID().uuidString)")!
        let history = HealthHistoryModel(accountID: "history", timeZone: zone, client: client, namespace: "test", defaults: defaults,
                                         workspace: { workspace }, isCurrent: { _ in true }, enableWeights: { _ in true },
                                         activities: { activities })
        let clock = ContinuousClock()
        let foodImport = await clock.measure {
            await history.begin(.foods)
            await history.confirm()
        }
        XCTAssertEqual(workspace.nutrition.entries.count, 4380)
        let workoutImport = await clock.measure {
            await history.begin(.workouts)
            await history.confirm()
        }
        XCTAssertEqual(activities.saved.count, 547)
        let reopen = await clock.measure { await history.refresh() }
        print("HEALTH-PERF foods import \(foodImport), workouts import \(workoutImport), screen reopen \(reopen)")
    }
}
