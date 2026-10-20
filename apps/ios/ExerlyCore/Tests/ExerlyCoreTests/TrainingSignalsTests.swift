import Foundation
import Testing
@testable import ExerlyCore

@Suite struct TrainingSignalsTests {
    /// The Friday of a simulated week, as the lifter's local date.
    static func friday(_ week: Int) -> LocalDate { LocalDate("2026-07-06")!.adding(days: week * 7 + 4) }

    static func profile(seed: Int, gain: Double, noise: Double, plateau: Int? = nil,
                        fatigue: ClosedRange<Int>? = nil) -> TrainingSimulator.Profile {
        var profile = TrainingSimulator.Profile(seed: UInt64(seed))
        profile.weeklyGain = gain
        profile.noise = noise
        profile.plateauFromWeek = plateau
        profile.fatigueWeeks = fatigue
        profile.unit = seed % 2 == 0 ? .kilograms : .pounds
        return profile
    }

    struct Rate: CustomStringConvertible {
        var hits = 0
        var trials = 0
        var value: Double { Double(hits) / Double(max(1, trials)) }
        var description: String { "\(hits)/\(trials)" }
    }

    /// Per lift at the end of week 15: stalls found on plateaued lifters, and
    /// false stalls on lifters still gaining.
    static func stallRates(seeds: Range<Int>, noise: Double) -> (found: Rate, falseOnProgress: Rate, slow: Rate) {
        var found = Rate(), falseAlarms = Rate(), slow = Rate()
        for seed in seeds {
            let cases: [(TrainingSimulator.Profile, Int)] = [
                (profile(seed: seed, gain: 0.008, noise: noise, plateau: 8), 0),
                (profile(seed: seed + 100_000, gain: 0.006, noise: noise), 1),
                (profile(seed: seed + 200_000, gain: 0.012, noise: noise), 1),
                (profile(seed: seed + 300_000, gain: 0.002, noise: noise), 2),
            ]
            for (profile, group) in cases {
                let result = TrainingSimulator.run(profile)
                let history = TrainingHistory(sessions: result.sessions, library: .bundled)
                for lift in TrainingSimulator.lifts {
                    let stalled = TrainingSignals.stall(of: lift.id, in: history, through: friday(15)) != nil
                    switch group {
                    case 0: found.trials += 1; if stalled { found.hits += 1 }
                    case 1: falseAlarms.trials += 1; if stalled { falseAlarms.hits += 1 }
                    default: slow.trials += 1; if stalled { slow.hits += 1 }
                    }
                }
            }
        }
        return (found, falseAlarms, slow)
    }

    /// Deload signals at the end of a two-week fatigue block, and false ones at
    /// the end of every week from week 5 for lifters who never tire.
    static func deloadRates(seeds: Range<Int>, noise: Double, drop: Double) -> (found: Rate, falseAlarms: Rate) {
        var found = Rate(), falseAlarms = Rate()
        for seed in seeds {
            var tired = profile(seed: seed, gain: 0.006, noise: noise, fatigue: 10...11)
            tired.fatigueDrop = drop
            let tiredHistory = TrainingHistory(sessions: TrainingSimulator.run(tired).sessions, library: .bundled)
            found.trials += 1
            if TrainingSignals.deload(in: tiredHistory, through: friday(11)) != nil { found.hits += 1 }
            let fresh = profile(seed: seed + 400_000, gain: [0.002, 0.006, 0.012][seed % 3], noise: noise)
            let freshHistory = TrainingHistory(sessions: TrainingSimulator.run(fresh).sessions, library: .bundled)
            for week in 5...15 {
                falseAlarms.trials += 1
                if TrainingSignals.deload(in: freshHistory, through: friday(week)) != nil { falseAlarms.hits += 1 }
            }
        }
        return (found, falseAlarms)
    }

    /// The rates recorded in docs/design/005-training-detectors.md, with room
    /// for the simulator's randomness. A drop means a regression.
    @Test func meetsTheRecordedRatesOnSimulatedLifters() {
        let bounds: [(noise: Double, stalls: Double, deloads: Double)] = [(0.015, 0.65, 0.9), (0.025, 0.5, 0.9), (0.04, 0.33, 0.75)]
        for bound in bounds {
            let stalls = Self.stallRates(seeds: 0..<30, noise: bound.noise)
            let deloads = Self.deloadRates(seeds: 0..<30, noise: bound.noise, drop: 0.07)
            print("Stalls, noise \(bound.noise): found \(stalls.found), false on progress \(stalls.falseOnProgress), "
                + "on 0.2 %/week \(stalls.slow)")
            print("Deload, noise \(bound.noise): found \(deloads.found), false \(deloads.falseAlarms)")
            #expect(stalls.found.value >= bound.stalls)
            #expect(stalls.falseOnProgress.value <= 0.02)
            #expect(deloads.found.value >= bound.deloads)
            #expect(deloads.falseAlarms.value <= 0.03)
        }
    }

    // MARK: Cases

    /// Sessions of one exercise, three a week, with a chosen e1RM path.
    func log(_ exercise: ExerciseID, weeks: Int, oneRepMax: (Int) -> Double, rir: Double? = 2) -> TrainingHistory {
        var sessions: [WorkoutSession] = []
        for index in 0..<(weeks * 3) {
            let day = Double(index / 3 * 7 + [0, 2, 4][index % 3])
            let load = (OneRepMax.load(forReps: 5 + (rir ?? 2), oneRepMax: oneRepMax(index)) / 2.5).rounded() * 2.5
            let set = PerformedSet(efforts: [Effort(reps: 5, load: .kg(load))], rir: rir, completedAt: Fixture.instant(days: day))
            sessions.append(Fixture.session(days: day, [(exercise, [set, set])]))
        }
        return TrainingHistory(sessions: sessions, library: .bundled)
    }

