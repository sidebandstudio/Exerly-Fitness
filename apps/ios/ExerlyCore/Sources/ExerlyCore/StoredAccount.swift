import Foundation

/// An account's largest stores, read and decoded from its database on
/// whatever thread calls `read`, with a connection of its own, so opening a
/// long history never blocks the main actor. The stores then start from it
/// (`NutritionStore(persistence:loaded:)`, `TrainingStore(persistence:loaded:)`).
public struct StoredAccount: Sendable {
    public struct Nutrition: Sendable {
        let foods: [Food]
        let entries: [FoodEntry]
        let days: [LocalDate: NutritionDay]
        let weights: [WeightEntry]
        let plans: [NutritionPlan]
        let hidden: [HiddenSuggestion]
    }

    public struct Training: Sendable {
        let sessions: [WorkoutSession]
        let customExercises: [Exercise]
        /// Its rows that couldn't be decoded, as `table/id`: the store tells
        /// persistence, so sync never takes them for deleted.
        let unreadable: [String]
    }

    public let nutrition: Nutrition
    public let training: Training
    /// Rows that couldn't be decoded, as `table/id`; left in the file as they are.
    public let unreadableRows: [String]

    /// Nil when there is nothing to read yet: no file, which opens on the
    /// main actor as before, with no history to wait for. A file an older
    /// version wrote is migrated here first, so its history is read here too;
    /// one a newer version wrote throws, as the main connection would.
    public static func read(url: URL) throws -> StoredAccount? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var database = try SQLiteDatabase(url: url, readOnly: true)
        defer { database.close() }
        if try SQLiteTrainingPersistence.schemaVersion(database) != SQLiteTrainingPersistence.currentSchemaVersion {
            database.close()
            try SQLiteTrainingPersistence.migrate(url: url)
            database = try SQLiteDatabase(url: url, readOnly: true)
        }
        guard case .integer(let version) = try database.query("PRAGMA user_version").first?.first,
              version == SQLiteTrainingPersistence.currentSchemaVersion else { return nil }
        var unreadable: [String] = []
        func documents(_ kind: String) throws -> [Data] {
            try database.query("SELECT payload FROM documents WHERE kind = ? ORDER BY id", kind).compactMap { row in
                if case .blob(let payload) = row[0] { return payload }
                return nil
            }
        }
        // The same tolerance as SQLiteTrainingPersistence: an unreadable row is
        // noted and skipped, never dropped from the file.
        func rows<T: Decodable>(_ type: T.Type, table: String, order: String) throws -> [T] {
            let decoder = JSONDecoder()
            return try database.query("SELECT id, payload FROM \(table) ORDER BY \(order)").compactMap { row in
                guard case .text(let id) = row[0] else { return nil }
                if case .blob(let payload) = row[1], let value = try? decoder.decode(T.self, from: payload) { return value }
                unreadable.append("\(table)/\(id)")
                return nil
            }
        }
        let decoder = ExerlyJSON.decoder
        let nutrition = Nutrition(
            foods: try documents(NutritionStore.foodKind).map { try decoder.decode(Food.self, from: $0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            entries: try documents(NutritionStore.entryKind).map { try decoder.decode(FoodEntry.self, from: $0) }
                .sorted(by: NutritionStore.entryOrder),
            days: Dictionary(try documents(NutritionStore.dayKind).map { try decoder.decode(NutritionDay.self, from: $0) }
                .map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a }),
            weights: try documents(NutritionStore.weightKind).map { try decoder.decode(WeightEntry.self, from: $0) }
                .sorted { $0.at < $1.at },
            plans: try documents(NutritionStore.planKind).map { try decoder.decode(NutritionPlan.self, from: $0) }
                .sorted(by: NutritionStore.planOrder),
            hidden: try documents(NutritionStore.hiddenKind).map { try decoder.decode(HiddenSuggestion.self, from: $0) }
                .sorted(by: NutritionStore.hiddenOrder))
        let sessions = try rows(WorkoutSession.self, table: "sessions", order: "started_at")
        let customExercises = try rows(Exercise.self, table: "custom_exercises", order: "id")
        let training = Training(sessions: sessions, customExercises: customExercises, unreadable: unreadable)
        return StoredAccount(nutrition: nutrition, training: training, unreadableRows: unreadable)
    }
}
