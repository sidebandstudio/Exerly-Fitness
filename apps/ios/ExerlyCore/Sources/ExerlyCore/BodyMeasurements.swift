import Foundation

/// A place on the body measured with a tape, or a visual body-fat estimate.
/// Raw values are the measurement types of the API's `/api/measurements`.
public enum BodySite: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case neck, shoulders, chest, bust, waist, hips
    case leftBicep = "left_bicep", rightBicep = "right_bicep"
    case leftForearm = "left_forearm", rightForearm = "right_forearm"
    case leftWrist = "left_wrist", rightWrist = "right_wrist"
    case leftThigh = "left_thigh", rightThigh = "right_thigh"
    case leftCalf = "left_calf", rightCalf = "right_calf"
    case leftAnkle = "left_ankle", rightAnkle = "right_ankle"
    /// Sites from before limbs had sides, kept for their history.
    case arms, thighs, calves
    case bodyFat = "body_fat"

    public enum Group: String, Sendable, Hashable, CaseIterable {
        case torso, arms, legs, bodyFat
    }

    public var id: String { rawValue }

    /// The sites a new entry offers: top to bottom, left before right, body fat last.
    public static let entry = allCases.filter { !$0.isLegacy }

    public var isLegacy: Bool { self == .arms || self == .thighs || self == .calves }

    /// A circumference in centimetres; otherwise a body-fat percentage.
    public var isLength: Bool { self != .bodyFat }

    public var group: Group {
        switch self {
        case .neck, .shoulders, .chest, .bust, .waist, .hips: .torso
        case .leftBicep, .rightBicep, .leftForearm, .rightForearm, .leftWrist, .rightWrist, .arms: .arms
        case .leftThigh, .rightThigh, .leftCalf, .rightCalf, .leftAnkle, .rightAnkle, .thighs, .calves: .legs
        case .bodyFat: .bodyFat
        }
    }

    public enum Side: String, Sendable, Hashable { case left, right }

    /// Which side a limb site is on; nil for the torso, older sites and body fat.
    public var side: Side? {
        rawValue.hasPrefix("left_") ? .left : rawValue.hasPrefix("right_") ? .right : nil
    }

    /// "Bicep" for both biceps; the name itself for sites without a side.
    public var limb: String {
        guard let side else { return name }
        let part = rawValue.dropFirst(side.rawValue.count + 1)
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    /// "Waist", "Left bicep".
    public var name: String {
        switch self {
        case .bodyFat: "Body fat"
        case .leftBicep, .leftForearm, .leftWrist, .leftThigh, .leftCalf, .leftAnkle: "Left \(limb.lowercased())"
        case .rightBicep, .rightForearm, .rightWrist, .rightThigh, .rightCalf, .rightAnkle: "Right \(limb.lowercased())"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Values a person could have, in centimetres or percent.
    public var range: ClosedRange<Double> { isLength ? 5...300 : 2...70 }
}

public enum LengthUnit: String, Sendable, Codable, Hashable, CaseIterable {
    case centimetres = "cm"
    case inches = "in"

    /// Inches for people who weigh in pounds, centimetres for kilograms.
    public init(_ mass: MassUnit) { self = mass == .pounds ? .inches : .centimetres }

    public func value(fromCentimetres centimetres: Double) -> Double {
        self == .inches ? centimetres / USUnits.centimetersPerInch : centimetres
    }

    public func centimetres(_ value: Double) -> Double {
        self == .inches ? value * USUnits.centimetersPerInch : value
    }
}

/// One saved measurement.
public struct BodyMeasurementReading: Sendable, Hashable, Identifiable {
    public var id: String
    public var site: BodySite
    public var date: LocalDate
    /// Centimetres, or a percentage for body fat.
    public var value: Double

    public init(id: String, site: BodySite, date: LocalDate, value: Double) {
        self.id = id
        self.site = site
        self.date = date
        self.value = value
    }
}

/// What the measurement screens show and what their entry sheet saves.
public enum BodyMeasurements {
    /// A value as the screens show it: in `unit` for a length, to 0.1.
    public static func display(_ value: Double, site: BodySite, unit: LengthUnit) -> Double {
        ((site.isLength ? unit.value(fromCentimetres: value) : value) * 10).rounded() / 10
    }

    /// A shown value back in centimetres, or percent for body fat.
    public static func stored(_ value: Double, site: BodySite, unit: LengthUnit) -> Double {
        site.isLength ? unit.centimetres(value) : value
    }

    /// Each site's newest reading, by date and then by order in `readings`.
    public static func latest(_ readings: [BodyMeasurementReading]) -> [BodySite: BodyMeasurementReading] {
        var latest: [BodySite: BodyMeasurementReading] = [:]
        for reading in readings where latest[reading.site].map({ reading.date >= $0.date }) ?? true {
            latest[reading.site] = reading
        }
        return latest
    }

    /// A site's readings, oldest first.
    public static func history(_ readings: [BodyMeasurementReading], site: BodySite) -> [BodyMeasurementReading] {
        readings.enumerated().filter { $0.element.site == site }
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
    }

    /// The newest reading minus the one before it, in stored units; nil with fewer than two.
    public static func change(_ readings: [BodyMeasurementReading], site: BodySite) -> Double? {
        let history = history(readings, site: site)
        guard history.count >= 2 else { return nil }
        return history[history.count - 1].value - history[history.count - 2].value
    }

    /// What an entry sheet saves: each value typed in `unit` that differs from
    /// the one it was prefilled with, as shown, in stored units. Blank fields
    /// and untouched prefills save nothing.
    public static func changes(entered: [BodySite: Double], prefilled: [BodySite: Double],
                               unit: LengthUnit) -> [BodySite: Double] {
        var changes: [BodySite: Double] = [:]
        for (site, value) in entered {
            let shown = (value * 10).rounded() / 10
            if let before = prefilled[site], (before * 10).rounded() == shown * 10 { continue }
            changes[site] = stored(shown, site: site, unit: unit)
        }
        return changes
    }

    /// What's wrong with a stored value, in words; nil when it's fine.
    public static func problem(_ value: Double, site: BodySite, unit: LengthUnit) -> String? {
        guard !(value.isFinite && site.range.contains(value)) else { return nil }
        let low = display(site.range.lowerBound, site: site, unit: unit)
        let high = display(site.range.upperBound, site: site, unit: unit)
        func text(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...1))) }
        return "\(site.name) must be \(text(low)) to \(text(high)) \(site.isLength ? unit.rawValue : "%")"
    }
}