    var lastDay: LocalDate { LocalDate("2026-10-05")!.adding(days: 11 * 7 + 4) }

    @Test func aFlatLiftIsDiagnosedWithVerifiableEvidence() throws {
        let history = log("barbell-bench-press", weeks: 12, oneRepMax: { index in index < 12 ? 100 + Double(index) : 112 })
        let diagnosis = try #require(TrainingSignals.stall(of: "barbell-bench-press", in: history, through: lastDay))
        #expect(diagnosis.kind == .stall && diagnosis.title == "Barbell Bench Press has stalled")
        #expect(diagnosis.evidence.allSatisfy { $0.level == .personalData })
        let metric = try #require(diagnosis.evidence.compactMap(\.metric).first)
        guard case .verified = metric.verify(against: history) else {
            Issue.record("The diagnosis's own number should verify")
            return
        }
        #expect(TrainingSignals.stalls(in: history, through: lastDay).map(\.exerciseIDs) == [["barbell-bench-press"]])
    }

    @Test func evidenceSpeaksThePersonsUnit() throws {
        let history = log("barbell-bench-press", weeks: 12, oneRepMax: { index in index < 12 ? 100 + Double(index) : 112 })
        let kilograms = try #require(TrainingSignals.stall(of: "barbell-bench-press", in: history, through: lastDay))
        let pounds = try #require(TrainingSignals.stall(of: "barbell-bench-press", in: history, through: lastDay, unit: .pounds))
        #expect(kilograms.evidence[0].claim.contains(" kg"))
        #expect(pounds.evidence.allSatisfy { !$0.claim.contains(" kg") })
        #expect(pounds.evidence[0].claim.contains(" lb"))
        // Numbers convert as well as the label: about 2.2 lb to the kilogram.
        let around = { (claim: String) in Double(claim.components(separatedBy: "around ")[1].components(separatedBy: " ")[0]) ?? 0 }
        #expect(abs(around(pounds.evidence[0].claim) / around(kilograms.evidence[0].claim) - 2.204_622_62) < 0.01)
        // Machine-readable evidence stays in kilograms.
        #expect(pounds.evidence.compactMap(\.metric) == kilograms.evidence.compactMap(\.metric))
    }

    @Test func aProgressingLiftOrTooLittleDataIsNotAStall() {
        let rising = log("back-squat", weeks: 12, oneRepMax: { 140 * (1 + 0.004 * Double($0)) })
        #expect(TrainingSignals.stall(of: "back-squat", in: rising, through: lastDay) == nil)
        let short = log("back-squat", weeks: 2, oneRepMax: { _ in 140 })
        #expect(TrainingSignals.stall(of: "back-squat", in: short, through: LocalDate("2026-10-16")!) == nil)
    }

    @Test func aFallingLiftIsToldAsADropNotAsUnchanged() throws {
        let falling = log("barbell-bench-press", weeks: 12, oneRepMax: { 110 - Double($0) * 10 / 35 })
        let drop = try #require(TrainingSignals.stall(of: "barbell-bench-press", in: falling, through: lastDay))
        #expect(drop.title == "Barbell Bench Press has dropped")
        #expect(drop.summary == "Your Barbell Bench Press estimate has gone down over the last 7 weeks.")
        let flat = log("barbell-bench-press", weeks: 12, oneRepMax: { _ in 100 })
        let stall = try #require(TrainingSignals.stall(of: "barbell-bench-press", in: flat, through: lastDay))
        #expect(stall.summary == "Your Barbell Bench Press estimate hasn't improved for 7 weeks.")
    }

    @Test func aStallWithoutRIRSaysSo() throws {
        let history = log("deadlift", weeks: 12, oneRepMax: { _ in 180 }, rir: nil)
        let diagnosis = try #require(TrainingSignals.stall(of: "deadlift", in: history, through: lastDay))
        #expect(diagnosis.evidence[0].caveats.contains { $0.hasPrefix("RIR not recorded") })
    }

    /// Twelve weeks of three lifts, all falling 8 % in the last two weeks.
    func liftsFallingTogether() -> TrainingHistory {
        var sessions: [WorkoutSession] = []
        for index in 0..<36 {
            let day = Double(index / 3 * 7 + [0, 2, 4][index % 3])
            let factor = index >= 31 ? 0.92 : 1.0
            let maxes: [(ExerciseID, Double)] = [("barbell-bench-press", 100), ("back-squat", 140), ("deadlift", 170)]
            let exercises: [(ExerciseID, [PerformedSet])] = maxes.map { id, max in
                    let load = (OneRepMax.load(forReps: 7, oneRepMax: max * factor) / 2.5).rounded() * 2.5
                    return (id, [PerformedSet(efforts: [Effort(reps: 5, load: .kg(load))], rir: 2,
                                              completedAt: Fixture.instant(days: day))])
                }
            sessions.append(Fixture.session(days: day, exercises))
        }
        return TrainingHistory(sessions: sessions, library: .bundled)
    }

    @Test func liftsFallingTogetherSignalADeload() throws {
        let history = liftsFallingTogether()
        let diagnosis = try #require(TrainingSignals.deload(in: history, through: lastDay))
        #expect(diagnosis.kind == .deload)
        #expect(Set(diagnosis.exerciseIDs) == ["barbell-bench-press", "back-squat", "deadlift"])
        #expect(TrainingSignals.deload(in: history, through: lastDay.adding(days: -14)) == nil)
        let pounds = try #require(TrainingSignals.deload(in: history, through: lastDay, unit: .pounds))
        #expect(pounds.evidence.allSatisfy { $0.claim.contains(" lb") && !$0.claim.contains(" kg") })
    }
}
