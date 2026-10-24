import Foundation

/// Workout history from Hevy's and Strong's CSV exports, as finished
/// sessions for `TrainingStore.importSessions`. PARITY I13. The formats are
/// recognised by their headers:
/// - Hevy: `title`, `start_time` ("22 Dec 2025, 08:00"), `end_time`,
///   `description`, `exercise_title`, `superset_id`, `exercise_notes`,
///   `set_index`, `set_type`, `weight_kg` or `weight_lbs`, `reps`,
///   `distance_km` or `distance_miles`, `duration_seconds`, `rpe`.
/// - Strong: `Date` ("2025-04-29 12:00:00"), `Workout Name`, `Duration (sec)`
///   or `Duration` ("1h 5m"), `Exercise Name`, `Set Order`, `Weight (kg)`,
///   `Weight (lbs)` or `Weight`, `Reps`, `RPE`, `Distance (meters)`, `(km)`,
///   `(miles)` or `Distance`, `Seconds`, `Notes`, `Workout Notes`, and in
///   newer files `Workout #`. Commas, semicolons or tabs.
public enum WorkoutImport {
    public enum Source: String, Sendable, Hashable {
        case hevy, strong
    }

    public struct Result: Sendable {
        public var source: Source
        /// Finished sessions whose IDs come from the file, so importing it again adds nothing.
        public var sessions: [WorkoutSession]
        /// How each exercise name in the file was matched.
        public var matched: [String: ExerciseID]
        /// Names that matched no exercise, with their number of sets. They are
        /// left out: map them, then parse again before importing.
        public var unmatched: [String: Int]
        /// Sets left out, and why.
        public var skipped: [String]
        /// What the file didn't say, and what was assumed.
        public var assumptions: [String]
        /// Sets of each exercise name in the file, matched or not.
        public var setCounts: [String: Int] = [:]
        /// Names the person chose to leave out, with their number of sets.
        public var leftOut: [String: Int] = [:]
        /// Rows that aren't sets, such as Strong's rest timers.
        public var restTimers = 0
        /// How weights, distances and times were read, one sentence each.
        public var units: [String] = []
        /// True when weights have no unit in the file and were read in the given one.
        public var weightUnitAssumed = false
    }

    public enum ImportError: Error, Equatable {
        /// Not a Hevy or Strong export: the headers found.
        case unrecognized([String])
    }

    static let namespace = UUID(uuidString: "5B0E7C1D-2F4A-4C8B-9E36-7A1D0F2B8C45")!

    /// A workout's ID from its source and its start to the minute, as the file
    /// writes it: the files have no time zone, so the same file gives the same
    /// IDs in whatever zone it's read. `ordinal` tells apart workouts starting
    /// in the same minute, in the file's order.
    static func sessionID(source: String, start: Date, in timeZone: TimeZone, ordinal: Int) -> UUID {
        UUID(named: "\(source)/local/\(localMinute(start, in: timeZone))/\(ordinal)", in: namespace)
    }

