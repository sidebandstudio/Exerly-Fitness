import ExerlyCore
import SwiftUI

/// One plate's claim on offline scans put on it: the scanner's plate, or a
/// meal being built. Its scans stay ready to log elsewhere once the plate
/// goes away unlogged.
@MainActor
final class BarcodeStaging: ObservableObject {
    let scope = "plate-\(UUID().uuidString)"
    let library: BarcodeLibrary

    init(library: BarcodeLibrary) {
        self.library = library
    }

    deinit {
        let library = library, scope = scope
        Task { @MainActor in library.unstage(scope: scope) }
    }
}

private struct BarcodeStagingScopeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The meal being built that a scan picked into it joins, so an offline
    /// scan picked from the scanner is consumed when that meal logs.
    var barcodeStagingScope: String? {
        get { self[BarcodeStagingScopeKey.self] }
        set { self[BarcodeStagingScopeKey.self] = newValue }
    }
}

extension NutritionPlateDraft {
    /// Logs the plate and consumes the offline scans staged on it whose food
    /// is still there, in one transaction: both or neither.
    func save(consuming library: BarcodeLibrary, scope: String) -> [FoodEntry]? {
        let ids = library.staged(scope: scope, foods: Set(rows.map(\.food.id)))
        guard !ids.isEmpty else { return save() }
        let entries = try? library.consume(ids) {
            guard let entries = save() else { throw BarcodeLibrary.NotLogged() }
            return entries
        }
        // A failed log keeps them staged, for the next try.
        if entries != nil { library.unstage(scope: scope) }
        return entries
    }
}
