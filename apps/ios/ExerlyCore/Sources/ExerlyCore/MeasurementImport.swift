import Foundation

/// A body measurement from another app's export, for the account's
/// measurements. Its ID comes from the source, date and site, so importing
/// the file again adds nothing, and a value corrected in the file updates it.
public struct ImportedMeasurement: Sendable, Codable, Hashable {
    /// Lowercase, as the app's measurements use them.
    public var clientID: String
    public var site: BodySite
    /// Centimetres, or a percentage for body fat.
    public var value: Double
    public var date: LocalDate
    public var source: ImportSource

    public init(site: BodySite, value: Double, date: LocalDate, source: ImportSource) {
        clientID = UUID(named: "\(source.rawValue)/measurement/\(date)/\(site.rawValue)", in: MeasurementImport.namespace)
            .uuidString.lowercased()
        self.site = site
        self.value = value
        self.date = date
        self.source = source
    }

    /// The measurement as the log keeps it once imported.
    public var state: MeasurementState {
        MeasurementState(type: site.rawValue, value: value, unit: site == .bodyFat ? "%" : "cm", date: date.description,
                         source: "imported", note: "From \(source.name)")
    }
}

/// Everything a measurement in the log says: a change to any of it, such as
/// moving it to another day, is an edit, and an import leaves an edited
/// measurement as it is.
public struct MeasurementState: Sendable, Codable, Hashable {
    public var type: String
    /// To four decimal places, as the server keeps it.
    public var value: Double
    public var unit: String
    public var date: String
    public var source: String?
    public var note: String?
    /// Deleted from the log, with this as its last state.
    public var deleted: Bool

    public init(type: String, value: Double, unit: String, date: String, source: String?, note: String?, deleted: Bool = false) {
        self.type = type
        self.value = (value * 10_000).rounded() / 10_000
        self.unit = unit
        self.date = date
        self.source = source
        self.note = note
        self.deleted = deleted
    }
}

/// A measurement an import changes to the file's value, from the value it had.
public struct ImportedMeasurementChange: Sendable, Codable, Hashable {
    /// The measurement with its new value.
    public var measurement: ImportedMeasurement
    public var from: Double

    public init(measurement: ImportedMeasurement, from: Double) {
        self.measurement = measurement
        self.from = from
    }

    /// The measurement as it was before the change.
    public var earlier: ImportedMeasurement {
        var earlier = measurement
        earlier.value = from
        return earlier
    }

    /// The change that puts the earlier value back.
    var reversed: ImportedMeasurementChange {
        var earlier = measurement
        earlier.value = from
        return ImportedMeasurementChange(measurement: earlier, from: measurement.value)
    }
}

/// Where imported measurements are kept: the app's measurement log, which
/// isn't in the account's document database. `HistoryImporter` saves to it
/// alongside the documents, all or nothing, and undoes it with them.
@MainActor
public protocol ImportedMeasurementStore: AnyObject {
    /// The states of those of these the log has, deleted ones included, by client ID.
    func states(_ clientIDs: [String]) -> [String: MeasurementState]
    /// Saves all of them or, on any error, none. One deleted from the log is
    /// brought back with its own identity rather than created again.
    func add(_ measurements: [ImportedMeasurement]) throws
    /// Changes each to its new value while it's still exactly as it was before
    /// the change, all or none; one edited in any way since is kept.
    func update(_ changes: [ImportedMeasurementChange]) throws -> (updated: Int, kept: Int)
    /// Removes those still exactly as imported, all or none, and keeps any edited since.
    func remove(_ measurements: [ImportedMeasurement]) throws -> (removed: Int, kept: Int)
    /// Takes back a removal that couldn't be finished: the deletions are
    /// cancelled if they haven't been sent, or reversed if they have. All or none.
    func restore(_ measurements: [ImportedMeasurement]) throws
}

/// Body measurements and weigh-ins from MacroFactor's Body Metrics sheet,
/// Hevy's measurement_data.csv and Strong's measurement files.
public enum MeasurementImport {
    static let namespace = UUID(uuidString: "3F6C2A91-7D4E-4B0A-9C55-1E8B2D7A6F30")!

    /// What a measurements file held.
    public struct Result: Sendable {
        public var source: ImportSource
        public var weights: [WeightEntry] = []
        public var measurements: [ImportedMeasurement] = []
        /// Columns or types that aren't a site Exerly keeps, with how many values.
        public var unknown: [String: Int] = [:]
        public var assumptions: [String] = []
        public var units: [String] = []
        public var skipped: [String] = []
    }

