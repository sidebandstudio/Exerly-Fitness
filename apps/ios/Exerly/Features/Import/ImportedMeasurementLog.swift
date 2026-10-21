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

    func states(_ clientIDs: [String]) -> [String: MeasurementState] { (try? sync.measurementStates(clientIDs)) ?? [:] }

    func add(_ measurements: [ImportedMeasurement]) throws {
        try sync.saveImportedMeasurements(measurements.map { ($0.clientID, Self.request($0)) })
    }

    func update(_ changes: [ImportedMeasurementChange]) throws -> (updated: Int, kept: Int) {
        try sync.updateImportedMeasurements(changes.map { ($0.measurement.clientID, $0.earlier.state, Self.request($0.measurement)) })
    }

    func remove(_ measurements: [ImportedMeasurement]) throws -> (removed: Int, kept: Int) {
        try sync.removeImportedMeasurements(measurements.map { ($0.clientID, $0.state) })
    }

    func restore(_ measurements: [ImportedMeasurement]) throws {
        try sync.restoreImportedMeasurements(measurements.map(\.clientID))
    }

    /// The measurement as its state says, with its app named in the note.
    private static func request(_ measurement: ImportedMeasurement) -> BodyMeasurementRequest {
        let state = measurement.state
        return BodyMeasurementRequest(type: state.type, value: state.value, unit: state.unit, entry_date: state.date,
                                      note: state.note, source: state.source ?? "imported")
    }
}
