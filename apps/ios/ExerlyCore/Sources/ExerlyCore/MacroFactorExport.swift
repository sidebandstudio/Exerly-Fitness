import Foundation

/// What a MacroFactor import read, and what it left out.
public struct MacroFactorReport: Sendable, Hashable {
    public struct Sheet: Sendable, Hashable {
        public var name: String
        /// What the sheet gave ("Food log, 120 rows"), or why it was left out.
        public var detail: String
        public var imported: Bool
    }

    public struct Skipped: Sendable, Hashable {
        public var sheet: String
        /// The row's number in its sheet; nil for a group, such as a plan version.
        public var row: Int?
        public var reason: String
    }

    public var sheets: [Sheet] = []
    public var skipped: [Skipped] = []
    /// Headers not understood, by sheet. Their cells were ignored.
    public var unknownColumns: [String: [String]] = [:]
    /// Headers understood but not imported, such as trend weight, by sheet.
    public var unusedColumns: [String: [String]] = [:]
    /// Exercise names that match nothing in Exerly's library, with their
    /// number of sets. Those sets were left out.
    public var unmappedExercises: [String: Int] = [:]
    /// Exercise names matched to Exerly's library, by name or by the
    /// person's choice, with their number of sets.
    public var mappedExercises: [String: ExerciseID] = [:]
    public var exerciseSets: [String: Int] = [:]
    /// Names the person chose to leave out, with their number of sets.
    public var leftOutExercises: [String: Int] = [:]
    /// What the file didn't say, and what was assumed instead.
    public var assumptions: [String] = []

    public init() {}
}

/// MacroFactor's data export (More → Data Management → Data Export, Quick or
/// Granular) read into Exerly documents. Nothing is saved here;
/// `MacroFactorImporter` previews and saves them. PARITY "Migration in".
///
/// Sheets are recognised by name or else by their columns, and columns by
/// header, ignoring case, spacing, punctuation and unit, with aliases. Names
/// come from docs/MACROFACTOR.md (the export's sheets as recorded by the
/// owner), MacroFactor's help centre ("Export Your Data") and the headers an
/// open-source parser of the export reads (github.com/chaotix345/macrofactor-mcp):
/// - Food log: `Date`, `Time` ("07:38 PM"), `Food Name`, `Serving Size`,
///   `Serving Qty`, `Serving Weight (g)`, `Calories (kcal)`, `Protein (g)`,
///   `Carbs (g)`, `Fat (g)` and nutrient columns.
/// - Calories & Macros and Micronutrients: `Date` and nutrient columns, as
///   one entry a day where the food log doesn't cover it.
/// - Scale Weight: `Date`, `Weight (kg)`, `Fat Percent`.
/// - Custom Foods, Favorites, Recipes: the food log's columns without a date.
/// - Nutrition Program Settings: `Program Update Date`, `Program Weekday`,
///   calories and macros, as manual plan versions; Weight Goals: `Goal`,
///   `Start Date`, `End Date`, `Goal Weight (kg)`, `Goal Rate per Week (%)`.
/// - Workouts: `Date`, `Workout`, `Workout Duration`, `Exercise`, `Set Type`,
///   `Weight (kg)`, `Reps`, `RIR`, `Duration`, `Distance short (m)`,
///   `Distance long (km)`.
/// - Fasting, Partial Logging and Food Log Notes: dates, flags and notes.
///
/// Every ID is a name-based UUID from the rows, so reading the same file
/// again gives the same documents, and a row repeated in two files is one.
public struct MacroFactorExport: Sendable {
    /// A day's status or notes from the export.
    public struct Day: Sendable, Hashable {
        public var date: LocalDate
        public var status: DayStatus?
        public var notes: String?
    }

    /// Custom foods, favorites and recipes, for the food library.
    public var foods: [Food] = []
    /// The food log's rows.
    public var entries: [FoodEntry] = []
    /// One unweighed entry for each day the export has totals for but no
    /// food log rows, so expenditure can use the day.
    public var dayTotals: [FoodEntry] = []
    public var days: [Day] = []
    public var weights: [WeightEntry] = []
    /// Manual plan versions, earliest first.
    public var plans: [NutritionPlan] = []
    /// Finished sessions, earliest first.
    public var sessions: [WorkoutSession] = []
    /// Body measurements, for the account's measurement log.
    public var measurements: [ImportedMeasurement] = []
    public var report = MacroFactorReport()

    /// The first and last day with food, a day status, a weigh-in or a workout.
    public var dateRange: ClosedRange<LocalDate>? {
        let dates = entries.map(\.date) + dayTotals.map(\.date) + days.map(\.date) + weights.map(\.date) + sessions.map(\.localDate)
            + measurements.map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }

    public var isEmpty: Bool {
        foods.isEmpty && entries.isEmpty && dayTotals.isEmpty && days.isEmpty && weights.isEmpty && plans.isEmpty && sessions.isEmpty
            && measurements.isEmpty
    }

    /// The meal of food log rows without a time, and of day totals.
    public static let mealWithoutTime = "MacroFactor"
    public static let dayTotalName = "MacroFactor day total"
    static let namespace = UUID(uuidString: "99CF0F44-6800-4596-B4E9-425A66879BEE")!

    static func id(_ name: String) -> UUID { UUID(named: "macrofactor/\(name)", in: namespace) }

    /// The ID of a library food, and of the logged food of the same name.
    static func foodID(_ name: String, brand: String?) -> String {
        id("food/\(MFColumns.key(name))|\(MFColumns.key(brand ?? ""))").uuidString
    }

    static func dayTotalID(_ date: LocalDate) -> UUID { id("day-total/\(date)") }

    /// Reads one or more exported files: .xlsx workbooks, or CSV files named
    /// after their sheet.
    /// `mapping` names the exercise for a name in the file, ahead of matching
    /// by name; the sets of names in `leftOut` are left out.
    public static func read(_ files: [(name: String, data: Data)], timeZone: TimeZone, unit: MassUnit,
                            library: ExerciseLibrary = .bundled, mapping: [String: ExerciseID] = [:], leftOut: Set<String> = [],
                            locale: Locale = .current, now: Date = Date()) throws -> MacroFactorExport {
        var sheets: [Spreadsheet.Sheet] = []
        for file in files {
            let name = (file.name as NSString).deletingPathExtension
            sheets += try Spreadsheet.read(file.data, name: name).sheets
        }
        return MacroFactorExport(Spreadsheet(sheets: sheets), timeZone: timeZone, unit: unit, library: library, mapping: mapping,
                                 leftOut: leftOut, locale: locale, now: now)
    }

    /// Maps a spreadsheet's sheets. Times have no zone, so they are read in
    /// `timeZone`. Weights without a unit are read in kilograms, as MacroFactor
    /// exports them; distances without one in `unit`'s system. Slashed dates
    /// that don't show their order follow `locale`.
    public init(_ spreadsheet: Spreadsheet, timeZone: TimeZone, unit: MassUnit, library: ExerciseLibrary = .bundled,
                mapping: [String: ExerciseID] = [:], leftOut: Set<String> = [], locale: Locale = .current, now: Date = Date()) {
        var reader = MFReader(timeZone: timeZone, unit: unit, library: library, locale: locale, now: now.roundedToMilliseconds)
        reader.mapping = mapping
        reader.leftOut = leftOut
        reader.read(spreadsheet)
        self = reader.export
    }

    init() {}
}

