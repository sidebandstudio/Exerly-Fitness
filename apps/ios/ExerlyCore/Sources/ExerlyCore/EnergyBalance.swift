import Foundation

/// Trend weight and expenditure from weigh-ins and logged intake. See
/// docs/design/007-nutrition.md, which records the error measured against
/// simulated people.
///
/// A Kalman filter and Rauch–Tung–Striebel smoother over four hidden states:
/// - `W`: weight without the day's water and gut contents, in kilograms;
/// - `E`: expenditure in logged kilocalories a day;
/// - `A`: the water and gut deviation, which the scale adds to `W`;
/// - `D`: how far the intake of a stretch of unlogged days sits from its
///   reference, in kcal a day.
///
/// Each day `W` changes by intake minus `E`, divided by the energy density;
/// `E` drifts slowly; `A` decays toward zero. Expenditure is in the units the
/// person logs, so a steady under-logger still gets targets that work.
///
/// An unlogged day's intake is unknown: its stretch's reference plus `D`, plus
/// the day's own spread. The reference is the recent logged average; before
/// anything is logged it is `E` itself, so weight change in those weeks moves
/// the trend through `D` and says nothing about expenditure. Each stretch
/// starts its own `D`, and logged days never inform it.
public enum EnergyBalance {
    public struct Parameters: Sendable, Hashable {
        /// Kilocalories per kilogram of tissue change.
        public var energyDensity = 7700.0
        /// Daily drift of expenditure, in kcal.
        public var expenditureDrift = 15.0
        /// How much expenditure changes per kilogram of tissue gained or lost,
        /// in kcal a day (Hall et al., 2011).
        public var expenditurePerKilogram = 22.0
        /// Daily unexplained change in weight, in kg.
        public var weightDrift = 0.01
        /// Water and gut swings, in kg, and how much of today's carries to tomorrow.
        public var water = 0.5
        public var waterPersistence = 0.8
        /// Scale error of one reading, in kg.
        public var scale = 0.15
        /// How far one unlogged day's intake may be from its stretch's level, in kcal.
        public var unloggedIntake = 600.0
        /// How far a stretch of unlogged days may sit from the recent logged
        /// average or, before any logging, from expenditure, in kcal a day.
        public var unloggedBalance = 500.0
        /// How much that offset drifts a day within a stretch, in kcal.
        public var unloggedDrift = 30.0

        public init() {}
    }

    public struct Day: Sendable, Hashable {
        public var date: LocalDate
        /// Logged energy for a complete or fasting day; nil when the day isn't complete.
        public var intake: Double?
        /// Readings that day, in kilograms.
        public var weights: [Double]

        public init(date: LocalDate, intake: Double?, weights: [Double]) {
            self.date = date
            self.intake = intake
            self.weights = weights
        }
    }

    public struct Estimate: Sendable, Hashable {
        public var date: LocalDate
        /// Trend weight, in kilograms, with one standard deviation.
        public var trend: Double
        public var trendError: Double
        /// Expenditure, in logged kcal a day, with one standard deviation.
        public var expenditure: Double
        public var expenditureError: Double
        /// The day's mean reading, if any.
        public var weight: Double?
        public var intake: Double?
    }

