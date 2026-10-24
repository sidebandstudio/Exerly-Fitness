import AppIntents

/// Siri and Shortcuts learn from what someone did through Exerly's intents,
/// and those donations can name their foods, meals, weights and totals. They
/// go with the account, at sign-out and when it's deleted.
enum IntentDonations {
    /// The intents whose donations can carry an account's data.
    static let accountTypes: [any AppIntent.Type] = [
        LogFoodIntent.self, OpenFoodIntent.self, UndoFoodIntent.self, LoggedFoodSnippetIntent.self, LogFoodNamedIntent.self,
        LogBarcodeIntent.self, LogJSONIntent.self, QuickAddIntent.self, RepeatMealIntent.self, RepeatDayIntent.self,
        LogWeightIntent.self, LogWaterIntent.self, TodaySummaryIntent.self, CaloriesLeftIntent.self, LogNextSetIntent.self,
        RestIntent.self,
    ]

    /// Deletes each type's donations, trying a type the system refuses again
    /// a few times. Returns what was deleted and how many types still failed.
    @discardableResult
    static func clear(attempts: Int = 3, pause: Duration = .milliseconds(500),
                      delete: (IntentDonationMatchingPredicate) async throws -> [IntentDonationIdentifier] = {
                          try await IntentDonationManager.shared.deleteDonations(matching: $0)
                      }) async -> (deleted: [IntentDonationIdentifier], failed: Int) {
        var deleted: [IntentDonationIdentifier] = [], failed = 0
        for type in accountTypes {
            var done = false
            for attempt in 1...max(1, attempts) where !done {
                do {
                    deleted += try await delete(.intentType(type))
                    done = true
                } catch {
                    if attempt < attempts { try? await Task.sleep(for: pause) }
                }
            }
            if !done { failed += 1 }
        }
        return (deleted, failed)
    }
}