// MARK: - Reading

/// The fields the import looks for, each with the header words it accepts.
enum MFField: Hashable {
    case date, time, name, brand, meal, servingSize, servingQty, servingWeight, barcode
    case weight, bodyFat, fasting, partial, complete, status, notes
    case updateDate, weekday, goal, startDate, endDate, goalWeight, rate
    case workout, workoutDuration, exercise, setType, load, reps, rir, rpe, duration, side, exerciseNotes, workoutNotes
    case recipe, ingredient, yield, recipeServings
}

struct MFReader {
    enum Role: Equatable {
        case foodLog, customFoods, favorites, recipes, day, fasting, partial, foodNotes, program, weightGoals, workouts, workoutNotes
        case bodyMetrics
        case leftOut(String)

        var title: String {
            switch self {
            case .foodLog: "Food log"
            case .customFoods: "Custom foods"
            case .favorites: "Favorite foods"
            case .recipes: "Recipes"
            case .day: "Daily data"
            case .fasting: "Fasting days"
            case .partial: "Partially logged days"
            case .foodNotes: "Food log notes"
            case .program: "Nutrition program"
            case .weightGoals: "Weight goals"
            case .workouts: "Workouts"
            case .workoutNotes: "Workout notes"
            case .bodyMetrics: "Body measurements"
            case .leftOut(let reason): reason
            }
        }
    }

    /// A sheet with its header row read.
    struct Table {
        var sheet: String
        var headers: [Int: MFColumns.Header]
        var rows: [Spreadsheet.Row]
        var dateOrder: MFColumns.DateOrder = .monthFirst
        /// Set when slashed dates didn't show their order, so the locale's was used.
        var dateNote: String?
    }

    struct Columns {
        var fields: [MFField: Int] = [:]
        /// Nutrient columns with the factor to Exerly's unit.
        var nutrients: [(column: Int, nutrient: Nutrient, factor: Double)] = []
        /// Every distance column, with metres per unit.
        var distances: [(column: Int, metres: Double)] = []

        func has(_ field: MFField) -> Bool { fields[field] != nil }
        func value(_ field: MFField, _ row: Spreadsheet.Row) -> Spreadsheet.Value? { fields[field].flatMap { row[$0] } }
    }

    struct Flags {
        var fasting: Bool?
        var partial: Bool?
        var complete: Bool?
        var notes: String?
    }

    struct Goal {
        var start: LocalDate?
        var end: LocalDate?
        var goal: NutritionGoal
    }

    let timeZone: TimeZone
    let unit: MassUnit
    let library: ExerciseLibrary
    let locale: Locale
    let now: Date
    var mapping: [String: ExerciseID] = [:]
    var leftOut: Set<String> = []
    var export = MacroFactorExport()

    private var foods: [String: Food] = [:]
    private var foodOrder: [String] = []
    private var entries: [UUID: FoodEntry] = [:]
    private var entryOrder: [UUID] = []
    private var totals: [LocalDate: NutrientAmounts] = [:]
    private var flags: [LocalDate: Flags] = [:]
    private var weighIns: [WeightEntry] = []
    private var goals: [Goal] = []
    private var sessionIDs = Set<UUID>()
    private var workoutNotes: [(date: LocalDate, workout: String?, notes: String)] = []

    init(timeZone: TimeZone, unit: MassUnit, library: ExerciseLibrary, locale: Locale, now: Date) {
        self.timeZone = timeZone
        self.unit = unit
        self.library = library
        self.locale = locale
        self.now = now
    }

    mutating func read(_ spreadsheet: Spreadsheet) {
        // Foods first, so log rows link to them; weigh-ins before workouts, for bodyweight.
        let order: [Role] = [.customFoods, .favorites, .recipes, .foodLog, .day, .fasting, .partial, .foodNotes, .weightGoals,
                             .program, .workouts, .workoutNotes, .bodyMetrics]
        var tables: [(role: Role, table: Table)] = []
        for sheet in spreadsheet.sheets {
            let (role, table) = classify(sheet)
            if case .leftOut(let reason) = role {
                export.report.sheets.append(.init(name: sheet.name, detail: reason, imported: false))
            } else if let table {
                tables.append((role, table))
            } else {
                export.report.sheets.append(.init(name: sheet.name, detail: "\(role.title), empty", imported: false))
            }
        }
        for role in order {
            for (tableRole, table) in tables where tableRole == role {
                let used = read(table, as: role)
                export.report.sheets.append(.init(name: table.sheet, detail: "\(role.title), \(used) \(used == 1 ? "row" : "rows")",
                                                  imported: used > 0))
            }
        }
        finish()
    }

    // MARK: Sheets

    static let sheetRoles: [String: Role] = {
        var roles: [String: Role] = [:]
        func add(_ role: Role, _ names: [String]) { for name in names { roles[MFColumns.key(name)] = role } }
        add(.foodLog, ["food log", "food logs", "food entries", "food diary", "logged foods", "food log entries"])
        add(.customFoods, ["custom foods", "custom food", "my foods"])
        add(.favorites, ["favorites", "favourites", "favorite foods", "favourite foods"])
        add(.recipes, ["recipes", "recipe", "custom recipes", "my recipes"])
        add(.day, ["calories & macros", "calories and macros", "micronutrients", "scale weight", "weigh-ins", "weight",
                   "quick export", "summary", "progress", "day flags", "daily", "daily nutrition", "nutrition"])
        add(.fasting, ["fasting", "fasting days", "fasted days"])
        add(.partial, ["partial logging", "partially logged", "partially logged days", "partial days"])
        add(.foodNotes, ["food log notes", "food notes", "day notes"])
        add(.program, ["nutrition program settings", "nutrition program", "program settings", "nutrition targets"])
        add(.weightGoals, ["weight goals", "weight goal", "goals"])
        add(.workouts, ["workouts", "workout log", "workout logs", "workout history", "workout sets", "training log"])
        add(.workoutNotes, ["workout log notes", "workout notes"])
        add(.leftOut("Exerly builds recent foods from your food log."), ["history", "food history", "recent foods"])
        add(.leftOut("Exerly works out your trend weight from your weigh-ins."), ["weight trend", "trend weight"])
        add(.leftOut("Exerly works out your expenditure from your food log and weigh-ins."), ["expenditure"])
        add(.leftOut("Steps come from Apple Health."), ["steps"])
        add(.bodyMetrics, ["body metrics", "measurements", "body measurements"])
        add(.leftOut("Training programs aren't imported yet. Your workouts are."), ["training programs", "training program", "programs"])
        add(.leftOut("Your profile is set in Exerly."), ["user profile", "profile"])
        add(.leftOut("Workout settings stay in MacroFactor."), ["workout settings", "exercise settings"])
        add(.leftOut("Gym profiles aren't imported yet."), ["gym profiles", "gym profile"])
        add(.leftOut("Custom exercises aren't imported yet. Workouts that use them are listed as unmatched."), ["custom exercises"])
        add(.leftOut("Nutrient goals aren't imported yet."), ["micronutrient goals", "nutrient goals"])
        return roles
    }()

