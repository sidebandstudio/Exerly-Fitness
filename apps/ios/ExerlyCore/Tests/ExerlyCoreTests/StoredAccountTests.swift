import Foundation
import Testing
@testable import ExerlyCore

/// Opening an account from its database read off the main actor gives the
/// same stores as reading it on the main actor.
@MainActor
@Suite struct StoredAccountTests {
    @Test func storesOpenedFromAReadOffTheMainActorMatchOnesReadOnIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-stored-\(UUID().uuidString)/x.sqlite")
        #expect(try StoredAccount.read(url: url) == nil, "Nothing to read before the file exists")
        let persistence = try SQLiteTrainingPersistence(url: url)
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        let thursday = LocalDate("2026-10-08")!, friday = LocalDate("2026-10-09")!
        try nutrition.log(Foods.oats, grams: 60, on: thursday, meal: "Breakfast")
        try nutrition.log(Foods.milk, grams: 244, on: friday, meal: "Breakfast")
        try nutrition.log(Foods.chicken, grams: 150, on: thursday, meal: "Dinner")
        try persistence.save(Fixture.session([("deadlift", [Fixture.set(5, 140)])]))
        // A row a newer version wrote, which this one can't read, stays and is counted.
        try persistence.database.execute("INSERT INTO sessions (id, started_at, ended_at, payload, updated_at) VALUES (?, ?, ?, ?, ?)",
                                          "unreadable", Date(), Date(), Data("{}".utf8), Date())

        let stored = try #require(try await Task.detached { try StoredAccount.read(url: url) }.value)
        let fromStored = NutritionStore(persistence: persistence, loaded: stored.nutrition)
        let direct = try NutritionStore(persistence: persistence)
        #expect(fromStored.entries == direct.entries)
        #expect(fromStored.entries.map(\.date) == [thursday, thursday, friday], "In the store's order")
        let training = try TrainingStore(persistence: persistence, loaded: stored.training)
        let directTraining = try TrainingStore(persistence: persistence)
        #expect(training.history.sessions == directTraining.history.sessions)
        #expect(stored.unreadableRows == ["sessions/unreadable"])
    }

    /// Health import records are read off the main actor with the rest, a
    /// removed one as its tombstone.
    @Test func healthImportRecordsAreReadOffTheMainActorToo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-stored-\(UUID().uuidString)/x.sqlite")
        let persistence = try SQLiteTrainingPersistence(url: url)
        let nutrition = try NutritionStore(persistence: persistence), imports = try HealthImportStore(persistence: persistence)
        let zone = TimeZone(identifier: "America/New_York")!
        let soup = HealthFoodReading(id: UUID(), at: Fixture.instant(), name: "Synthetic soup", nutrients: NutrientAmounts([.energy: 250]),
                                     source: "com.example.tracker", sourceName: "Tracker")
        let toast = HealthFoodReading(id: UUID(), at: Fixture.instant().addingTimeInterval(-3600), name: "Synthetic toast",
                                      nutrients: NutrientAmounts([.energy: 120]), source: "com.example.tracker", sourceName: "Tracker")
        var adding = HealthFoodChanges(), removing = HealthFoodChanges()
        adding.adding = [soup, toast]
        removing.removing = [toast.id]
        try imports.apply(adding, to: nutrition, install: "phone", timeZone: zone)
        try imports.apply(removing, to: nutrition, install: "phone", timeZone: zone)
        let stored = try #require(try await Task.detached { try StoredAccount.read(url: url) }.value)
        let loaded = try HealthImportStore(persistence: persistence, loaded: stored.healthImports)
        #expect(loaded.records == (try HealthImportStore(persistence: persistence)).records)
        #expect(loaded.records[toast.id]?.state == .removed && loaded.records[toast.id]?.target == "")
        #expect(stored.healthImportWork == nil)
        #expect(try loaded.pendingWork() == nil, "no work left unfinished")

        // Work a crash left unfinished is read with them, and is gone once finished.
        try imports.recordWork(Data("planned".utf8))
        let reopened = try #require(try await Task.detached { try StoredAccount.read(url: url) }.value)
        #expect(reopened.healthImportWork == Data("planned".utf8))
        let opening = try HealthImportStore(persistence: persistence, loaded: reopened.healthImports, work: reopened.healthImportWork)
        #expect(try opening.pendingWork() == Data("planned".utf8))
        try opening.save([], finishingWork: true)
        #expect(try opening.pendingWork() == nil)
        #expect(try imports.pendingWork() == nil)
    }

    /// A file an older version wrote is brought up to date and read off the
    /// main actor too, not left for the stores to read on it.
    @Test func aFileInAnOlderSchemaIsMigratedAndReadOffTheMainActor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-stored-\(UUID().uuidString)/x.sqlite")
        let persistence = try SQLiteTrainingPersistence(url: url)
        let session = Fixture.session([("deadlift", [Fixture.set(5, 140)])])
        try persistence.save(session)
        // Version 3 had no documents table.
        try persistence.database.executeScript("DROP TABLE documents; PRAGMA user_version = 3;")
        persistence.close()

        let stored = try #require(try await Task.detached { try StoredAccount.read(url: url) }.value, "Read, not left for later")
        #expect(stored.training.sessions.map(\.id) == [session.id])
        #expect(stored.nutrition.entries.isEmpty)
        let reopened = try SQLiteTrainingPersistence(url: url)
        #expect(try reopened.schemaVersion() == SQLiteTrainingPersistence.currentSchemaVersion)
        #expect(try TrainingStore(persistence: reopened, loaded: stored.training).history.sessions.map(\.id) == [session.id])
    }

    /// Two opens of one older file, an abandoned one and its replacement,
    /// can migrate it at once: both succeed, and it ends up current.
    @Test func twoMigrationsOfAnOlderFileRacingBothSucceed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var made: [URL] = []
        for index in 0..<40 {
            let url = directory.appendingPathComponent("\(index)/x.sqlite")
            let persistence = try SQLiteTrainingPersistence(url: url)
            try persistence.database.executeScript("DROP TABLE documents; PRAGMA user_version = 3;")
            persistence.close()
            made.append(url)
        }
        let urls = made
        let failures = await Task.detached { () -> [String] in
            let failures = Failures()
            for url in urls {
                DispatchQueue.concurrentPerform(iterations: 2) { _ in
                    do { try SQLiteTrainingPersistence.migrate(url: url) } catch { failures.append("\(error)") }
                }
            }
            return failures.all
        }.value
        #expect(failures.isEmpty, "\(failures.count) of \(urls.count * 2) failed: \(failures.first ?? "")")
        for url in urls { #expect(try SQLiteTrainingPersistence(url: url).schemaVersion() == SQLiteTrainingPersistence.currentSchemaVersion) }
    }
}

/// Errors collected from several threads.
private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    func append(_ item: String) { lock.withLock { items.append(item) } }
}
