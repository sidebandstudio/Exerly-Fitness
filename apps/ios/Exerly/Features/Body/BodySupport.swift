import ExerlyCore
import SwiftUI

/// Weights, changes and energy as the weight screens write them.
enum BodyFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// A trend or converted weight, to 0.1 in `unit`.
    static func weight(_ kilograms: Double, _ unit: MassUnit, withUnit: Bool = true) -> String {
        let text = number(Mass.kg(kilograms).value(in: unit))
        return withUnit ? "\(text) \(unit.rawValue)" : text
    }

    /// A reading as entered when it was entered in `unit` (up to 0.01), converted to 0.1 otherwise.
    static func reading(_ mass: Mass, _ unit: MassUnit, withUnit: Bool = true) -> String {
        let text = mass.unit == unit
            ? mass.value.formatted(.number.precision(.fractionLength(1...2)))
            : number(mass.value(in: unit))
        return withUnit ? "\(text) \(unit.rawValue)" : text
    }

    /// "+0.4 lb", "−1.2 lb" or "0.0 lb", with a true minus sign.
    static func change(_ kilograms: Double, _ unit: MassUnit, digits: Int = 1, suffix: String = "") -> String {
        let value = Mass.kg(kilograms).value(in: unit)
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : ""
        return "\(sign)\(number(abs(rounded), digits: digits)) \(unit.rawValue)\(suffix)"
    }

    /// Spoken form: "down 1.2 pounds".
    static func spokenChange(_ kilograms: Double, _ unit: MassUnit, digits: Int = 1) -> String {
        let value = Mass.kg(kilograms).value(in: unit)
        let scale = pow(10, Double(digits))
        let rounded = (abs(value) * scale).rounded() / scale
        guard rounded > 0 else { return "no change" }
        return "\(value < 0 ? "down" : "up") \(number(rounded, digits: digits)) \(unitName(unit))"
    }

    static func spokenWeight(_ kilograms: Double, _ unit: MassUnit) -> String {
        "\(number(Mass.kg(kilograms).value(in: unit))) \(unitName(unit))"
    }

    /// A reading spoken as `reading` writes it.
    static func spokenReading(_ mass: Mass, _ unit: MassUnit) -> String {
        "\(reading(mass, unit, withUnit: false)) \(unitName(unit))"
    }

    static func unitName(_ unit: MassUnit) -> String { unit == .pounds ? "pounds" : "kilograms" }

    /// Energy to the nearest 10 kcal, grouped.
    static func kcal(_ value: Double) -> String {
        ((value / 10).rounded() * 10).formatted(.number.precision(.fractionLength(0)))
    }

    /// "Today", "Yesterday", or "Tue, Oct 6"; with the year when it isn't this year.
    static func day(_ date: LocalDate, today: LocalDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: -1) { return "Yesterday" }
        var style = date.year == today.year
            ? Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
            : Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.timeZone = BodyDates.utc
        return BodyDates.anchor(date).formatted(style)
    }

    /// "Oct 6", for chart tables.
    static func shortDate(_ date: LocalDate) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = BodyDates.utc
        return BodyDates.anchor(date).formatted(style)
    }

    /// A weigh-in as VoiceOver reads its row: the day and time, the weight,
    /// any body fat and where it came from, so two on one day differ.
    static func spokenWeighIn(_ entry: WeightEntry, day: String, unit: MassUnit, timeZone: TimeZone) -> String {
        var parts = ["Weigh-in, \(day) at \(time(entry.at, in: timeZone))", spokenReading(entry.weight, unit)]
        if let fat = entry.bodyFat { parts.append("\(number(fat)) percent body fat") }
        if entry.source == .appleHealth { parts.append("from Apple Health") }
        return parts.joined(separator: ", ")
    }

    static func time(_ instant: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return instant.formatted(style)
    }

    static func message(_ error: Error) -> String {
        if case NutritionStore.StoreError.invalid(let problems) = error {
            let text = problems.joined(separator: "; ")
            return text.prefix(1).uppercased() + text.dropFirst() + "."
        }
        if case NutritionStore.StoreError.notFound = error { return "This weigh-in no longer exists." }
        return error.localizedDescription
    }
}

