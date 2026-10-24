import Foundation
import Testing
@testable import ExerlyCore

@Suite struct TrainingHistoryTests {
    let library = Fixture.library

    var sessions: [WorkoutSession] {
        [
            Fixture.session(days: 0, [("back-squat", [Fixture.set(5, 60, kind: .warmUp), Fixture.set(5, 100, rir: 2), Fixture.set(5, 100, rir: 1)])]),
            Fixture.session(days: 2, [("back-squat", [Fixture.set(3, 110, rir: 2), Fixture.set(8, 90, rir: 0)])]),
            Fixture.session(days: 4, [("back-squat", [Fixture.set(5, 105, rir: 1), Fixture.set(5, 105, done: false)])]),
        ]
    }

    @Test func sortsSessionsAndFindsTheLastPerformance() throws {
        let history = TrainingHistory(sessions: sessions.reversed(), library: library)
        #expect(history.sessions.map(\.startedAt) == sessions.map(\.startedAt))

        let last = try #require(history.lastPerformance(of: "back-squat"))
        #expect(last.sets.first?.primary.load == .kg(105))

        let beforeThird = try #require(history.lastPerformance(of: "back-squat", before: Fixture.instant(days: 4)))
        #expect(beforeThird.sets.first?.primary.load == .kg(110))
        #expect(history.lastPerformance(of: "deadlift") == nil)
    }

    @Test func listsOnlyCountingSetsInOrder() {
        let history = TrainingHistory(sessions: sessions, library: library)
        let sets = history.sets(of: "back-squat")
        #expect(sets.map(\.set.primary.load) == [.kg(100), .kg(100), .kg(110), .kg(90), .kg(105)])
        #expect(sets.allSatisfy { $0.bodyweight == .kg(80) })
        let ranged = history.sets(of: "back-squat", from: LocalDate("2026-10-07"), through: LocalDate("2026-10-07"))
        #expect(ranged.count == 2)
    }

    @Test func computesEveryExerciseExportStatistic() throws {
        let history = TrainingHistory(sessions: sessions, library: library)
        let stats = try #require(history.statistics(of: "back-squat"))
        #expect(stats.totalSets == 5)
        #expect(stats.totalReps == 26)
        #expect(stats.bestSetReps == 8)
        #expect(stats.totalVolume == 500 + 500 + 330 + 720 + 525)
        #expect(stats.bestSetVolume == 720)
        #expect(stats.heaviestLoad == .kg(110))
        // Best e1RM: 110 kg x 3 at RIR 2 -> 5 reps to failure -> 110 * 36 / 32.
        #expect(close(stats.estimatedOneRepMax?.kilograms, 110 * 36 / 32))
        let e1rm = 110.0 * 36 / 32
        #expect(close(stats.estimatedThreeRepMax?.kilograms, e1rm * 34 / 36))
        #expect(close(stats.estimatedTenRepMax?.kilograms, e1rm * 27 / 36))
        #expect(stats.totalDuration == 0)
        #expect(stats.bestSetDuration == 0)
    }

    @Test func statisticsForTimedAndCardioExercises() throws {
        let plank = PerformedSet(efforts: [Effort(duration: 45)], completedAt: Fixture.instant())
        let longer = PerformedSet(efforts: [Effort(duration: 70)], completedAt: Fixture.instant())
        let run = PerformedSet(efforts: [Effort(duration: 1500, distance: 5000)], completedAt: Fixture.instant())
        let history = TrainingHistory(sessions: [Fixture.session([("plank", [plank, longer]), ("running", [run])])], library: library)

        let plankStats = try #require(history.statistics(of: "plank"))
        #expect(plankStats.totalDuration == 115)
        #expect(plankStats.bestSetDuration == 70)
        #expect(plankStats.estimatedOneRepMax == nil)
        #expect(plankStats.totalSets == 2)

        let runStats = try #require(history.statistics(of: "running"))
        #expect(runStats.totalDistance == 5000)
        #expect(runStats.bestSetDistance == 5000)
        #expect(history.statistics(of: "deadlift") == nil)
    }

    @Test func dropSetsUseTheirTopSetForStrengthAndAllEffortsForVolume() throws {
        var drop = Fixture.set(8, 100, kind: .drop)
        drop.efforts.append(Effort(reps: 4, load: .kg(80)))
        let history = TrainingHistory(sessions: [Fixture.session([("barbell-bench-press", [drop])])], library: library)
        let stats = try #require(history.statistics(of: "barbell-bench-press"))
        #expect(stats.totalReps == 12)
        #expect(stats.bestSetVolume == 1120)
        #expect(stats.heaviestLoad == .kg(100))
        // Top set of a drop set is treated as taken to failure.
        #expect(close(stats.estimatedOneRepMax?.kilograms, 100 * 36 / 29))
    }

