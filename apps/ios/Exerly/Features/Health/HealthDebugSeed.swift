#if DEBUG
import ExerlyCore
import Foundation
import SwiftUI

/// Synthetic scale readings for UI tests, written to the simulator's Health
/// as another app would write them. Debug builds only, and only when a test
/// sets EXERLY_HEALTH_SEED to readings like "71.8|22.5|0|00:30;72.4||1|07:15":
/// kilograms, body fat % (optional), days ago and local time.
enum HealthDebugSeed {
    static let markerKey = "ExerlyDebugSeed"

    static var spec: String? {
        guard let value = ProcessInfo.processInfo.environment["EXERLY_HEALTH_SEED"], !value.isEmpty else { return nil }
        return value
    }

    /// Whether a UI test asked for synthetic sleep, heart rate variability
    /// and resting heart rate, written when each switch is turned on.
    static var recovery: Bool { ProcessInfo.processInfo.environment["EXERLY_HEALTH_RECOVERY_SEED"] == "1" }

    static func readings(_ spec: String, timeZone: TimeZone, now: Date = Date()) -> [(at: Date, kilograms: Double, bodyFat: Double?)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return spec.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let kilograms = Double(parts[0]), let daysAgo = Int(parts[2]) else { return nil }
            let time = parts[3].split(separator: ":").compactMap { Int($0) }
            guard time.count == 2, let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)),
                  let at = calendar.date(bySettingHour: time[0], minute: time[1], second: 0, of: day) else { return nil }
            return (at, kilograms, Double(parts[1]))
        }
    }

    /// A UI test's synthetic changes from Health waiting for the person
    /// (EXERLY_HEALTH_CHANGES_SEED=1): a soup imported yesterday that Health
    /// then deleted, and oats a full read no longer found, and today's yogurt
    /// with the tracker's set aside for it. Once per account, saved as reads
    /// would save them.
    @MainActor
    static func seedChanges(_ workspace: TrainingWorkspace, timeZone: TimeZone) throws {
        guard ProcessInfo.processInfo.environment["EXERLY_HEALTH_CHANGES_SEED"] == "1",
              workspace.healthImports.records.isEmpty, workspace.healthImports.queue.isEmpty else { return }
        let now = Date()
        let soup = HealthFoodReading(id: UUID(), at: now.addingTimeInterval(-26 * 3600), name: "Synthetic lentil soup",
                                     nutrients: NutrientAmounts([.energy: 320, .protein: 18]), source: "com.example.diary", sourceName: "Diary")
        let oats = HealthFoodReading(id: UUID(), at: now.addingTimeInterval(-50 * 3600), name: "Synthetic oats",
                                     nutrients: NutrientAmounts([.energy: 380, .protein: 13]), source: "com.example.tracker", sourceName: "Tracker")
        // Today's yogurt, from the diary app; the tracker's for the same day was set aside.
        let yogurt = HealthFoodReading(id: UUID(), at: now.addingTimeInterval(-3600), name: "Synthetic Greek yogurt",
                                       nutrients: NutrientAmounts([.energy: 150, .protein: 15]), source: "com.example.diary", sourceName: "Diary")
        var changes = HealthFoodChanges()
        changes.adding = [soup, oats, yogurt]
        let imports = workspace.healthImports
        try imports.apply(changes, to: workspace.nutrition, install: HealthImportInstall.id(), timeZone: timeZone)
        try imports.save(imports.noting([yogurt.id: [.init(source: "com.example.tracker", name: "Tracker")]], now: now))
        let listed = [(soup.id, HealthChangeQueue.Entry.Reason.deleted), (oats.id, .missing)].compactMap { id, reason in
            imports.records[id].map { HealthChangeQueue.Entry($0, reason: reason) }
        }
        try imports.save([], queue: HealthChangeQueue(entries: listed))
    }

    static func seedIfRequested(_ client: HealthStoreClient, timeZone: TimeZone) async {
        guard let spec, let service = client as? HealthKitService else { return }
        try? await service.seedDebugWeights(readings(spec, timeZone: timeZone), timeZone: timeZone)
    }
}

/// How many samples Exerly wrote to Health for the open account, so a UI test
/// can check writes without the Health app. Shown only with EXERLY_HEALTH_PROBE=1.
struct HealthDebugProbe: View {
    @ObservedObject var sync: HealthSync
    @State private var counts = ""

    var body: some View {
        if ProcessInfo.processInfo.environment["EXERLY_HEALTH_PROBE"] == "1" {
            Text(counts).font(.exSmall).foregroundStyle(Color.exTextMuted)
                .accessibilityIdentifier("health.debug.probe")
                .task(id: "\(sync.lastResult?.summary ?? "")-\(sync.isSyncing)") { await refresh() }
        }
    }

    private func refresh() async {
        guard let workspace = sync.workspace, let service = sync.client as? HealthKitService else { return }
        // Records a test names stay counted after they're deleted in Exerly.
        let named = (ProcessInfo.processInfo.environment["EXERLY_HEALTH_PROBE_IDS"] ?? "").split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        let food = await service.debugCount(.food, ids: workspace.nutrition.entries.map(\.id) + named)
        let weight = await service.debugCount(.weight, ids: workspace.nutrition.weights.map(\.id) + named)
        let workout = await service.debugCount(.workout, ids: workspace.store.history.sessions.map(\.id) + named)
        counts = "food \(food.count) (\(Int(food.kilocalories.rounded())) kcal) weight \(weight.count) workout \(workout.count)"
    }
}
#endif
