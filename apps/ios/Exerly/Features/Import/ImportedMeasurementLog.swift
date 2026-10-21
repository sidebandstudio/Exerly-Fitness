import ExerlyCore
import Foundation

/// The account's measurement log as an import sees it: measurements from
/// MacroFactor, Hevy or Strong are saved through the sync engine like any
/// entered here, with their app named in the note, and Undo deletes them.
@MainActor
final class ImportedMeasurementLog: ImportedMeasurementStore {
    private let sync: SyncEngine

    /// Nil unless the sync engine belongs to `accountID`, so an import never
    /// writes another account's log.
    init?(sync: SyncEngine, accountID: String) {
        guard sync.isConfigured(for: accountID) else { return nil }
        self.sync = sync
    }

    func existing(_ clientIDs: [String]) -> Set<String> { (try? sync.measurementClientIDs(clientIDs)) ?? [] }

    func add(_ measurements: [ImportedMeasurement]) throws {
        try sync.saveImportedMeasurements(measurements.map { measurement in
            (measurement.clientID, BodyMeasurementRequest(type: measurement.site.rawValue, value: measurement.value,
                                                          unit: measurement.site == .bodyFat ? "%" : "cm",
                                                          entry_date: measurement.date.description,
                                                          note: "From \(measurement.source.name)", source: "imported"))
        })
    }

    func remove(_ measurements: [ImportedMeasurement]) throws -> (removed: Int, kept: Int) {
        try sync.removeImportedMeasurements(measurements.map { ($0.clientID, $0.value) })
    }
}