    /// A sheet's role, by name or else by its columns, and its table.
    func classify(_ sheet: Spreadsheet.Sheet) -> (Role, Table?) {
        let name = MFColumns.key(sheet.name)
        if name.hasPrefix("muscle groups") { return (.leftOut("Exerly works out sets and volume from your workouts."), nil) }
        if name.hasPrefix("exercises ") { return (.leftOut("Exerly works out exercise records from your workouts."), nil) }
        if let role = Self.sheetRoles[name] {
            if case .leftOut = role { return (role, nil) }
            return (role, table(sheet, role: role))
        }
        // By columns, for a renamed sheet or a CSV named after its file.
        for role in [Role.workouts, .program, .foodLog, .customFoods, .day] {
            guard let table = table(sheet, role: role) else { continue }
            let columns = columns(table, role: role)
            let hasNutrients = !columns.nutrients.isEmpty
            switch role {
            case .workouts where columns.has(.exercise) && columns.has(.date): return (role, table)
            case .program where columns.has(.weekday) && hasNutrients: return (role, table)
            case .foodLog where columns.has(.name) && columns.has(.date) && hasNutrients: return (role, table)
            case .customFoods where columns.has(.name) && !columns.has(.date) && hasNutrients: return (role, table)
            case .day where columns.has(.date) && (hasNutrients || columns.has(.weight) || columns.has(.fasting) || columns.has(.partial)):
                return (role, table)
            default: continue
            }
        }
        return (.leftOut("Not recognised as MacroFactor data."), nil)
    }

    /// The header is the first of the first ten rows with a header the role
    /// knows; the rows after it are data.
    func table(_ sheet: Spreadsheet.Sheet, role: Role) -> Table? {
        guard !sheet.rows.isEmpty else { return nil }
        let candidates = sheet.rows.prefix(10)
        let header = candidates.first { row in
            let table = Table(sheet: sheet.name, headers: headers(row), rows: [])
            let columns = columns(table, role: role)
            return !columns.fields.isEmpty || !columns.nutrients.isEmpty
        } ?? sheet.rows[0]
        var table = Table(sheet: sheet.name, headers: headers(header), rows: sheet.rows.filter { $0.number > header.number })
        let found = columns(table, role: role).fields
        if let date = [MFField.date, .updateDate, .startDate].lazy.compactMap({ found[$0] }).first {
            let order = MFColumns.dateOrder(table.rows.map { $0[date] }, locale: locale)
            table.dateOrder = order.order
            if !order.decided {
                table.dateNote = "Dates in \(sheet.name) such as 03/04 were read as \(order.order == .dayFirst ? "day/month" : "month/day"), "
                    + "as this device writes them."
            }
        }
        return table
    }

    private func headers(_ row: Spreadsheet.Row) -> [Int: MFColumns.Header] {
        var headers: [Int: MFColumns.Header] = [:]
        for (index, cell) in row.cells.enumerated() {
            if let text = MFColumns.text(cell) { headers[index] = MFColumns.Header(text) }
        }
        return headers
    }

    // MARK: Columns

    typealias Spec = (field: MFField, names: [String], units: [MFColumns.Unit?]?)

    static let dateNames = ["date", "day", "log date", "entry date", "logged date", "date logged", "logged on"]
    static let timeNames = ["time", "time logged", "logged time", "log time", "timestamp", "time of day", "logged at", "start time",
                            "started at", "start"]
    static let nameNames = ["food name", "food", "name", "item", "food item", "description", "food description"]
    static let massUnits: [MFColumns.Unit?] = [nil, .kg, .lb]

    static func specs(_ role: Role) -> [Spec] {
        let food: [Spec] = [
            (.name, nameNames, nil), (.brand, ["brand", "brand name", "manufacturer"], nil),
            (.servingSize, ["serving size", "serving", "serving name", "serving unit", "unit", "serving description"], nil),
            (.servingQty, ["serving qty", "serving quantity", "quantity", "qty", "servings", "number of servings", "amount"], nil),
            (.servingWeight, ["serving weight", "weight", "total weight", "grams", "serving grams", "logged weight"], [nil, .g, .kg, .oz, .lb]),
            (.barcode, ["barcode", "upc", "ean", "gtin"], nil),
        ]
        switch role {
        case .foodLog:
            return [(.date, dateNames, nil), (.time, timeNames, nil), (.meal, ["meal", "meal name", "meal slot", "meal type"], nil)] + food
        case .customFoods, .favorites:
            return food
        case .recipes:
            return [(.recipe, ["recipe", "recipe name", "recipe title"], nil),
                    (.ingredient, ["ingredient", "ingredient name", "food name", "food", "item"], nil),
                    (.name, ["name"], nil), (.brand, ["brand", "brand name"], nil),
                    (.servingSize, ["serving size", "serving", "serving unit", "unit"], nil),
                    (.servingQty, ["serving qty", "serving quantity", "quantity", "qty", "amount"], nil),
                    (.servingWeight, ["serving weight", "weight", "ingredient weight", "grams"], [nil, .g, .kg, .oz, .lb]),
                    (.yield, ["yield", "cooked weight", "total weight", "recipe weight", "final weight"], [nil, .g, .kg, .oz, .lb]),
                    (.recipeServings, ["servings", "serving count", "number of servings", "portions", "recipe servings"], nil)]
        case .day, .fasting, .partial, .foodNotes:
            return [(.date, dateNames, nil), (.time, timeNames, nil),
                    (.weight, ["weight", "scale weight", "body weight", "bodyweight", "weigh in", "weight reading"], massUnits),
                    (.bodyFat, ["body fat", "bodyfat", "bf", "body fat percentage", "fat percentage", "body fat percent"], [nil, .percent]),
                    (.fasting, ["fasting", "fasted", "fasting day", "fast", "is fasting", "fasted day"], nil),
                    (.partial, ["partial logging", "partially logged", "partial", "partial day", "partial log", "incomplete"], nil),
                    (.complete, ["complete", "completed", "logging complete", "complete day", "fully logged", "day complete"], nil),
                    (.status, ["day status", "logging status", "status"], nil),
                    (.notes, role == .foodNotes ? ["notes", "note", "food log notes", "food log note", "food notes", "day notes", "comment", "comments"]
                        : ["food log notes", "food log note", "food notes", "day notes"], nil)]
        case .program:
            return [(.updateDate, ["program update date", "update date", "program date", "date", "start date", "effective date", "updated"], nil),
                    (.weekday, ["program weekday", "weekday", "day", "day of week", "day of the week"], nil)]
        case .weightGoals:
            return [(.goal, ["goal", "goal type", "direction", "goal direction"], nil), (.startDate, ["start date", "start"], nil),
                    (.endDate, ["end date", "end"], nil), (.goalWeight, ["goal weight", "target weight"], massUnits),
                    (.rate, ["goal rate per week", "goal rate", "rate", "weekly rate", "rate per week"], [nil, .percent])]
        case .workouts, .workoutNotes:
            return [(.date, dateNames, nil), (.time, timeNames, nil),
                    (.workout, ["workout", "workout name", "session", "routine", "workout title", "session name"], nil),
                    (.workoutDuration, ["workout duration", "session duration", "total duration"], [nil, .seconds, .minutes]),
                    (.exercise, ["exercise", "exercise name", "movement"], nil),
                    (.setType, ["set type", "type", "set kind"], nil), (.load, ["weight", "load", "weight used"], massUnits),
                    (.reps, ["reps", "repetitions", "rep count"], nil), (.rir, ["rir", "reps in reserve"], nil), (.rpe, ["rpe"], nil),
                    (.duration, ["duration", "set duration", "seconds"], [nil, .seconds, .minutes]),
                    (.side, ["side", "laterality"], nil),
                    (.exerciseNotes, ["exercise notes", "exercise note", "set notes"], nil),
                    (.workoutNotes, role == .workoutNotes ? ["notes", "note", "workout notes", "workout log notes", "comment"]
                        : ["workout notes", "workout note", "session notes", "notes", "note"], nil)]
        case .bodyMetrics: return [(.date, dateNames, nil)]
        case .leftOut: return []
        }
    }