    /// Smoothed estimates for every day from the first weigh-in on.
    /// `prior` is an expenditure guess (a formula's) and its standard deviation;
    /// without one it starts at 31 kcal per kilogram, ±600.
    public static func estimate(_ days: [Day], prior: (mean: Double, error: Double)? = nil,
                                parameters p: Parameters = Parameters()) -> [Estimate] {
        let sorted = days.sorted { $0.date < $1.date }
        guard let firstIndex = sorted.firstIndex(where: { !$0.weights.isEmpty }) else { return [] }
        // Fill gaps so every calendar day is a step.
        var series: [Day] = []
        for day in sorted[firstIndex...] {
            while let last = series.last, last.date.adding(days: 1) < day.date {
                series.append(Day(date: last.date.adding(days: 1), intake: nil, weights: []))
            }
            if series.last?.date == day.date {
                series[series.count - 1].weights += day.weights
                if let intake = day.intake { series[series.count - 1].intake = intake }
            } else {
                series.append(day)
            }
        }
        let firstWeight = mean(series[0].weights)!
        let start = prior ?? (31 * firstWeight, 600)
        let balance = p.unloggedBalance * p.unloggedBalance
        var x = Vector([firstWeight, start.mean, 0, 0])
        var P = Matrix.diagonal([p.water * p.water, start.error * start.error, p.water * p.water, balance])
        // Expenditure follows weight: each day it moves by `expenditurePerKilogram`
        // times the day's tissue change, (intake − E) / density.
        let coupling = p.expenditurePerKilogram / p.energyDensity
        let intakeEffect = Vector([1 / p.energyDensity, coupling, 0, 0])
        let waterNoise = p.water * p.water * (1 - p.waterPersistence * p.waterPersistence)

        var filtered: [(x: Vector, P: Matrix)] = []
        var predicted: [(x: Vector, P: Matrix, F: Matrix)] = []
        var recentIntake: [Double] = []
        for (index, day) in series.enumerated() {
            var F = Matrix.identity
            if index > 0 {
                // Predict across the previous day's intake.
                let previous = series[index - 1]
                F[0, 1] = -1 / p.energyDensity
                F[1, 1] = 1 - coupling
                F[2, 2] = p.waterPersistence
                var intake = 0.0
                var intakeVariance = 0.0
                if let logged = previous.intake {
                    intake = logged
                    recentIntake = Array((recentIntake + [logged]).suffix(7))
                } else {
                    // The stretch's reference plus D, give or take the day's spread.
                    if let recent = mean(recentIntake) {
                        intake = recent
                    } else {
                        // Before any logging the reference is E, so intake − E is D alone.
                        F[0, 1] = 0
                        F[1, 1] = 1
                    }
                    F[0, 3] = 1 / p.energyDensity
                    F[1, 3] = coupling
                    intakeVariance = p.unloggedIntake * p.unloggedIntake
                }
                var offsetNoise = p.unloggedDrift * p.unloggedDrift
                if day.intake == nil, previous.intake != nil {
                    // A new stretch of unlogged days starts with its own D.
                    F[3, 3] = 0
                    offsetNoise = balance
                }
                x = F * x + intakeEffect * intake
                P = F * P * F.transposed
                    + Matrix.diagonal([p.weightDrift * p.weightDrift, p.expenditureDrift * p.expenditureDrift, waterNoise,
                                       offsetNoise])
                    + intakeEffect.outer(intakeEffect) * intakeVariance
            }
            predicted.append((x, P, F))
            if let reading = mean(day.weights) {
                // y = W + A, with the scale's error shrinking over several readings.
                let r = p.scale * p.scale / Double(day.weights.count)
                let innovation = reading - (x.w + x.a)
                let s = P[0, 0] + 2 * P[0, 2] + P[2, 2] + r
                let gain = Vector((0..<Matrix.size).map { P[$0, 0] + P[$0, 2] }) / s
                x += gain * innovation
                let h = Vector([1, 0, 1, 0])
                P = (Matrix.identity - gain.outer(h)) * P
                P = (P + P.transposed) * 0.5
            }
            filtered.append((x, P))
        }

        // Rauch–Tung–Striebel smoothing, backwards.
        var smoothed = filtered
        if series.count > 1 {
            for index in stride(from: series.count - 2, through: 0, by: -1) {
                let (xf, Pf) = filtered[index]
                let (xp, Pp, F) = predicted[index + 1]
                let gain = Pf * F.transposed * Pp.inverse
                let x = xf + gain * (smoothed[index + 1].x - xp)
                let P = Pf + gain * (smoothed[index + 1].P - Pp) * gain.transposed
                smoothed[index] = (x, (P + P.transposed) * 0.5)
            }
        }
        return series.indices.map { index in
            let (x, P) = smoothed[index]
            return Estimate(date: series[index].date, trend: x.w, trendError: max(0, P[0, 0]).squareRoot(),
                            expenditure: x.e, expenditureError: max(0, P[1, 1]).squareRoot(),
                            weight: mean(series[index].weights), intake: series[index].intake)
        }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

extension EnergyBalance {
    /// How much one day's readings move the trend on another day.
    public struct Influence: Sendable, Hashable {
        public var date: LocalDate
        /// The trend's change for each kilogram the day's mean reading changes.
        public var effect: Double
    }

    /// What the trend on `date` rests on: for each day with readings from
    /// `lookback` days before `date` through it, how far that trend moves per
    /// kilogram the day's readings move. The filter and smoother are linear in
    /// the readings, so each effect is exact. With a `prior`, the effects of
    /// all readings ever sum to 1. Older readings also act through
    /// expenditure, so an effect can be negative. Runs the estimate once per
    /// day counted; call it off the main thread.
    public static func influence(_ days: [Day], on date: LocalDate, lookback: Int = 28,
                                 prior: (mean: Double, error: Double)? = nil,
                                 parameters: Parameters = Parameters()) -> [Influence] {
        func trend(_ days: [Day]) -> Double? {
            estimate(days, prior: prior, parameters: parameters).first { $0.date == date }?.trend
        }
        guard let base = trend(days) else { return [] }
        let window = date.adding(days: -lookback)...date
        return days.indices.compactMap { index in
            guard window.contains(days[index].date), !days[index].weights.isEmpty else { return nil }
            var moved = days
            moved[index].weights = days[index].weights.map { $0 + 1 }
            return trend(moved).map { Influence(date: days[index].date, effect: $0 - base) }
        }
    }
}

extension NutritionStore {
    /// The days `EnergyBalance` needs, from this store's weigh-ins and log.
    /// Only complete days with food and fasting days count as known intake:
    /// a day marked complete with nothing logged is unknown, not a zero.
    public func energyBalanceDays(from start: LocalDate, through end: LocalDate) -> [EnergyBalance.Day] {
        guard start <= end else { return [] }
        var readings: [LocalDate: [Double]] = [:]
        for weight in weights where (start...end).contains(weight.date) {
            readings[weight.date, default: []].append(weight.weight.kilograms)
        }
        var energy: [LocalDate: Double] = [:]
        for entry in entries where (start...end).contains(entry.date) {
            energy[entry.date, default: 0] += entry.nutrients.energy
        }
        return (0...start.days(until: end)).map { offset in
            let date = start.adding(days: offset)
            let status = day(date).status
            let intake: Double? = switch status {
            case .complete: energy[date]
            case .fasting: energy[date] ?? 0
            default: nil
            }
            return EnergyBalance.Day(date: date, intake: intake, weights: readings[date] ?? [])
        }
    }
}

// MARK: Small fixed-size linear algebra
// Loops run in a fixed order so the API's JavaScript port gets the same numbers.

struct Vector: Sendable {
    var values: [Double]
    init(_ values: [Double]) { self.values = values }
    var w: Double { values[0] }
    var e: Double { values[1] }
    var a: Double { values[2] }
    static func + (l: Vector, r: Vector) -> Vector { Vector(zip(l.values, r.values).map(+)) }
    static func += (l: inout Vector, r: Vector) { l = l + r }
    static func - (l: Vector, r: Vector) -> Vector { Vector(zip(l.values, r.values).map(-)) }
    static func * (l: Vector, s: Double) -> Vector { Vector(l.values.map { $0 * s }) }
    static func / (l: Vector, s: Double) -> Vector { Vector(l.values.map { $0 / s }) }
    func outer(_ other: Vector) -> Matrix {
        var m = Matrix.zero
        for i in 0..<Matrix.size { for j in 0..<Matrix.size { m[i, j] = values[i] * other.values[j] } }
        return m
    }
}

/// A square matrix of the state's size, stored by rows.
struct Matrix: Sendable {
    static let size = 4
    var values: [Double]
    static var zero: Matrix { Matrix(values: Array(repeating: 0, count: size * size)) }
    static var identity: Matrix { diagonal(Array(repeating: 1, count: size)) }
    static func diagonal(_ entries: [Double]) -> Matrix {
        var m = zero
        for i in 0..<size { m[i, i] = entries[i] }
        return m
    }
    subscript(_ i: Int, _ j: Int) -> Double {
        get { values[i * Self.size + j] }
        set { values[i * Self.size + j] = newValue }
    }
    var transposed: Matrix {
        var m = Matrix.zero
        for i in 0..<Self.size { for j in 0..<Self.size { m[i, j] = self[j, i] } }
        return m
    }
    static func + (l: Matrix, r: Matrix) -> Matrix { Matrix(values: zip(l.values, r.values).map(+)) }
    static func - (l: Matrix, r: Matrix) -> Matrix { Matrix(values: zip(l.values, r.values).map(-)) }
    static func * (l: Matrix, s: Double) -> Matrix { Matrix(values: l.values.map { $0 * s }) }
    static func * (l: Matrix, r: Matrix) -> Matrix {
        var m = Matrix.zero
        for i in 0..<size {
            for j in 0..<size {
                var sum = 0.0
                for k in 0..<size { sum += l[i, k] * r[k, j] }
                m[i, j] = sum
            }
        }
        return m
    }
    static func * (l: Matrix, v: Vector) -> Vector {
        Vector((0..<size).map { i in
            var sum = 0.0
            for k in 0..<size { sum += l[i, k] * v.values[k] }
            return sum
        })
    }
    /// Gauss–Jordan elimination. Only covariances are inverted, and those are
    /// symmetric positive definite, so no pivoting is needed.
    var inverse: Matrix {
        var a = self
        var b = Matrix.identity
        let n = Self.size
        for c in 0..<n {
            let pivot = a[c, c]
            for j in 0..<n {
                a[c, j] /= pivot
                b[c, j] /= pivot
            }
            for r in 0..<n where r != c {
                let factor = a[r, c]
                for j in 0..<n {
                    a[r, j] -= factor * a[c, j]
                    b[r, j] -= factor * b[c, j]
                }
            }
        }
        return b
    }
}