/// Date-only values for charts and pickers: noon UTC on the local date, read
/// back with a UTC calendar, so no time zone can move a day.
enum BodyDates {
    static let utc = TimeZone(identifier: "UTC")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    static func anchor(_ date: LocalDate) -> Date {
        calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))!
    }

    static func date(_ anchor: Date) -> LocalDate { LocalDate(anchor, in: utc) }
}

/// The last estimates computed, so a screen redrawn without new data doesn't
/// run the filter again. The inputs are compared, not the store's identity.
@MainActor
final class BodyEstimates {
    static let shared = BodyEstimates()
    private var key: Key?
    private var value: [EnergyBalance.Estimate] = []

    private struct Key: Equatable {
        let days: [EnergyBalance.Day]
        let prior: [Double]
    }

    func estimates(_ store: NutritionStore, through today: LocalDate) -> [EnergyBalance.Estimate] {
        guard let first = store.weights.map(\.date).min(), first <= today else { return [] }
        let days = store.energyBalanceDays(from: first, through: today)
        let basis = store.plans.first?.basis
        let key = Key(days: days, prior: basis.map { [$0.expenditure, $0.expenditureError] } ?? [])
        if key != self.key {
            value = EnergyBalance.estimate(days, prior: basis.map { (mean: $0.expenditure, error: $0.expenditureError) })
            self.key = key
        }
        return value
    }
}

/// Weigh-ins that earlier versions saved through the old daily-weight API,
/// including setup's first weight, brought into ExerlyCore once per launch.
@MainActor
enum LegacyWeighIns {
    private static var finished: Set<String> = []
    private static var running: Set<String> = []

    static func importIfNeeded(_ workspace: TrainingWorkspace, timeZone: TimeZone) async {
        let account = workspace.accountID
        let legacy = SyncEngine.shared
        guard !finished.contains(account), !running.contains(account), legacy.isConfigured(for: account) else { return }
        running.insert(account)
        defer { running.remove(account) }
        // Only after this device has the server's weigh-ins, so a copy edited on
        // another device is never replaced by the old reading.
        await workspace.synchronize()
        guard let sync = workspace.sync, sync.state == .idle, sync.lastSyncedAt != nil else { return }
        var readings: [LegacyWeighIn] = []
        var end = legacy.today
        // The old API serves 400 days at a time; stop at a window with nothing in it.
        for _ in 0..<10 {
            guard let start = end.adding(days: -399),
                  let rows = try? await legacy.weights(from: start.rawValue, to: end.rawValue),
                  legacy.isConfigured(for: account) else { return }
            let found = rows.compactMap { row -> LegacyWeighIn? in
                guard row.exists, let kilograms = row.weight_kg, let date = LocalDate(row.entry_date) else { return nil }
                return LegacyWeighIn(date: date, kilograms: kilograms, bodyFat: row.body_fat_pct)
            }
            readings += found
            guard !found.isEmpty, let previous = start.adding(days: -1) else { break }
            end = previous
        }
        do {
            if try workspace.nutrition.importLegacyWeights(readings, accountID: account, timeZone: timeZone) > 0 {
                Task { await workspace.synchronize() }
            }
            finished.insert(account)
        } catch { /* Kept for the next launch. */ }
    }

    /// Deleting an imported weigh-in deletes the old day's reading too, so the
    /// next import, here or on another device, doesn't bring it back.
    static func forget(_ entry: WeightEntry, accountID: String) async {
        let legacy = SyncEngine.shared
        guard legacy.isConfigured(for: accountID),
              let rows = try? await legacy.weights(from: "2000-01-01", to: "2100-12-31", cachedOnly: true),
              let row = rows.first(where: { row in
                  LocalDate(row.entry_date).map { NutritionStore.legacyWeightID(accountID: accountID, date: $0) } == entry.id
              }) else { return }
        _ = try? legacy.deleteWeight(row)
    }
}