    /// Headers understood but not imported.
    static let unused: Set<String> = Set(["trend weight", "weight trend", "trend", "expenditure", "tdee", "steps", "step count",
        "daily average", "expenditure calculation mode", "program type", "program style", "coaching style", "exercise base weight",
        "base weight", "rest", "rest time", "rest timer", "set", "set number", "set index", "set order", "set no", "starting scale weight",
        "starting trend weight", "ending scale weight", "ending trend weight", "original eta", "original eta days", "eta",
        "trend weight goal checkpoint date", "trend weight goal checkpoint weight", "checkpoint date", "checkpoint weight", "icon",
        "source", "food source", "color", "colour", "visual body fat assessment", "status", "weight", "net carbs"].map(MFColumns.key))

    func columns(_ table: Table, role: Role) -> Columns {
        var columns = Columns()
        let specs = Self.specs(role)
        let takesNutrients = [Role.foodLog, .customFoods, .favorites, .recipes, .day, .program].contains(role)
        var seen = Set<Nutrient>()
        for (index, header) in table.headers.sorted(by: { $0.key < $1.key }) {
            if role == .workouts || role == .workoutNotes, header.base.hasPrefix("distance") {
                let metres: Double? = switch header.unit {
                case .m: 1
                case .km: 1000
                case .mi: 1609.344
                case nil: unit == .kilograms ? 1000 : 1609.344
                default: nil
                }
                if let metres { columns.distances.append((index, metres)); continue }
            }
            // "Fat Percent" is body fat, not dietary fat.
            if [Role.day, .fasting, .partial, .foodNotes].contains(role), header.base == "fat", header.unit == .percent {
                if columns.fields[.bodyFat] == nil { columns.fields[.bodyFat] = index }
                continue
            }
            if let spec = specs.first(where: { spec in
                columns.fields[spec.field] == nil && spec.names.contains(header.base) && (spec.units?.contains(header.unit) ?? true)
            }) {
                columns.fields[spec.field] = index
                continue
            }
            if takesNutrients, !header.base.split(separator: " ").contains(where: { $0 == "target" || $0 == "goal" }),
               let nutrient = MFColumns.nutrients[header.base], !seen.contains(nutrient),
               let factor = MFColumns.factor(header.unit, to: nutrient) {
                seen.insert(nutrient)
                columns.nutrients.append((index, nutrient, factor))
            }
        }
        return columns
    }

    /// Reports headers a sheet's role didn't use.
    private mutating func reportColumns(_ table: Table, _ columns: Columns, role: Role) {
        let used = Set(columns.fields.values).union(columns.nutrients.map(\.column)).union(columns.distances.map(\.column))
        var unknown: [String] = [], unused: [String] = []
        for (index, header) in table.headers.sorted(by: { $0.key < $1.key }) where !used.contains(index) {
            let words = header.base.split(separator: " ")
            if Self.unused.contains(header.base) || words.contains("target") || words.contains("goal")
                || MFColumns.nutrients[header.base] != nil {
                unused.append(header.text)
            } else {
                unknown.append(header.text)
            }
        }
        if !unknown.isEmpty { export.report.unknownColumns[table.sheet, default: []] += unknown }
        if !unused.isEmpty { export.report.unusedColumns[table.sheet, default: []] += unused }
    }

    // MARK: Rows

    private mutating func read(_ table: Table, as role: Role) -> Int {
        let columns = columns(table, role: role)
        reportColumns(table, columns, role: role)
        if let note = table.dateNote { assume(note) }
        switch role {
        case .customFoods: return readFoods(table, columns, favorite: false)
        case .favorites: return readFoods(table, columns, favorite: true)
        case .recipes: return readRecipes(table, columns)
        case .foodLog: return readFoodLog(table, columns)
        case .day, .fasting, .partial, .foodNotes: return readDays(table, columns, role: role)
        case .weightGoals: return readGoals(table, columns)
        case .program: return readProgram(table, columns)
        case .workouts: return readWorkouts(table, columns)
        case .workoutNotes: return readWorkoutNotes(table, columns)
        case .bodyMetrics: return readBodyMetrics(table, columns)
        case .leftOut: return 0
        }
    }

    private mutating func skip(_ table: Table, _ row: Spreadsheet.Row?, _ reason: String) {
        export.report.skipped.append(.init(sheet: table.sheet, row: row?.number, reason: reason))
    }

    private mutating func assume(_ note: String) {
        if !export.report.assumptions.contains(note) { export.report.assumptions.append(note) }
    }

    /// A row's nutrients; nil with a reason when they can't be used.
    private func nutrients(_ row: Spreadsheet.Row, _ columns: Columns) -> (NutrientAmounts, String?) {
        var amounts = NutrientAmounts()
        for column in columns.nutrients {
            guard let value = MFColumns.number(row[column.column]) else { continue }
            if value < 0 { return (amounts, "a negative amount of \(column.nutrient.name.lowercased())") }
            amounts[column.nutrient] = value * column.factor
        }
        return (amounts, nil)
    }

    private func hasEnergyOrMacros(_ amounts: NutrientAmounts) -> Bool {
        [Nutrient.energy, .protein, .carbohydrate, .fat].contains { (amounts[$0] ?? 0) > 0 }
    }

    /// Grams from a weight column in its unit.
    private func grams(_ row: Spreadsheet.Row, _ columns: Columns, _ table: Table, field: MFField = .servingWeight) -> Double? {
        guard let column = columns.fields[field], let value = MFColumns.number(row[column]), value > 0 else { return nil }
        switch table.headers[column]?.unit {
        case .kg: return value * 1000
        case .oz: return USUnits.grams(ounces: value)
        case .lb: return value * 453.592_37
        default: return value
        }
    }

    private func date(_ row: Spreadsheet.Row, _ columns: Columns, _ table: Table, field: MFField = .date) -> LocalDate? {
        MFColumns.date(columns.value(field, row), order: table.dateOrder)
    }

    /// Seconds into the day from the time column, or from a date cell that has a time.
    private func seconds(_ row: Spreadsheet.Row, _ columns: Columns) -> Double? {
        if columns.has(.time) { return MFColumns.time(columns.value(.time, row)) }
        switch columns.value(.date, row) {
        case .date(let serial) where serial != serial.rounded(.down): return MFColumns.time(.date(serial))
        case .text(let text) where text.contains(":"): return MFColumns.time(text)
        default: return nil
        }
    }