    public enum Length: Sendable { case cm, inches, mm }

    /// The site a header or type names, ignoring case, punctuation, a unit and
    /// the order of side and part ("Bicep (Left)" is the left bicep). Nil for
    /// one Exerly doesn't keep, such as "abdomen".
    public static func site(_ name: String) -> BodySite? {
        let words = words(name).filter { !unitWords.contains($0) }
        let side = words.contains("left") ? "left" : words.contains("right") ? "right" : nil
        let part = words.filter { $0 != "left" && $0 != "right" }.joined(separator: " ")
        let parts: [String: String] = [
            "neck": "neck", "shoulder": "shoulders", "shoulders": "shoulders", "chest": "chest", "bust": "bust", "waist": "waist",
            "hip": "hips", "hips": "hips", "bicep": "bicep", "biceps": "bicep", "arm": "bicep", "upper arm": "bicep",
            "forearm": "forearm", "wrist": "wrist", "thigh": "thigh", "thighs": "thigh", "calf": "calf", "calves": "calf",
            "ankle": "ankle", "body fat": "body_fat", "fat": "body_fat", "fat percent": "body_fat", "body fat percent": "body_fat",
            "visual body fat": "body_fat", "visual body fat assessment": "body_fat", "body fat percentage": "body_fat",
        ]
        guard let base = parts[part] else { return nil }
        if let side, ["bicep", "forearm", "wrist", "thigh", "calf", "ankle"].contains(base) { return BodySite(rawValue: "\(side)_\(base)") }
        switch base {
        case "bicep": return .arms
        case "thigh": return .thighs
        case "calf": return .calves
        case "forearm", "wrist", "ankle": return nil
        default: return BodySite(rawValue: base)
        }
    }

    /// Whether a header or type is body weight.
    static func isWeight(_ name: String) -> Bool {
        let rest = words(name).filter { !unitWords.contains($0) }
        return rest == ["weight"] || rest == ["body", "weight"] || rest == ["bodyweight"]
    }

    /// The length unit a header or unit cell names.
    static func length(_ text: String) -> Length? {
        let words = Set(words(text))
        if words.contains("cm") { return .cm }
        if words.contains("mm") { return .mm }
        if !words.isDisjoint(with: ["in", "inch", "inches"]) { return .inches }
        return nil
    }

