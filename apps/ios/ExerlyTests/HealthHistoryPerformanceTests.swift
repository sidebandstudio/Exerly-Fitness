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

    /// Opening an account with three years of Health import records, a third
    /// of them taken out: wall time in all, and on the main actor, where only
    /// the stores' setup runs once the history is read off it.
    func testOpeningAnAccountWithThreeYearsOfImportRecords() async throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TrainingWorkspace(accountID: "opening", root: root)
        let now = Date()
        var foods = HealthFoodChanges(), removing = HealthFoodChanges(), workouts: [HealthImport] = []
        for day in 1...1095 {
            for hour in [8, 12, 16, 19] {
                let at = now.addingTimeInterval(Double(-day) * 86400 + Double(hour - 12) * 3600)
                let reading = HealthFoodReading(id: UUID(), at: at, name: "Synthetic meal \(hour)", nutrients: NutrientAmounts([.energy: 500]),
                                                source: "com.example.tracker", sourceName: "Tracker")
                foods.adding.append(reading)
                if hour == 16 || (hour == 19 && day % 3 == 0) { removing.removing.append(reading.id) }
            }
            if day % 2 == 0 {
                let start = now.addingTimeInterval(Double(-day) * 86400)
                let reading = HealthWorkoutReading(id: UUID(), start: start, end: start.addingTimeInterval(2400), activity: "Running",
                                                   kilocalories: 300, source: "com.apple.health.1", sourceName: "Watch")
                workouts.append(HealthImport(workout: reading, clientID: HealthHistory.activityID(for: reading.id, accountID: "opening"),
                                             fingerprint: "f", owner: "phone", timeZone: zone))
            }
        }
        try workspace.healthImports.apply(foods, to: workspace.nutrition, install: "phone", timeZone: zone)
        try workspace.healthImports.apply(removing, to: workspace.nutrition, install: "phone", timeZone: zone)
        try workspace.healthImports.save(workouts)
        await workspace.close()
        let read = StoredRead()
        let clock = ContinuousClock()
        var opened: TrainingWorkspace?
        let total = try await clock.measure {
            opened = try await TrainingWorkspace.open(accountID: "opening", root: root, api: nil) { url in try read.read(url) }
        }
        XCTAssertEqual(opened?.healthImports.records.count, 4380 + 547)
        await opened?.close()
        var again: TrainingWorkspace?
        let mainActor = try clock.measure { again = try TrainingWorkspace(accountID: "opening", root: root, stored: read.stored) }
        XCTAssertEqual(again?.healthImports.records.count, 4380 + 547)
        await again?.close()
        print("HEALTH-OPEN \(4380 + 547) records, \(removing.removing.count) taken out: open \(total), main actor \(mainActor)")
    }
}

/// What an opening read, kept to open again from on the main actor.
private final class StoredRead: @unchecked Sendable {
    private(set) var stored: StoredAccount?

    func read(_ url: URL) throws -> StoredAccount? {
        stored = try StoredAccount.read(url: url)
        return stored
    }
}