    @Test func bestE1RMPerSessionFormsATrend() {
        let history = TrainingHistory(sessions: sessions, library: library)
        let trend = history.oneRepMaxTrend(of: "back-squat")
        #expect(trend.map(\.date.description) == ["2026-10-05", "2026-10-07", "2026-10-09"])
        // Session 1: 100 x 5 @ RIR 2 -> 7 reps to failure.
        #expect(close(trend[0].oneRepMax.kilograms, 100 * 36 / 30))
        #expect(close(trend[1].oneRepMax.kilograms, 110 * 36 / 32))
        #expect(close(trend[2].oneRepMax.kilograms, 105 * 36 / 31))
    }

    @Test func detectsRecordsAgainstEarlierSessionsOnly() throws {
        let history = TrainingHistory(sessions: sessions, library: library)
        let first = history.sessions[0]
        #expect(history.records(in: first).isEmpty, "a first session sets no records")

        let second = history.sessions[1]
        let records = history.records(in: second)
        let kinds = Set(records.map(\.kind))
        // 90 x 8 also beats the 5 reps done earlier at 90 kg or more.
        #expect(kinds == [.heaviestLoad, .oneRepMax, .setVolume, .repsAtLoad])
        let heaviest = try #require(records.first { $0.kind == .heaviestLoad })
        #expect(heaviest.value == 110)
        #expect(heaviest.previous == 100)
        #expect(heaviest.setID == second.exercises[0].sets[0].id)

        let third = history.sessions[2]
        let repRecords = history.records(in: third).filter { $0.kind == .repsAtLoad }
        // 105 x 5: earlier best at 105 kg or more was 3 reps (at 110).
        #expect(repRecords.count == 1)
        #expect(repRecords.first?.value == 5)
        #expect(repRecords.first?.previous == 3)
        #expect(repRecords.first?.load == .kg(105))
    }

    @Test func headlinesKeepOneRecordPerExerciseByMeaning() throws {
        func record(_ kind: PersonalRecord.Kind, _ exercise: ExerciseID) -> PersonalRecord {
            PersonalRecord(kind: kind, exerciseID: exercise, sessionID: UUID(), setID: UUID(), value: 2, previous: 1)
        }
        // Lighter but more reps: no heavier weight, so the estimated 1RM leads.
        let lighter = [record(.setVolume, "deadlift"), record(.repsAtLoad, "deadlift"), record(.oneRepMax, "deadlift")]
        #expect(PersonalRecord.headlines(lighter).map(\.kind) == [.oneRepMax])
        let mixed = [record(.oneRepMax, "back-squat"), record(.repsAtLoad, "pull-up"), record(.heaviestLoad, "back-squat"),
                     record(.setVolume, "pull-up"), record(.duration, "plank")]
        let headlines = PersonalRecord.headlines(mixed)
        #expect(headlines.map(\.exerciseID) == ["back-squat", "pull-up", "plank"])
        #expect(headlines.map(\.kind) == [.heaviestLoad, .repsAtLoad, .duration])
        #expect(PersonalRecord.headlines([]).isEmpty)
        // Every kind in Kind has a place in the order.
        let all = PersonalRecord.Kind.allCases.map { record($0, "deadlift") }
        #expect(PersonalRecord.headlines(all.reversed()).first?.kind == .heaviestLoad)
    }

    @Test func recordsIgnoreWarmUpsAndUnknownBodyweight() {
        let earlier = Fixture.session(days: 0, [("pull-up", [Fixture.set(8)])])
        let later = Fixture.session(days: 1, bodyweight: nil, [("pull-up", [Fixture.set(12), Fixture.set(20, kind: .warmUp)])])
        let history = TrainingHistory(sessions: [earlier, later], library: library)
        let records = history.records(in: history.sessions[1])
        #expect(!records.contains { $0.kind == .oneRepMax || $0.kind == .heaviestLoad || $0.kind == .setVolume })
    }

    @Test func weeklyMuscleVolumeOverARange() throws {
        let history = TrainingHistory(sessions: sessions, library: library)
        let weeks = history.weeklyMuscleVolume(firstWeekday: .monday)
        let week = try #require(weeks[LocalDate("2026-10-05")!])
        #expect(week[.quads]?.sets == 5)
        #expect(week[.adductors]?.sets == 2.5)
    }

    /// PARITY A03: volume per muscle over any range of local dates counts only
    /// the sessions in it, with synergists at half credit.
    @Test func muscleVolumeOverADateRangeCountsOnlyItsSessions() {
        let history = TrainingHistory(sessions: sessions, library: library)
        let wednesday = history.muscleVolume(from: LocalDate("2026-10-07")!, through: LocalDate("2026-10-07")!)
        #expect(wednesday[.quads] == MuscleVolume(sets: 2, tonnage: Tonnage(resistance: 3 * 110 + 8 * 90)))
        #expect(wednesday[.adductors]?.sets == 1 && wednesday[.adductors]?.tonnage.resistance == 525)
        let all = history.muscleVolume(from: LocalDate("2026-10-05")!, through: LocalDate("2026-10-09")!)
        #expect(all[.quads]?.sets == 5, "The warm-up and the set not done don't count")
        #expect(history.muscleVolume(from: LocalDate("2026-10-10")!, through: LocalDate("2026-10-31")!).isEmpty)
    }
}