    static let unitWords: Set<String> = ["cm", "mm", "in", "inch", "inches", "kg", "kgs", "lb", "lbs", "pct", "percent"]

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "%", with: " percent ")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .map { $0 == "pct" ? "percent" : $0 }
            // "fat_percent" and "body fat (%)" read alike.
            .filter { !$0.isEmpty }
    }

    static func centimetres(_ value: Double, _ unit: Length) -> Double {
        switch unit {
        case .cm: value
        case .mm: value / 10
        case .inches: value * 2.54
        }
    }

    /// A value that can be a measurement: positive, and a body fat under 100 %.
    static func plausible(_ value: Double, site: BodySite) -> Bool {
        value.isFinite && value > 0 && value <= (site == .bodyFat ? 100 : 1000)
    }

    // MARK: Hevy

    /// Hevy's measurement_data.csv (Profile → Settings → Export & Import Data →
    /// Export Measurements): one row a day, `date` ("23 Oct 2023, 00:00"),
    /// `weight_kg` or `weight_lbs`, `fat_percent`, and a column per site
    /// named with `_cm` or `_in`.
    static func hevy(_ text: String, timeZone: TimeZone) -> Result {
        var result = Result(source: .hevy)
        let rows = WorkoutImport.csv(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return result }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        result.units.append("Times read in \(timeZone.identifier): the file has no time zone")
        let weightColumn = header.firstIndex { $0 == "weight_kg" || $0 == "weight_lbs" }
        if let weightColumn { result.units.append("Weights in \(header[weightColumn] == "weight_kg" ? "kg" : "lb"), from the \u{201C}\(header[weightColumn])\u{201D} column") }
        if header.contains(where: { $0.hasSuffix("_cm") }) { result.units.append("Lengths in cm, from the column names") }
        if header.contains(where: { $0.hasSuffix("_in") }) { result.units.append("Lengths in inches, from the column names, kept in cm") }
        for (number, row) in rows.dropFirst().enumerated() where row.contains(where: { !$0.isEmpty }) {
            func cell(_ index: Int) -> String { index < row.count ? row[index].trimmingCharacters(in: .whitespaces) : "" }
            let dateText = header.firstIndex(of: "date").map(cell) ?? ""
            var at: Date?
            for pattern in ["d MMM yyyy, HH:mm", "d MMM yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] where at == nil {
                formatter.dateFormat = pattern
                at = formatter.date(from: dateText)
            }
            guard let at else {
                result.skipped.append("Row \(number + 2): an unreadable date, \(dateText)")
                continue
            }
            let date = LocalDate(at, in: timeZone)
            var bodyFat: Double?
            for (index, name) in header.enumerated() where name != "date" && index != weightColumn {
                guard let value = Double(cell(index).replacingOccurrences(of: ",", with: ".")), value > 0 else { continue }
                if name == "fat_percent" {
                    bodyFat = value
                    continue
                }
                let unit: Length = name.hasSuffix("_in") ? .inches : .cm
                guard let site = site(name), site != .bodyFat else {
                    result.unknown[name, default: 0] += 1
                    continue
                }
                let cm = centimetres(value, unit)
                if plausible(cm, site: site) { result.measurements.append(ImportedMeasurement(site: site, value: cm, date: date, source: .hevy)) }
            }
            if let weightColumn, let value = Double(cell(weightColumn)), value > 0 {
                let mass = Mass(value, header[weightColumn] == "weight_kg" ? .kilograms : .pounds)
                result.weights.append(WeightEntry(id: UUID(named: "hevy/weight/\(date)", in: namespace), at: at.roundedToMilliseconds,
                                                  date: date, weight: mass, bodyFat: bodyFat, source: .hevy))
            } else if let bodyFat, plausible(bodyFat, site: .bodyFat) {
                result.measurements.append(ImportedMeasurement(site: .bodyFat, value: bodyFat, date: date, source: .hevy))
            }
        }
        return result
    }

    // MARK: Strong

    /// Strong's measurement export (Settings → Export Measurements): one CSV a
    /// measurement, each row `Date`, `Measurement Type` (or `Measurement`),
    /// `Value`, `Unit` and `Source`.
    static func strong(_ texts: [String], timeZone: TimeZone, unit: MassUnit) -> Result {
        var result = Result(source: .strong)
        result.units.append("Units from each row's Unit column")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var assumedLength = false
        for text in texts {
            let rows = WorkoutImport.csv(text)
            guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { continue }
            func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
            guard let dateColumn = column(["date"]), let typeColumn = column(["measurement type", "measurement", "type"]),
                  let valueColumn = column(["value"]) else { continue }
            let unitColumn = column(["unit"])
            for (number, row) in rows.dropFirst().enumerated() where row.contains(where: { !$0.isEmpty }) {
                func cell(_ index: Int?) -> String {
                    guard let index, index < row.count else { return "" }
                    return row[index].trimmingCharacters(in: .whitespaces)
                }
                var at: Date?
                for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] where at == nil {
                    formatter.dateFormat = pattern
                    at = formatter.date(from: cell(dateColumn))
                }
                guard let at, let value = Double(cell(valueColumn).replacingOccurrences(of: ",", with: ".")), value > 0 else {
                    result.skipped.append("A \(cell(typeColumn)) row \(number + 2) without a readable date or value")
                    continue
                }
                let date = LocalDate(at, in: timeZone)
                let type = cell(typeColumn), unitText = cell(unitColumn).lowercased()
                if isWeight(type) {
                    let mass = Mass(value, unitText.hasPrefix("lb") ? .pounds : unitText.hasPrefix("kg") ? .kilograms : unit)
                    result.weights.append(WeightEntry(id: UUID(named: "strong/weight/\(date)/\(at.timeIntervalSince1970)", in: namespace),
                                                      at: at.roundedToMilliseconds, date: date, weight: mass, source: .strong))
                    continue
                }
                guard let site = site(type) else {
                    result.unknown[type, default: 0] += 1
                    continue
                }
                var cm = value
                if site != .bodyFat {
                    let stated = length(unitText)
                    if stated == nil { assumedLength = true }
                    cm = centimetres(value, stated ?? (unit == .kilograms ? .cm : .inches))
                }
                if plausible(cm, site: site) { result.measurements.append(ImportedMeasurement(site: site, value: cm, date: date, source: .strong)) }
            }
        }
        if assumedLength {
            result.assumptions.append("Some lengths have no unit, so they were read in \(unit == .kilograms ? "cm" : "inches").")
        }
        return result
    }
}