    /// The minute `date` shows on a clock in `timeZone`, counted from 1970.
    static func localMinute(_ date: Date, in timeZone: TimeZone) -> Int {
        Int(((date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))) / 60).rounded(.down))
    }

    /// Reads an export. Its times have no zone, so they are read in `timeZone`;
    /// weights without a unit are taken in `unit`. `mapping` names the
    /// exercise for any name, ahead of the built-in matching.
    public static func parse(_ text: String, timeZone: TimeZone, unit: MassUnit, library: ExerciseLibrary,
                             mapping: [String: ExerciseID] = [:], leftOut: Set<String> = []) throws -> Result {
        let rows = csv(text)
        guard let header = rows.first else { throw ImportError.unrecognized([]) }
        let columns = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces), $0) }, uniquingKeysWith: { a, _ in a })
        let records = rows.dropFirst().filter { $0.contains { !$0.isEmpty } }.map { row in
            Record(values: row, columns: columns)
        }
        let format: Format
        if columns["exercise_title"] != nil && columns["start_time"] != nil {
            format = .hevy
        } else if columns["Exercise Name"] != nil && columns["Set Order"] != nil && columns["Date"] != nil {
            format = .strong
        } else {
            throw ImportError.unrecognized(header)
        }
        var result = Result(source: format.source, sessions: [], matched: [:], unmatched: [:], skipped: [], assumptions: [])
        let units = format.units(columns, unit: unit, assumptions: &result.assumptions)
        result.weightUnitAssumed = units.weight != nil && result.assumptions.contains { $0.hasPrefix("Weights have no unit") }
        if let weight = units.weight {
            result.units.append(result.weightUnitAssumed ? "Weights read in \(units.weightUnit.rawValue): the file doesn't name a unit"
                                : "Weights in \(units.weightUnit.rawValue), from the \u{201C}\(weight)\u{201D} column")
        }
        if let distance = units.distance {
            let name = units.metres == 1 ? "metres" : units.metres == 1000 ? "km" : "miles"
            result.units.append(distance == "Distance" ? "Distances read in \(name): the file doesn't name a unit"
                                : "Distances in \(name), from the \u{201C}\(distance)\u{201D} column")
        }
        result.units.append("Times read in \(timeZone.identifier): the file has no time zone")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Rows grouped into workouts, in the file's order.
        var starts: [Int: Int] = [:]
        var order: [String] = []
        var workouts: [String: [Record]] = [:]
        for record in records {
            let key = format.workoutKey(record)
            if workouts[key] == nil { order.append(key) }
            workouts[key, default: []].append(record)
        }
        for key in order {
            let rows = workouts[key]!
            let first = rows[0]
            guard let start = format.start(first, timeZone: timeZone) else {
                result.skipped.append("A workout with an unreadable date, \(format.dateText(first)), with \(rows.count) rows")
                continue
            }
            // Neither app's export has a workout ID, so a workout is known by its
            // start, to the minute: correcting its title or end in the app and
            // exporting again updates it rather than adding it twice.
            let minute = Self.localMinute(start, in: timeZone)
            let ordinal = starts[minute, default: 0]
            starts[minute] = ordinal + 1
            let sessionID = Self.sessionID(source: format.source.rawValue, start: start, in: timeZone, ordinal: ordinal)
            var exercises: [PerformedExercise] = []
            var supersets: [String: UUID] = [:]
            var previousName: String?
            for record in rows {
                let name = format.exerciseName(record)
                guard let kind = format.kind(record) else { result.restTimers += 1; continue }
                result.setCounts[name, default: 0] += 1
                if leftOut.contains(name) {
                    result.leftOut[name, default: 0] += 1
                    continue
                }
                guard let id = match(name, library: library, mapping: mapping), let exercise = library.exercise(id) else {
                    result.unmatched[name, default: 0] += 1
                    continue
                }
                result.matched[name] = id
                let effort = Effort(reps: record.int(format.reps), load: units.load(record), duration: format.duration(record),
                                    distance: units.distance(record))
                var set = PerformedSet(kind: kind, efforts: [effort], rir: record.double(format.rpe).map(PerformedSet.rir(fromRPE:)))
                if exercises.isEmpty || previousName != name {
                    let index = exercises.count
                    let group = format.superset(record).map { group in
                        supersets[group] ?? { supersets[group] = UUID(named: "\(sessionID)/superset/\(group)", in: namespace); return supersets[group]! }()
                    }
                    exercises.append(PerformedExercise(id: UUID(named: "\(sessionID)/\(index)", in: namespace), exerciseID: id,
                                                       notes: format.exerciseNotes(record), supersetID: group))
                }
                previousName = name
                let last = exercises.count - 1
                set.id = UUID(named: "\(exercises[last].id)/\(exercises[last].sets.count)", in: namespace)
                set.completedAt = start
                guard set.isLoggable(for: exercise) else {
                    result.skipped.append("\(name) on \(LocalDate(start, in: timeZone)): a set without what \(exercise.name) records")
                    continue
                }
                exercises[last].sets.append(set)
            }
            exercises.removeAll { $0.sets.isEmpty }
            guard !exercises.isEmpty else { continue }
            // Sets are spread evenly from the start to the end.
            let count = exercises.reduce(0) { $0 + $1.sets.count }
            let end = max(format.end(first, start: start, timeZone: timeZone) ?? start, start.addingTimeInterval(Double(count) * 60))
            var done = 0
            for e in exercises.indices {
                for s in exercises[e].sets.indices {
                    done += 1
                    exercises[e].sets[s].completedAt = start.addingTimeInterval(end.timeIntervalSince(start) * Double(done) / Double(count))
                        .roundedToMilliseconds
                }
            }
            var session = WorkoutSession(name: format.workoutName(first), startedAt: start.roundedToMilliseconds,
                                         endedAt: end.roundedToMilliseconds, timeZone: timeZone, bodyweight: nil, exercises: exercises)
            session.id = sessionID
            session.notes = format.workoutNotes(first)
            result.sessions.append(session)
        }
        return result
    }

    // MARK: Matching

    /// Common Hevy and Strong names whose words differ from the library's.
    static let known: [String: ExerciseID] = [
        "squat barbell": "back-squat", "bent over row barbell": "barbell-row", "bicep curl barbell": "barbell-curl",
        "bicep curl dumbbell": "dumbbell-curl", "bicep curl cable": "cable-curl", "hammer curl dumbbell": "hammer-curl",
        "overhead press barbell": "overhead-press", "shoulder press dumbbell": "seated-dumbbell-shoulder-press",
        "seated overhead press dumbbell": "seated-dumbbell-shoulder-press", "shoulder press machine": "machine-shoulder-press",
        "triceps pushdown cable": "triceps-pushdown", "triceps pushdown": "triceps-pushdown", "skullcrusher barbell": "skull-crusher",
        "skullcrusher ez bar": "skull-crusher", "lateral raise dumbbell": "dumbbell-lateral-raise", "lateral raise cable": "cable-lateral-raise",
        "face pull cable": "face-pull", "face pull": "face-pull", "seated row cable": "seated-cable-row", "seated cable row": "seated-cable-row",
        "lying leg curl machine": "lying-leg-curl", "seated leg curl machine": "seated-leg-curl", "leg extension machine": "leg-extension",
        "hip thrust barbell": "barbell-hip-thrust", "standing calf raise machine": "standing-calf-raise", "calf raise standing": "standing-calf-raise",
        "seated calf raise machine": "seated-calf-raise", "chest fly dumbbell": "dumbbell-fly", "chest fly cable": "cable-fly",
        "cable fly crossovers": "cable-fly", "triceps dip": "dip", "chest dip": "dip", "shrug barbell": "barbell-shrug",
        "shrug dumbbell": "dumbbell-shrug", "hanging leg raise": "hanging-leg-raise", "leg raise hanging": "hanging-leg-raise",
        "pull up assisted": "assisted-pull-up", "dip assisted": "assisted-dip", "romanian deadlift dumbbell": "dumbbell-romanian-deadlift",
        "goblet squat kettlebell": "goblet-squat", "goblet squat dumbbell": "goblet-squat",
    ]

    static let equipmentWords: [String: Equipment] = [
        "barbell": .barbell, "dumbbell": .dumbbell, "cable": .cable, "machine": .machine, "kettlebell": .kettlebell,
        "smith machine": .smithMachine, "ez bar": .ezBar, "trap bar": .trapBar, "band": .resistanceBand, "bodyweight": .bodyweight,
    ]

    /// The exercise for a name: `mapping`, then the names above, then a
    /// library exercise whose name or alias has the same words, with or
    /// without the equipment in parentheses ("Bench Press (Barbell)" is
    /// "Barbell Bench Press"). Nil rather than a guess.
    public static func match(_ name: String, library: ExerciseLibrary, mapping: [String: ExerciseID] = [:]) -> ExerciseID? {
        if let id = mapping[name], library.exercise(id) != nil { return id }
        let all = ExerciseLibrary.tokens(name)
        if let id = known[all.joined(separator: " ")], library.exercise(id) != nil { return id }
        let base = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let qualifier = name.range(of: #"\(([^)]*)\)"#, options: .regularExpression)
            .map { ExerciseLibrary.tokens(String(name[$0])).joined(separator: " ") }
        func words(_ text: String) -> Set<String> { Set(ExerciseLibrary.tokens(text)) }
        let named = { (exercise: Exercise, query: Set<String>) in
            ([exercise.name] + exercise.aliases).contains { words($0) == query }
        }
        if let exercise = library.exercises.first(where: { named($0, Set(all)) }) { return exercise.id }
        let equipment = qualifier.flatMap { equipmentWords[$0] }
        return library.exercises.first { exercise in
            named(exercise, words(base)) && (qualifier == nil || equipment.map(exercise.equipment.contains) == true)
        }?.id
    }

    // MARK: Formats

    struct Record {
        var values: [String]
        var columns: [String: Int]

        func text(_ column: String?) -> String {
            guard let column, let index = columns[column], index < values.count else { return "" }
            return values[index].trimmingCharacters(in: .whitespaces)
        }

        func double(_ column: String?) -> Double? {
            Double(text(column).replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
        }

        func int(_ column: String?) -> Int? {
            double(column).flatMap { $0 > 0 && $0 < 10000 ? Int($0.rounded()) : nil }
        }
    }

    struct Units {
        var weight: String?
        var weightUnit: MassUnit
        var distance: String?
        var metres: Double

        func load(_ record: Record) -> Mass? { record.double(weight).flatMap { $0 > 0 ? Mass($0, weightUnit) : nil } }
        func distance(_ record: Record) -> Double? { record.double(distance).flatMap { $0 > 0 ? $0 * metres : nil } }
    }

    enum Format {
        case hevy, strong

        var source: Source { self == .hevy ? .hevy : .strong }
        var reps: String { self == .hevy ? "reps" : "Reps" }
        var rpe: String { self == .hevy ? "rpe" : "RPE" }

        func units(_ columns: [String: Int], unit: MassUnit, assumptions: inout [String]) -> Units {
            func first(_ names: [String]) -> String? { names.first { columns[$0] != nil } }
            if self == .hevy {
                let weight = first(["weight_kg", "weight_lbs"])
                let distance = first(["distance_km", "distance_miles", "distance_meters"])
                return Units(weight: weight, weightUnit: weight == "weight_lbs" ? .pounds : .kilograms, distance: distance,
                             metres: distance == "distance_miles" ? 1609.344 : distance == "distance_meters" ? 1 : 1000)
            }
            var units = Units(weight: first(["Weight (kg)", "Weight (lbs)", "Weight"]), weightUnit: unit,
                              distance: first(["Distance (meters)", "Distance (km)", "Distance (miles)", "Distance"]), metres: 1)
            switch units.weight {
            case "Weight (kg)": units.weightUnit = .kilograms
            case "Weight (lbs)": units.weightUnit = .pounds
            case "Weight": assumptions.append("Weights have no unit in this file, so they were read in \(unit == .kilograms ? "kg" : "lb").")
            default: break
            }
            switch units.distance {
            case "Distance (km)": units.metres = 1000
            case "Distance (miles)": units.metres = 1609.344
            case "Distance":
                units.metres = unit == .kilograms ? 1000 : 1609.344
                assumptions.append("Distances have no unit in this file, so they were read in \(unit == .kilograms ? "km" : "miles").")
            default: break
            }
            return units
        }

        func workoutKey(_ record: Record) -> String {
            switch self {
            case .hevy: [record.text("title"), record.text("start_time"), record.text("end_time")].joined(separator: "|")
            case .strong: record.text("Workout #").isEmpty ? record.text("Date") + "|" + record.text("Workout Name")
                : "#" + record.text("Workout #") + "|" + record.text("Date")
            }
        }

        func dateText(_ record: Record) -> String { record.text(self == .hevy ? "start_time" : "Date") }

        func date(_ text: String, timeZone: TimeZone) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            for pattern in self == .hevy ? ["d MMM yyyy, HH:mm", "d MMM yyyy, HH:mm:ss"] : ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                formatter.dateFormat = pattern
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }

        func start(_ record: Record, timeZone: TimeZone) -> Date? { date(dateText(record), timeZone: timeZone) }

        func end(_ record: Record, start: Date, timeZone: TimeZone) -> Date? {
            if self == .hevy { return date(record.text("end_time"), timeZone: timeZone) }
            if let seconds = record.double("Duration (sec)"), seconds > 0 { return start.addingTimeInterval(seconds) }
            // "1h 5m", "45m" or "30s".
            var seconds = 0.0
            for part in record.text("Duration").split(separator: " ") {
                guard let value = Double(part.dropLast()) else { continue }
                switch part.last {
                case "h": seconds += value * 3600
                case "m": seconds += value * 60
                case "s": seconds += value
                default: break
                }
            }
            return seconds > 0 ? start.addingTimeInterval(seconds) : nil
        }

        func workoutName(_ record: Record) -> String {
            let name = record.text(self == .hevy ? "title" : "Workout Name")
            return name.isEmpty ? "Imported workout" : name
        }

        func workoutNotes(_ record: Record) -> String { record.text(self == .hevy ? "description" : "Workout Notes") }
        func exerciseName(_ record: Record) -> String { record.text(self == .hevy ? "exercise_title" : "Exercise Name") }
        func exerciseNotes(_ record: Record) -> String { record.text(self == .hevy ? "exercise_notes" : "Notes") }

        func superset(_ record: Record) -> String? {
            let group = self == .hevy ? record.text("superset_id") : ""
            return group.isEmpty ? nil : group
        }

        func duration(_ record: Record) -> Double? {
            record.double(self == .hevy ? "duration_seconds" : "Seconds").flatMap { $0 > 0 ? $0 : nil }
        }

        /// The set's kind; nil for a row that isn't a set, such as a rest timer.
        func kind(_ record: Record) -> SetKind? {
            if self == .hevy {
                return switch record.text("set_type").lowercased() {
                case "warmup": .warmUp
                case "failure": .failure
                case "dropset": .drop
                default: .standard
                }
            }
            let order = record.text("Set Order").uppercased()
            if Int(order) != nil { return .standard }
            return switch order {
            case "W": .warmUp
            case "D": .drop
            case "F": .failure
            default: nil
            }
        }
    }

    // MARK: CSV

    /// Rows of fields, with quotes, doubled quotes and line breaks in quotes.
    /// The delimiter is a comma, semicolon or tab, whichever the header uses most.
    static func csv(_ text: String) -> [[String]] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let headerLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let counts = [";", ",", "\t"].map { mark in (mark, headerLine.filter { String($0) == mark }.count) }
        let delimiter = Character(counts.max { $0.1 < $1.1 || ($0.1 == $1.1 && $1.0 == ",") }?.0 ?? ",")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