    private func instant(_ date: LocalDate, _ seconds: Double?) -> Date {
        guard let seconds else { return WeightTrend.noon(on: date, in: timeZone) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let whole = Int(seconds)
        if let at = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: whole / 3600,
                                                       minute: whole % 3600 / 60, second: whole % 60)),
           LocalDate(at, in: timeZone) == date {
            return at.roundedToMilliseconds
        }
        return WeightTrend.noon(on: date, in: timeZone)
    }

    /// The meal by time of day, by the same clock as `suggestedMeal`.
    static func meal(at seconds: Double?) -> String {
        guard let seconds else { return MacroFactorExport.mealWithoutTime }
        switch Int(seconds) / 60 {
        case 240..<630: return "Breakfast"
        case 630..<870: return "Lunch"
        case 1020..<1290: return "Dinner"
        default: return "Snacks"
        }
    }

    private static func amount(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// "1 cup" from a size of "cup" and a quantity of 1; nil when the size is grams.
    private static func servingName(size: String?, quantity: Double?) -> String? {
        let size = size?.trimmingCharacters(in: .whitespaces)
        if let size, ["g", "gram", "grams", "gr"].contains(MFColumns.key(size)) { return nil }
        guard let size, !size.isEmpty else { return quantity.map { "\(amount($0)) \($0 == 1 ? "serving" : "servings")" } ?? "1 serving" }
        if size.first?.isNumber == true { return size }
        return "\(amount(quantity ?? 1)) \(size)"
    }

    // MARK: Foods

    private mutating func readFoods(_ table: Table, _ columns: Columns, favorite: Bool) -> Int {
        var used = 0
        for row in table.rows {
            guard let name = MFColumns.text(columns.value(.name, row)) else {
                skip(table, row, "No food name")
                continue
            }
            let (amounts, problem) = nutrients(row, columns)
            if let problem { skip(table, row, "\(name): \(problem)"); continue }
            guard !amounts.values.isEmpty else { skip(table, row, "\(name): no calories or nutrients"); continue }
            guard let weight = grams(row, columns, table) else {
                skip(table, row, "\(name): no serving weight, so its nutrients per 100 g are unknown")
                continue
            }
            let brand = MFColumns.text(columns.value(.brand, row))
            let quantity = MFColumns.number(columns.value(.servingQty, row)).flatMap { $0 > 0 ? $0 : nil }
            let serving = Self.servingName(size: MFColumns.text(columns.value(.servingSize, row)), quantity: quantity)
            var food = Food(id: MacroFactorExport.foodID(name, brand: brand), name: name, brand: brand, source: .imported,
                            per100g: amounts.scaled(by: 100 / weight), servings: serving.map { [Serving($0, grams: weight)] } ?? [],
                            barcode: MFColumns.text(columns.value(.barcode, row)), favorite: favorite, createdAt: now)
            if let saved = foods[food.id] {
                food = saved
                food.favorite = food.favorite || favorite
            } else {
                guard food.problems.isEmpty else { skip(table, row, "\(name): \(food.problems.joined(separator: ", "))"); continue }
                foodOrder.append(food.id)
            }
            foods[food.id] = food
            used += 1
        }
        return used
    }

    private mutating func readRecipes(_ table: Table, _ columns: Columns) -> Int {
        guard columns.has(.recipe) || columns.has(.name) else {
            skip(table, nil, "No recipe name column")
            return 0
        }
        guard columns.has(.ingredient), columns.has(.recipe) else {
            // One row a recipe, without ingredients: a food.
            var named = columns
            named.fields[.name] = columns.fields[.recipe] ?? columns.fields[.name]
            let used = readFoods(table, named, favorite: false)
            if used > 0 { assume("Recipes without ingredients were imported as foods.") }
            return used
        }
        var order: [String] = []
        var groups: [String: (name: String, ingredients: [RecipeIngredient], yield: Double?, servings: Double?)] = [:]
        var used = 0
        for row in table.rows {
            guard let recipe = MFColumns.text(columns.value(.recipe, row)) else { skip(table, row, "No recipe name"); continue }
            guard let name = MFColumns.text(columns.value(.ingredient, row)) else { skip(table, row, "\(recipe): no ingredient name"); continue }
            let (amounts, problem) = nutrients(row, columns)
            if let problem { skip(table, row, "\(recipe), \(name): \(problem)"); continue }
            guard let weight = grams(row, columns, table) else { skip(table, row, "\(recipe), \(name): no weight"); continue }
            let brand = MFColumns.text(columns.value(.brand, row))
            let snapshot = FoodSnapshot(foodID: MacroFactorExport.foodID(name, brand: brand), name: name, brand: brand,
                                        source: .imported, per100g: amounts.scaled(by: 100 / weight))
            let key = MFColumns.key(recipe)
            if groups[key] == nil { order.append(key) }
            var group = groups[key] ?? (recipe, [], nil, nil)
            group.ingredients.append(RecipeIngredient(food: snapshot, grams: weight))
            group.yield = group.yield ?? grams(row, columns, table, field: .yield)
            group.servings = group.servings ?? MFColumns.number(columns.value(.recipeServings, row)).flatMap { $0 > 0 ? $0 : nil }
            groups[key] = group
            used += 1
        }
        for key in order {
            guard let group = groups[key] else { continue }
            let recipe = Food.recipe(id: MacroFactorExport.id("recipe/\(key)").uuidString, name: group.name, ingredients: group.ingredients,
                                     yieldGrams: group.yield, servingCount: group.servings, createdAt: now)
            guard recipe.problems.isEmpty else { skip(table, nil, "\(group.name): \(recipe.problems.joined(separator: ", "))"); continue }
            if foods[recipe.id] == nil { foodOrder.append(recipe.id) }
            foods[recipe.id] = recipe
        }
        return used
    }

    // MARK: Food log

    private mutating func readFoodLog(_ table: Table, _ columns: Columns) -> Int {
        var occurrences: [String: Int] = [:]
        var used = 0
        for row in table.rows {
            guard let date = date(row, columns, table) else {
                skip(table, row, "No readable date\(MFColumns.text(columns.value(.date, row)).map { ": \($0)" } ?? "")")
                continue
            }
            guard let name = MFColumns.text(columns.value(.name, row)) else { skip(table, row, "No food name"); continue }
            let (amounts, problem) = nutrients(row, columns)
            if let problem { skip(table, row, "\(name): \(problem)"); continue }
            guard !amounts.values.isEmpty else {
                skip(table, row, "\(name): no calories or nutrients")
                continue
            }
            let seconds = seconds(row, columns)
            let brand = MFColumns.text(columns.value(.brand, row))
            let key = "entry/\(date)/\(seconds.map { String(Int($0)) } ?? "-")/\(MFColumns.key(name))|\(MFColumns.key(brand ?? ""))"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let id = MacroFactorExport.id("\(key)/\(occurrence)")
            var meal = MFColumns.text(columns.value(.meal, row)) ?? Self.meal(at: seconds)
            if meal.count > 40 { meal = String(meal.prefix(40)) }
            let foodID = MacroFactorExport.foodID(name, brand: brand)
            var snapshot = FoodSnapshot(foodID: foodID, name: name, brand: brand, source: .imported, per100g: amounts)
            var entry = FoodEntry(id: id, date: date, meal: meal, loggedAt: instant(date, seconds), food: snapshot, grams: 100)
            if seconds == nil { entry.timeUnknown = true }
            if let weight = grams(row, columns, table) {
                entry.grams = weight
                entry.food.per100g = amounts.scaled(by: 100 / weight)
                let quantity = MFColumns.number(columns.value(.servingQty, row)).flatMap { $0 > 0 ? $0 : nil }
                if let serving = Self.servingName(size: MFColumns.text(columns.value(.servingSize, row)), quantity: 1),
                   columns.has(.servingSize) {
                    entry.serving = Serving(serving, grams: weight / (quantity ?? 1))
                    entry.quantity = quantity ?? 1
                }
            } else {
                snapshot.unweighed = true
                entry.food = snapshot
                if !columns.has(.servingWeight) { assume("The food log has no weights, so its foods were logged as whole portions.") }
            }
            guard entry.problems.isEmpty else { skip(table, row, "\(name): \(entry.problems.joined(separator: ", "))"); continue }
            if entries[id] == nil { entryOrder.append(id) }
            entries[id] = entry
            used += 1
        }
        if columns.has(.servingWeight), columns.has(.servingQty) {
            assume("A food log row's serving weight was read as the weight of everything logged in that row.")
        }
        if !columns.has(.time), !columns.has(.meal), used > 0 {
            assume("The food log has no times, so its foods are under \"\(MacroFactorExport.mealWithoutTime)\" on each day.")
        }
        return used
    }

    // MARK: Days

    private mutating func readDays(_ table: Table, _ columns: Columns, role: Role) -> Int {
        var occurrences: [String: Int] = [:]
        var used = 0
        if columns.has(.weight), table.headers[columns.fields[.weight]!]?.unit == nil {
            assume("Weights in \(table.sheet) have no unit, so they were read in kg, as MacroFactor exports them.")
        }
        for row in table.rows {
            guard let date = date(row, columns, table) else {
                skip(table, row, "No readable date\(MFColumns.text(columns.value(.date, row)).map { ": \($0)" } ?? "")")
                continue
            }
            var usedRow = false
            // A weigh-in.
            if let column = columns.fields[.weight], let value = MFColumns.number(row[column]), value > 0 {
                let unit: MassUnit = table.headers[column]?.unit == .lb ? .pounds : .kilograms
                let seconds = seconds(row, columns)
                var bodyFat = MFColumns.number(columns.value(.bodyFat, row)).flatMap { $0 > 0 ? $0 : nil }
                if let fat = bodyFat, fat < 1 {
                    bodyFat = fat * 100
                    assume("Body fat written as a fraction (0.18) was read as a percentage (18 %).")
                }
                let key = "weight/\(date)/\(seconds.map { String(Int($0)) } ?? "-")"
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                var entry = WeightEntry(id: MacroFactorExport.id("\(key)/\(occurrence)"), at: instant(date, seconds), date: date,
                                        weight: Mass(value, unit), bodyFat: bodyFat, source: .macroFactor)
                if !entry.problems.isEmpty, entry.bodyFat != nil {
                    entry.bodyFat = nil
                    if entry.problems.isEmpty { assume("Body fat outside 1 to 75 % was left off its weigh-in.") }
                }
                if entry.problems.isEmpty {
                    let duplicate = weighIns.contains {
                        $0.id == entry.id || ($0.date == date && abs($0.weight.kilograms - entry.weight.kilograms) < 0.005)
                    }
                    if !duplicate { weighIns.append(entry) }
                    usedRow = true
                } else {
                    skip(table, row, "Weigh-in on \(date): \(entry.problems.joined(separator: ", "))")
                }
            }
            // The day's totals.
            let (amounts, problem) = nutrients(row, columns)
            if let problem {
                skip(table, row, "\(date): \(problem)")
            } else if !amounts.values.isEmpty {
                var day = totals[date] ?? NutrientAmounts()
                for (nutrient, amount) in amounts.values where day[nutrient] == nil { day[nutrient] = amount }
                totals[date] = day
                usedRow = true
            }
            // Flags and notes.
            var flag = flags[date] ?? Flags()
            let before = (flag.fasting, flag.partial, flag.complete, flag.notes)
            if let value = MFColumns.bool(columns.value(.fasting, row)) { flag.fasting = value }
            if let value = MFColumns.bool(columns.value(.partial, row)) { flag.partial = value }
            if let value = MFColumns.bool(columns.value(.complete, row)) { flag.complete = value }
            switch MFColumns.text(columns.value(.status, row)).map(MFColumns.key) {
            case "fasting"?, "fasted"?, "fast"?: flag.fasting = true
            case "partial"?, "partially logged"?, "partial logging"?, "incomplete"?: flag.partial = true
            case "complete"?, "completed"?, "logged"?, "fully logged"?: flag.complete = true
            default: break
            }
            // A row in a Fasting or Partial Logging sheet is a flag unless a column says otherwise.
            if role == .fasting, MFColumns.bool(columns.value(.fasting, row)) == nil { flag.fasting = true }
            if role == .partial, MFColumns.bool(columns.value(.partial, row)) == nil { flag.partial = true }
            if let notes = MFColumns.text(columns.value(.notes, row)) {
                flag.notes = flag.notes.map { "\($0)\n\(notes)" } ?? notes
            }
            if before != (flag.fasting, flag.partial, flag.complete, flag.notes) {
                flags[date] = flag
                usedRow = true
            }
            if usedRow { used += 1 }
        }
        return used
    }

    // MARK: Plans

    private mutating func readGoals(_ table: Table, _ columns: Columns) -> Int {
        var used = 0
        for row in table.rows {
            let text = MFColumns.text(columns.value(.goal, row)).map(MFColumns.key) ?? ""
            let rateValue = MFColumns.number(columns.value(.rate, row))
            var direction: NutritionGoal.Direction?
            if ["lose", "loss", "cut", "fat loss", "lose weight", "lose fat", "weight loss"].contains(where: text.contains) {
                direction = .lose
            } else if ["gain", "build", "bulk", "muscle", "gain weight"].contains(where: text.contains) {
                direction = .gain
            } else if text.contains("maint") {
                direction = .maintain
            } else if let rateValue, rateValue != 0 {
                direction = rateValue < 0 ? .lose : .gain
            }
            guard let direction else { skip(table, row, "A goal that isn't to lose, gain or maintain"); continue }
            var rate = 0.0
            if direction != .maintain, let rateValue {
                let percent = table.headers[columns.fields[.rate]!]?.unit == .percent || abs(rateValue) >= 0.03
                rate = abs(rateValue) / (percent ? 100 : 1)
                let limit = direction == .lose ? NutritionTargets.maximumLoss : NutritionTargets.maximumGain
                if rate > limit {
                    rate = limit
                    assume("A goal rate above Exerly's limit of \(Self.amount(limit * 100)) % a week was imported at the limit.")
                }
            }
            if direction != .maintain, rate == 0 {
                rate = NutritionRate.standard(for: direction)
                assume("A goal without a rate was given Exerly's standard rate.")
            }
            let weight: Mass? = columns.fields[.goalWeight].flatMap { column in
                MFColumns.number(row[column]).flatMap { $0 > 0 ? Mass($0, table.headers[column]?.unit == .lb ? .pounds : .kilograms) : nil }
            }
            goals.append(Goal(start: date(row, columns, table, field: .startDate), end: date(row, columns, table, field: .endDate),
                              goal: NutritionGoal(direction, weeklyRate: rate, goalWeight: direction == .maintain ? nil : weight)))
            used += 1
        }
        return used
    }

    private static let weekdays: [String: Weekday] = {
        var days: [String: Weekday] = [:]
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in names.enumerated() {
            let day = Weekday(rawValue: index + 1)!
            days[name] = day
            days[String(name.prefix(3))] = day
        }
        days["tues"] = .tuesday
        days["thur"] = .thursday
        days["thurs"] = .thursday
        return days
    }()

    private mutating func readProgram(_ table: Table, _ columns: Columns) -> Int {
        var order: [LocalDate] = []
        var versions: [LocalDate: [(weekday: Weekday?, targets: DailyTargets, row: Int)]] = [:]
        var used = 0
        for row in table.rows {
            guard let start = date(row, columns, table, field: .updateDate) else {
                skip(table, row, "No readable program date")
                continue
            }
            let (amounts, problem) = nutrients(row, columns)
            if let problem { skip(table, row, "\(start): \(problem)"); continue }
            guard let energy = amounts[.energy], let protein = amounts[.protein], let fat = amounts[.fat],
                  let carbohydrate = amounts[.carbohydrate] else {
                skip(table, row, "\(start): targets need calories, protein, carbs and fat")
                continue
            }
            var text = MFColumns.text(columns.value(.weekday, row)).map(MFColumns.key)
            if let day = text, ["all", "all days", "every day", "everyday", "daily"].contains(day) { text = nil }
            let weekday = text.flatMap { Self.weekdays[$0] }
            if text != nil, weekday == nil { skip(table, row, "\(start): an unknown weekday"); continue }
            if versions[start] == nil { order.append(start) }
            versions[start, default: []].append((weekday, DailyTargets(energy: energy, protein: protein, fat: fat, carbohydrate: carbohydrate),
                                                 row.number))
            used += 1
        }
        for start in order {
            guard let rows = versions[start] else { continue }
            var targets: [DailyTargets?] = Array(repeating: nil, count: 7)
            if rows.count == 1, rows[0].weekday == nil {
                targets = Array(repeating: rows[0].targets, count: 7)
            } else {
                for row in rows { if let weekday = row.weekday { targets[weekday.rawValue - 1] = row.targets } }
            }
            let days = targets.compactMap { $0 }
            guard days.count == 7 else {
                skip(table, nil, "The program from \(start) has targets for \(days.count) of 7 weekdays")
                continue
            }
            let mean = days.reduce(0) { $0 + $1.energy } / 7
            let goal = goals.last { goal in
                (goal.start.map { $0 <= start } ?? true) && (goal.end.map { start <= $0 } ?? true)
            }?.goal ?? NutritionGoal(.maintain)
            let plan = NutritionPlan(id: MacroFactorExport.id("plan/\(start)"), startDate: start,
                                     createdAt: WeightTrend.noon(on: start, in: timeZone), goal: goal, mode: .manual,
                                     weekdayWeights: days.map { mean > 0 ? (($0.energy / mean) * 1000).rounded() / 1000 : 1 },
                                     targets: days)
            guard plan.validationErrors.isEmpty else {
                skip(table, nil, "The program from \(start): \(plan.validationErrors.joined(separator: ", "))")
                continue
            }
            export.plans.removeAll { $0.id == plan.id }
            export.plans.append(plan)
        }
        export.plans.sort { $0.startDate < $1.startDate }
        if used > 0 { assume("Nutrition programs were imported as manual targets: Exerly's check-ins don't change them.") }
        return used
    }

    // MARK: Workouts

    /// MacroFactor's continuations of a myo set.
    static let miniSetNames: Set<String> = ["mini set", "miniset", "myo mini set", "myo rep mini set", "myo reps mini set"]

    private static func setKind(_ text: String?) -> SetKind? {
        guard let text else { return .standard }
        let key = MFColumns.key(text)
        switch key {
        case "", "standard", "standard set", "normal", "normal set", "working", "working set", "straight", "s": return .standard
        case "warm up", "warmup", "warm up set", "warmup set", "w": return .warmUp
        case "drop", "drop set", "dropset", "d": return .drop
        case "myo", "myo set", "myo reps", "myoreps", "m": return .myo
        case "failure", "failure set", "to failure", "f": return .failure
        default: return nil
        }
    }

    private mutating func readWorkouts(_ table: Table, _ columns: Columns) -> Int {
        guard columns.has(.exercise) else { skip(table, nil, "No exercise column"); return 0 }
        var order: [String] = []
        var groups: [String: [Spreadsheet.Row]] = [:]
        var dates: [String: (LocalDate, Double?)] = [:]
        for row in table.rows {
            guard let date = date(row, columns, table) else {
                skip(table, row, "No readable date\(MFColumns.text(columns.value(.date, row)).map { ": \($0)" } ?? "")")
                continue
            }
            let seconds = seconds(row, columns)
            let key = "\(date)/\(MFColumns.key(MFColumns.text(columns.value(.workout, row)) ?? ""))/\(seconds.map { String(Int($0)) } ?? "-")"
            if groups[key] == nil {
                order.append(key)
                dates[key] = (date, seconds)
            }
            groups[key, default: []].append(row)
        }
        if !columns.has(.time), !order.isEmpty { assume("Workouts have no start time, so each starts at midday.") }
        var used = 0
        var unknownKinds = false
        var looseMiniSets = 0
        var workoutStarts: [Int: Int] = [:]
        for key in order {
            guard let rows = groups[key], let (date, seconds) = dates[key] else { continue }
            // Known by its start, so a workout renamed in MacroFactor updates rather than doubles.
            let minute = WorkoutImport.localMinute(instant(date, seconds), in: timeZone)
            let ordinal = workoutStarts[minute, default: 0]
            workoutStarts[minute] = ordinal + 1
            let sessionID = WorkoutImport.sessionID(source: "macroFactor", start: instant(date, seconds), in: timeZone, ordinal: ordinal)
            var exercises: [PerformedExercise] = []
            var index: [ExerciseID: Int] = [:]
            for row in rows {
                guard let name = MFColumns.text(columns.value(.exercise, row)) else { skip(table, row, "No exercise name"); continue }
                if leftOut.contains(name) {
                    export.report.leftOutExercises[name, default: 0] += 1
                    continue
                }
                guard let id = WorkoutImport.match(name, library: library, mapping: mapping), let exercise = library.exercise(id) else {
                    export.report.unmappedExercises[name, default: 0] += 1
                    continue
                }
                export.report.mappedExercises[name] = id
                export.report.exerciseSets[name, default: 0] += 1
                var kindText = MFColumns.text(columns.value(.setType, row))
                let mini = kindText.map(MFColumns.key).map(Self.miniSetNames.contains) ?? false
                var kind = mini ? .standard : Self.setKind(kindText)
                if kind == nil { unknownKinds = true; kind = .standard; kindText = nil }
                let load = columns.fields[.load].flatMap { column in
                    MFColumns.number(row[column]).flatMap { $0 > 0 ? Mass($0, table.headers[column]?.unit == .lb ? .pounds : .kilograms) : nil }
                }
                let reps = MFColumns.number(columns.value(.reps, row)).flatMap { $0 >= 1 && $0 < 10_000 ? Int($0.rounded()) : nil }
                let duration = columns.fields[.duration].flatMap { MFColumns.duration(row[$0], unit: table.headers[$0]?.unit) }
                let distance = columns.distances.lazy.compactMap { column in
                    MFColumns.number(row[column.column]).flatMap { $0 > 0 ? $0 * column.metres : nil }
                }.first
                var rir = MFColumns.number(columns.value(.rir, row)).map { min(6, max(0, $0)) }
                if rir == nil, let rpe = MFColumns.number(columns.value(.rpe, row)) { rir = PerformedSet.rir(fromRPE: rpe) }
                let side: Side? = switch MFColumns.text(columns.value(.side, row)).map(MFColumns.key) {
                case "left"?, "l"?: .left
                case "right"?, "r"?: .right
                default: nil
                }
                let position: Int
                if let existing = index[id] {
                    position = existing
                } else {
                    position = exercises.count
                    index[id] = position
                    exercises.append(PerformedExercise(id: MacroFactorExport.id("\(sessionID)/\(position)"), exerciseID: id,
                                                       notes: MFColumns.text(columns.value(.exerciseNotes, row)) ?? ""))
                }
                // A mini-set continues the myo set before it, as one set of several efforts.
                if mini, let last = exercises[position].sets.indices.last, exercises[position].sets[last].kind == .myo {
                    exercises[position].sets[last].efforts.append(Effort(reps: reps, load: load, duration: duration, distance: distance))
                    export.report.exerciseSets[name, default: 1] -= 1
                    used += 1
                    continue
                }
                if mini { looseMiniSets += 1 }
                var set = PerformedSet(id: MacroFactorExport.id("\(exercises[position].id)/\(exercises[position].sets.count)"),
                                       kind: kind ?? .standard, side: side,
                                       efforts: [Effort(reps: reps, load: load, duration: duration, distance: distance)], rir: rir)
                set.completedAt = Date(timeIntervalSince1970: 0)
                guard set.isLoggable(for: exercise) else {
                    skip(table, row, "\(name) on \(date): a set without what \(exercise.name) records")
                    continue
                }
                exercises[position].sets.append(set)
                used += 1
            }
            exercises.removeAll { $0.sets.isEmpty }
            guard !exercises.isEmpty else { continue }
            // Sets are spread evenly from the start to the end.
            let start = instant(date, seconds)
            let count = exercises.reduce(0) { $0 + $1.sets.count }
            let length = columns.fields[.workoutDuration].flatMap { column in
                rows.lazy.compactMap { MFColumns.duration($0[column], unit: table.headers[column]?.unit) }.first
            }
            let end = start.addingTimeInterval(max(length ?? 0, Double(count) * 60))
            var done = 0
            for e in exercises.indices {
                for s in exercises[e].sets.indices {
                    done += 1
                    exercises[e].sets[s].completedAt = start.addingTimeInterval(end.timeIntervalSince(start) * Double(done) / Double(count))
                        .roundedToMilliseconds
                }
            }
            let bodyweight = weighIns.filter { $0.date <= date }.max { $0.at < $1.at }?.weight
            var session = WorkoutSession(name: MFColumns.text(columns.value(.workout, rows[0])) ?? "Workout", startedAt: start,
                                         endedAt: end.roundedToMilliseconds, timeZone: timeZone, bodyweight: bodyweight, exercises: exercises)
            session.id = sessionID
            session.notes = rows.lazy.compactMap { MFColumns.text(columns.value(.workoutNotes, $0)) }.first ?? ""
            guard (try? session.validate(library: library)) != nil else {
                skip(table, nil, "The workout on \(date) isn't valid")
                continue
            }
            if sessionIDs.insert(sessionID).inserted { export.sessions.append(session) }
        }
        if unknownKinds { assume("Set types Exerly doesn't know were imported as working sets.") }
        if looseMiniSets > 0 {
            assume("\(looseMiniSets) mini-\(looseMiniSets == 1 ? "set" : "sets") without a myo set before \(looseMiniSets == 1 ? "it" : "them") became working sets.")
        }
        export.sessions.sort { $0.startedAt < $1.startedAt }
        return used
    }

    private mutating func readWorkoutNotes(_ table: Table, _ columns: Columns) -> Int {
        var used = 0
        for row in table.rows {
            guard let date = date(row, columns, table), let notes = MFColumns.text(columns.value(.workoutNotes, row)) else {
                skip(table, row, "A note without a readable date or text")
                continue
            }
            workoutNotes.append((date, MFColumns.text(columns.value(.workout, row)).map(MFColumns.key), notes))
            used += 1
        }
        return used
    }

    // MARK: Body metrics

    /// A date and a column per site, such as "Waist (cm)" or "Left Bicep
    /// (in)". Lengths without a unit are read in the person's units.
    private mutating func readBodyMetrics(_ table: Table, _ columns: Columns) -> Int {
        var used = 0
        var assumed = false
        let sites = table.headers.compactMap { index, header -> (Int, BodySite, MeasurementImport.Length?)? in
            guard index != columns.fields[.date], let site = MeasurementImport.site(header.text) else { return nil }
            return (index, site, MeasurementImport.length(header.text))
        }
        let unknown = table.headers.filter { index, header in
            index != columns.fields[.date] && MeasurementImport.site(header.text) == nil && !header.text.isEmpty
        }.map(\.value.text).sorted()
        if !unknown.isEmpty { export.report.unknownColumns[table.sheet, default: []] += unknown }
        for row in table.rows {
            guard let date = date(row, columns, table) else {
                skip(table, row, "No readable date")
                continue
            }
            for (index, site, length) in sites {
                guard let value = MFColumns.number(row[index]), value > 0 else { continue }
                if site != .bodyFat && length == nil { assumed = true }
                let measured = site == .bodyFat ? value : MeasurementImport.centimetres(value, length ?? (unit == .kilograms ? .cm : .inches))
                guard MeasurementImport.plausible(measured, site: site) else {
                    skip(table, row, "\(site.rawValue) of \(value) isn't a measurement")
                    continue
                }
                export.measurements.append(ImportedMeasurement(site: site, value: measured, date: date, source: .macroFactor))
                used += 1
            }
        }
        if assumed { assume("Some body measurements have no unit, so they were read in \(unit == .kilograms ? "cm" : "inches").") }
        return used
    }

    // MARK: Finish

    private mutating func finish() {
        export.foods = foodOrder.compactMap { foods[$0] }
        export.entries = entryOrder.compactMap { entries[$0] }
            .sorted { ($0.date, $0.loggedAt, $0.id.uuidString) < ($1.date, $1.loggedAt, $1.id.uuidString) }
        let logged = Set(export.entries.map(\.date))
        for (date, amounts) in totals.sorted(by: { $0.key < $1.key }) where !logged.contains(date) && hasEnergyOrMacros(amounts) {
            let id = MacroFactorExport.dayTotalID(date)
            var snapshot = FoodSnapshot(foodID: "quick:" + id.uuidString, name: MacroFactorExport.dayTotalName,
                                        source: .imported, per100g: amounts)
            snapshot.unweighed = true
            var total = FoodEntry(id: id, date: date, meal: MacroFactorExport.mealWithoutTime,
                                  loggedAt: WeightTrend.noon(on: date, in: timeZone), food: snapshot, grams: 100)
            total.timeUnknown = true
            export.dayTotals.append(total)
        }
        let withFood = logged.union(export.dayTotals.map(\.date))
        for date in withFood.union(flags.keys).sorted() {
            let flag = flags[date] ?? Flags()
            let status: DayStatus? = if flag.fasting == true {
                .fasting
            } else if flag.partial == true {
                .partial
            } else if flag.complete == true || withFood.contains(date) {
                .complete
            } else {
                nil
            }
            if status != nil || flag.notes != nil { export.days.append(.init(date: date, status: status, notes: flag.notes)) }
        }
        export.weights = weighIns.sorted { $0.at < $1.at }
        for note in workoutNotes {
            for index in export.sessions.indices where export.sessions[index].localDate == note.date && export.sessions[index].notes.isEmpty
                && (note.workout.map { MFColumns.key(export.sessions[index].name) == $0 } ?? true) {
                export.sessions[index].notes = note.notes
            }
        }
    }
}
