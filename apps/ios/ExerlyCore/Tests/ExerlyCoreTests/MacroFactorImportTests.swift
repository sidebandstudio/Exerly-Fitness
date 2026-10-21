import Foundation
import Testing
@testable import ExerlyCore

@MainActor
@Suite struct MacroFactorImportTests {
    let newYork = TimeZone(identifier: "America/New_York")!

    func read(_ sheets: [(name: String, rows: [[TestCell]])] = MacroFactorFixture.sheets, unit: MassUnit = .kilograms) throws
        -> MacroFactorExport {
        MacroFactorExport(try Spreadsheet.xlsx(XLSXBuilder(sheets).data()), timeZone: newYork, unit: unit,
                          locale: Locale(identifier: "en_US"), now: Fixture.instant())
    }

    func stores() throws -> (InMemoryTrainingPersistence, NutritionStore, TrainingStore) {
        let persistence = InMemoryTrainingPersistence()
        return (persistence, try NutritionStore(persistence: persistence, now: { Fixture.instant() }),
                try TrainingStore(persistence: persistence, now: { Fixture.instant() }))
    }

    func at(_ date: String, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let day = LocalDate(date)!
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    // MARK: Headers

    @Test func headersMatchIgnoringCaseSpacingPunctuationAndUnits() {
        typealias Header = MFColumns.Header
        #expect(Header("Weight (kg)").base == "weight" && Header("Weight (kg)").unit == .kg)
        #expect(Header("  WEIGHT   kg ").base == "weight" && Header("  WEIGHT   kg ").unit == .kg)
        #expect(Header("Fat Percent").base == "fat" && Header("Fat Percent").unit == .percent)
        #expect(Header("Goal Rate per Week (%)").base == "goal rate per week" && Header("Goal Rate per Week (%)").unit == .percent)
        #expect(Header("Folate (mcg DFE)").base == "folate" && Header("Folate (mcg DFE)").unit == .mcg)
        #expect(Header("Vitamin B12 (µg)").unit == .mcg)
        #expect(Header("kcal").base == "" && Header("kcal").unit == .kcal)
        #expect(Header("Trend Weight (kg)").base == "trend weight")
        #expect(Header("Glitter (sparkles)").base == "glitter sparkles" && Header("Glitter (sparkles)").unit == nil)
        let nutrients = MFColumns.nutrients
        for (header, nutrient) in [("Calories (kcal)", Nutrient.energy), ("Carbs (g)", .carbohydrate), ("B1, Thiamine (mg)", .thiamin),
                                   ("Vitamin B6 (mg)", .vitaminB6), ("Omega-3 ALA (g)", .omega3ALA), ("Sugars Added (g)", .addedSugars),
                                   ("Monounsaturated Fat (g)", .monounsaturatedFat), ("Fibre", .fiber), ("Vitamin K (mcg)", .vitaminK),
                                   ("kcal", .energy), ("Pantothenic Acid (B5)", .pantothenicAcid)] {
            #expect(nutrients[Header(header).base] == nutrient, "\(header)")
        }
        #expect(nutrients[Header("Net Carbs (g)").base] == nil, "Net carbs aren't carbs")
        #expect(MFColumns.factor(.mg, to: .protein) == 0.001 && MFColumns.factor(.iu, to: .vitaminD) == 0.025)
        #expect(MFColumns.factor(.iu, to: .vitaminA) == nil && MFColumns.factor(.percent, to: .fat) == nil)
    }

    @Test func cellsReadWhetherTypedOrText() {
        #expect(MFColumns.number("82,5") == 82.5 && MFColumns.number("1,234.5") == 1234.5 && MFColumns.number("1.234,5") == 1234.5)
        #expect(MFColumns.number("6+") == 6 && MFColumns.number("18 %") == 18 && MFColumns.number("abc") == nil && MFColumns.number("1e3") == 1000)
        #expect(MFColumns.time("07:38 PM") == 70_680 && MFColumns.time("12:05 AM") == 300 && MFColumns.time("19:38:15") == 70_695)
        #expect(MFColumns.time("2026-10-05 08:30") == 30_600 && MFColumns.time(.number(0.25)) == 21_600 && MFColumns.time("25:00") == nil)
        #expect(MFColumns.date("2026-10-05", order: .monthFirst) == LocalDate("2026-10-05"))
        #expect(MFColumns.date("10/05/2026", order: .monthFirst) == LocalDate("2026-10-05"))
        #expect(MFColumns.date("05/10/2026", order: .dayFirst) == LocalDate("2026-10-05"))
        #expect(MFColumns.date("Oct 5, 2026", order: .dayFirst) == LocalDate("2026-10-05"))
        #expect(MFColumns.date(.number(46300), order: .dayFirst) == LocalDate("2026-10-05"))
        #expect(MFColumns.date(.number(12), order: .dayFirst) == nil, "A small number isn't a date")
        #expect(MFColumns.duration(.text("1:05:30"), unit: nil) == 3930 && MFColumns.duration(.text("1h 5m"), unit: nil) == 3900)
        #expect(MFColumns.duration(.number(45), unit: .minutes) == 2700 && MFColumns.duration(.date(1.0 / 24), unit: nil) == 3600)
        #expect(MFColumns.bool(.text("Yes")) == true && MFColumns.bool(.text("FALSE")) == false && MFColumns.bool(.text("maybe")) == nil)
        let texts: [Spreadsheet.Value?] = [.text("03/04/2026"), .text("13/04/2026")]
        #expect(MFColumns.dateOrder(texts, locale: Locale(identifier: "en_US")) == (.dayFirst, true))
        let ambiguous = MFColumns.dateOrder([.text("03/04/2026")], locale: Locale(identifier: "en_GB"))
        #expect(ambiguous.order == .dayFirst && !ambiguous.decided, "Undecided slashes follow the locale")
    }

    // MARK: Mapping

    @Test func foodLogRowsBecomeEntriesWithSnapshotsServingsMealsAndTimes() throws {
        let export = try read()
        let entries = export.entries
        #expect(entries.map(\.food.name) == ["Synthetic Oats", "Test Chicken Breast", "Fixture Apple", "Fixture Apple", "Synthetic Oats",
                                            "Restaurant Bowl"])
        #expect(entries.map(\.meal) == ["Breakfast", "Lunch", "Snacks", "Snacks", "Breakfast", "Dinner"], "Meals follow the time of day")
        #expect(Set(entries.map(\.id)).count == 6, "Two identical rows are two entries")

        let oats = entries[0]
        #expect(oats.date == LocalDate("2026-10-01") && oats.loggedAt == at("2026-10-01", 7, 30))
        #expect(oats.grams == 80 && close(oats.nutrients.energy, 300) && close(oats.nutrients[.sodium], 2) && close(oats.nutrients[.fiber], 8))
        #expect(oats.serving == Serving("1 cup", grams: 80) && oats.quantity == 1)
        #expect(oats.food.source == .imported && oats.food.foodID == export.foods.first { $0.name == "Synthetic Oats" }?.id,
                "A logged food links to the library food of the same name")

        let chicken = entries[1]
        #expect(chicken.loggedAt == at("2026-10-01", 12) && chicken.food.brand == "Fixture Farms")
        #expect(chicken.grams == 150 && chicken.serving == nil, "Logged by weight, so no serving")
        #expect(close(chicken.food.per100g.energy, 248 / 1.5, tolerance: 1e-9) && chicken.food.per100g[.fiber] == nil, "An empty cell is unknown, not zero")

        let secondOats = entries[4]
        #expect(secondOats.grams == 120 && secondOats.quantity == 1.5 && secondOats.serving == Serving("1 cup", grams: 80))
        #expect(close(secondOats.nutrients.energy, 450))

        let bowl = entries[5]
        #expect(bowl.food.unweighed == true && bowl.grams == 100 && close(bowl.nutrients.energy, 700), "No weight: a whole portion")
        #expect(bowl.loggedAt == at("2026-10-02", 19, 40))
    }

    @Test func dailyTotalsFillDaysWithoutFoodLogRowsWithEveryNutrient() throws {
        let export = try read()
        #expect(export.dayTotals.map(\.date) == [LocalDate("2026-09-29")!, LocalDate("2026-09-30")!],
                "Oct 1 has food log rows and Oct 3 logged nothing")
        let total = export.dayTotals[0]
        #expect(total.meal == MacroFactorExport.mealWithoutTime && total.food.name == MacroFactorExport.dayTotalName)
        #expect(total.food.unweighed == true && total.food.foodID.hasPrefix(NutritionStore.quickAddPrefix), "Kept out of recent foods")
        let n = total.nutrients
        #expect(n.energy == 2150 && n.protein == 150 && n.carbohydrate == 230 && n.fat == 70)
        #expect(n[.fiber] == 31 && n[.sodium] == 2400 && n[.vitaminB12] == 4.2 && n[.thiamin] == 1.4 && n[.omega3ALA] == 1.1)
        #expect(n[.alcohol] == 14 && n[.caffeine] == 200 && n[.folate] == 410 && close(n[.vitaminD], 10), "400 IU of vitamin D is 10 mcg")
        #expect(total.loggedAt == WeightTrend.noon(on: LocalDate("2026-09-29")!, in: newYork))
    }

    /// PARITY N21-N27: a column for each of Exerly's 51 micronutrients arrives
    /// in its own nutrient, in Exerly's unit, and none is left over. Only a few
    /// of MacroFactor's real headers are known (MacroFactorColumns.swift:72-75);
    /// the others are common spellings, so this tests the matching, not the
    /// real export's 50 columns.
    @Test func everyMicronutrientColumnArrivesInItsOwnNutrientAndUnit() throws {
        let columns: [(header: String, nutrient: Nutrient, cell: Double, expected: Double)] = [
            ("B1, Thiamine (mg)", .thiamin, 1.2, 1.2), ("B2, Riboflavin (mg)", .riboflavin, 1.3, 1.3),
            ("B3, Niacin (mg)", .niacin, 16, 16), ("B5, Pantothenic Acid (mg)", .pantothenicAcid, 5, 5),
            ("B6, Pyridoxine (mg)", .vitaminB6, 1.7, 1.7), ("B12, Cobalamin (mcg)", .vitaminB12, 2.4, 2.4),
            ("Folate (mcg DFE)", .folate, 400, 400),
            ("Vitamin A (mcg)", .vitaminA, 900, 900), ("Vitamin C (mg)", .vitaminC, 90, 90), ("Vitamin D (mcg)", .vitaminD, 15, 15),
            ("Vitamin E (mg)", .vitaminE, 15.5, 15.5), ("Vitamin K (mcg)", .vitaminK, 120, 120),
            ("Calcium (mg)", .calcium, 1000, 1000), ("Copper (mg)", .copper, 0.9, 0.9), ("Iron (mg)", .iron, 8, 8),
            ("Magnesium (mg)", .magnesium, 420, 420), ("Manganese (mg)", .manganese, 2.3, 2.3),
            ("Phosphorus (mg)", .phosphorus, 700, 700), ("Potassium (mg)", .potassium, 3400, 3400),
            ("Selenium (mcg)", .selenium, 55, 55), ("Sodium (mg)", .sodium, 2300, 2300), ("Zinc (mg)", .zinc, 11, 11),
            ("Histidine (g)", .histidine, 1.1, 1.1), ("Isoleucine (g)", .isoleucine, 1.4, 1.4), ("Leucine (g)", .leucine, 2.7, 2.7),
            ("Lysine (g)", .lysine, 2.1, 2.1), ("Methionine (g)", .methionine, 0.7, 0.7), ("Phenylalanine (g)", .phenylalanine, 1.3, 1.3),
            ("Threonine (g)", .threonine, 1.1, 1.1), ("Tryptophan (g)", .tryptophan, 0.3, 0.3), ("Valine (g)", .valine, 1.6, 1.6),
            ("Cysteine (mg)", .cystine, 450, 0.45), ("Tyrosine (g)", .tyrosine, 1.2, 1.2),
            ("Monounsaturated Fat (g)", .monounsaturatedFat, 25, 25), ("Polyunsaturated Fat (g)", .polyunsaturatedFat, 15, 15),
            ("Saturated Fat (g)", .saturatedFat, 20, 20), ("Trans Fat (g)", .transFat, 0.5, 0.5),
            ("Omega-3 Total (g)", .omega3, 2, 2), ("Omega-3 ALA (g)", .omega3ALA, 1.5, 1.5), ("Omega-3 EPA (g)", .omega3EPA, 0.25, 0.25),
            ("Omega-3 DHA (g)", .omega3DHA, 0.25, 0.25), ("Omega-6 (g)", .omega6, 12, 12),
            ("Fiber (g)", .fiber, 30, 30), ("Starch (g)", .starch, 90, 90), ("Sugars (g)", .sugars, 50, 50),
            ("Sugars Added (g)", .addedSugars, 20, 20),
            ("Alcohol (g)", .alcohol, 14, 14), ("Caffeine (mg)", .caffeine, 95, 95), ("Cholesterol (mg)", .cholesterol, 250, 250),
            ("Choline (mg)", .choline, 550, 550), ("Water (g)", .water, 2500, 2500),
        ]
        #expect(Set(columns.map(\.nutrient)).count == columns.count, "One column per nutrient")
        let date = TestCell.date(MacroFactorFixture.serial(LocalDate("2026-09-29")!))
        let export = try read([
            ("Calories & Macros", [MacroFactorFixture.header(["Date", "Calories (kcal)", "Protein (g)", "Carbs (g)", "Fat (g)"]),
                                   [date, .n(2200), .n(150), .n(240), .n(70)]]),
            ("Micronutrients", [MacroFactorFixture.header(["Date"] + columns.map(\.header)), [date] + columns.map { TestCell.n($0.cell) }]),
        ])
        #expect(export.report.unknownColumns["Micronutrients"] == nil && export.report.unusedColumns["Micronutrients"] == nil)
        let amounts = try #require(export.dayTotals.first).nutrients
        for column in columns {
            #expect(close(amounts[column.nutrient], column.expected), "\(column.header) → \(column.nutrient): \(String(describing: amounts[column.nutrient]))")
        }
        // The omega-3 total is its own column, not the sum of its parts added again.
        #expect(amounts[.omega3] == 2)
    }

    /// PARITY S06: a weight goal's starting and ending scale and trend weights
    /// aren't kept. Exerly draws the start of a goal's path from its own trend.
    @Test func aWeightGoalsStartAndEndWeightsAreLeftOut() throws {
        let export = try read([("Weight Goals", [
            MacroFactorFixture.header(["Goal", "Start Date", "End Date", "Goal Weight (kg)", "Goal Rate per Week (%)",
                                       "Starting Scale Weight (kg)", "Starting Trend Weight (kg)", "Ending Scale Weight (kg)",
                                       "Ending Trend Weight (kg)"]),
            [.s("Lose"), .date(MacroFactorFixture.serial(LocalDate("2026-09-01")!)), .date(MacroFactorFixture.serial(LocalDate("2026-09-28")!)),
             .n(78), .n(0.5), .n(83), .n(82.6), .n(81), .n(81.2)],
        ])])
        #expect(export.report.unusedColumns["Weight Goals"] == ["Starting Scale Weight (kg)", "Starting Trend Weight (kg)",
                                                                "Ending Scale Weight (kg)", "Ending Trend Weight (kg)"])
    }

    /// PARITY N31: a day total, or a row without a time, has no time of day.
    /// It's stamped at noon for the trend, but timing doesn't count it at 12:00.
    @Test func importedDayTotalsAreLeftOutOfTimingByHour() throws {
        let (_, nutrition, training) = try stores()
        let export = try read()
        #expect(MacroFactorImport(export, nutrition: nutrition, training: training).save(nutrition: nutrition, training: training)
            .failures.isEmpty)
        let timing = nutrition.timing(from: LocalDate("2026-09-29")!, through: LocalDate("2026-09-30")!, timeZone: newYork)
        #expect(timing.hours[12].entries == 0 && timing.untimedEntries == export.dayTotals.count)
        #expect(export.dayTotals.allSatisfy { $0.timeUnknown == true })
    }

    @Test func dayFlagsGiveFastingPartialAndCompleteDaysWithNotes() throws {
        let days = try read().days
        #expect(days.map(\.date.description) == ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"])
        #expect(days.map(\.status) == [.complete, .partial, .complete, .complete, .fasting])
        #expect(days[2].notes == "Synthetic note: travel day" && days[0].notes == nil)
    }

    @Test func scaleWeightBecomesMacroFactorWeighInsWithBodyFat() throws {
        let export = try read()
        #expect(export.weights.map(\.date.description) == ["2026-09-28", "2026-09-30", "2026-10-02", "2026-10-04"], "900 kg is left out")
        #expect(export.weights.map(\.weight) == [.kg(82.4), .kg(82.1), .kg(81.9), .kg(81.7)])
        #expect(export.weights.map(\.bodyFat) == [18.5, nil, 19, 20], "0.2 is read as 20 %")
        #expect(export.weights.allSatisfy { $0.source == .macroFactor })
        #expect(export.weights[0].at == WeightTrend.noon(on: LocalDate("2026-09-28")!, in: newYork))
        #expect(export.report.assumptions.contains { $0.contains("fraction") })

        let pounds = try read([("Weigh-ins", [[.s("date"), .s("WEIGHT LBS"), .s("Body Fat"), .s("time")],
                                             [.s("2026-10-05"), .s("181.4"), .s("17.5"), .s("6:45 AM")]])], unit: .kilograms)
        #expect(pounds.weights.first?.weight == .lb(181.4) && pounds.weights.first?.bodyFat == 17.5)
        #expect(pounds.weights.first?.at == at("2026-10-05", 6, 45))
    }

    @Test func programSettingsBecomeManualPlanVersionsWithTheirGoal() throws {
        let export = try read()
        #expect(export.plans.map(\.startDate.description) == ["2026-09-01", "2026-09-21"], "The 3-weekday version is left out")
        let first = export.plans[0], second = export.plans[1]
        #expect(first.mode == .manual && first.targets.allSatisfy { $0 == DailyTargets(energy: 2200, protein: 160, fat: 75, carbohydrate: 220) })
        #expect(first.goal == NutritionGoal(.lose, weeklyRate: 0.005, goalWeight: .kg(78)))
        #expect(first.weekdayWeights == Array(repeating: 1, count: 7))
        #expect(second.targets(on: LocalDate("2026-10-03")!)?.energy == 2500, "Oct 3, 2026 is a Saturday")
        #expect(second.targets(on: LocalDate("2026-10-05")!)?.energy == 2100)
        #expect(second.validationErrors.isEmpty && second.weekdayWeights[6] > second.weekdayWeights[0])
        #expect(export.report.skipped.contains { $0.reason.contains("3 of 7 weekdays") })
    }

    @Test func customFoodsFavoritesAndRecipesJoinTheLibrary() throws {
        let foods = try read().foods
        #expect(foods.map(\.name) == ["Synthetic Oats", "Fixture Protein Bar", "Test Greek Yogurt", "Fixture Chili"])
        let bar = foods[1]
        #expect(bar.favorite && bar.brand == "Test Co" && bar.servings == [Serving("1 bar", grams: 60)], "Custom and favorite are one food")
        #expect(close(bar.per100g.energy, 220 / 0.6) && bar.source == .imported)
        #expect(foods[2].favorite && !foods[0].favorite)
        let chili = foods[3]
        #expect(chili.source == .recipe && chili.ingredients?.map(\.food.name) == ["Synthetic Beans", "Synthetic Beef"])
        #expect(chili.servingCount == 4 && chili.recipeGrams == 500 && close(chili.per100g.energy, (260 + 750) / 5))
    }

    @Test func workoutsMapExercisesByNameAndReportTheRest() throws {
        let export = try read()
        #expect(export.sessions.map(\.name) == ["Push A", "Cardio"])
        let push = export.sessions[0]
        #expect(push.exercises.map(\.exerciseID) == ["barbell-bench-press", "dumbbell-lateral-raise", "plank"])
        let bench = push.exercises[0].sets
        #expect(bench.map(\.kind) == [.warmUp, .standard, .failure], "Sets of one exercise gather in order")
        #expect(bench.map(\.primary.load) == [.kg(40), .kg(80), .kg(70)] && bench.map(\.primary.reps) == [10, 8, 9])
        #expect(bench.map(\.rir) == [nil, 2, 0])
        #expect(push.exercises[1].sets[0].rir == 6, "6+ RIR is 6")
        #expect(push.exercises[2].sets[0].primary.duration == 60)
        #expect(push.startedAt == WeightTrend.noon(on: LocalDate("2026-10-01")!, in: newYork) && push.duration == 3600)
        #expect(push.bodyweight == .kg(82.1), "The latest weigh-in on or before the day")
        #expect(push.exercises.flatMap(\.sets).allSatisfy { $0.completedAt.map { $0 > push.startedAt && $0 <= push.endedAt! } == true })
        #expect(throws: Never.self) { try push.validate(library: .bundled) }

        let run = export.sessions[1].exercises[0].sets[0].primary
        #expect(run.distance == 5000 && run.duration == 1500, "5 km in the long distance column")

        #expect(export.report.unmappedExercises == ["Synthetic Zercher Hop": 1])
        #expect(export.report.skipped.contains { $0.sheet == "Workouts" && $0.row == 8 && $0.reason.contains("Back Squat") },
                "A squat without a weight isn't a loggable set")
    }

    @Test func aWorkoutKeepsItsIDWhenTheFileIsReadInAnotherZone() throws {
        let london = MacroFactorExport(try Spreadsheet.xlsx(XLSXBuilder(MacroFactorFixture.sheets).data()),
                                       timeZone: TimeZone(identifier: "Europe/London")!, unit: .kilograms,
                                       locale: Locale(identifier: "en_US"), now: Fixture.instant())
        #expect(london.sessions.map(\.id) == (try read()).sessions.map(\.id), "Known by the start the file writes, not an instant")
    }

    /// An import's writes show once the outermost transaction commits, never on
    /// a rollback, and hidden suggestions are a kind it can write.
    @Test func writeAllPublishesAfterTheCommitAndTakesHiddenSuggestions() throws {
        let (_, source, _) = try stores()
        let oats = try source.log(Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380])), grams: 80,
                                  on: LocalDate("2026-10-01")!, meal: "Breakfast", at: Fixture.instant())
        try source.hideSuggestion(oats.food)
        let hidden = try #require(source.hiddenSuggestions.first)
        let entry = try #require(try source.payload(kind: NutritionStore.entryKind, id: oats.id.uuidString))
        let suggestion = try #require(try source.payload(kind: NutritionStore.hiddenKind, id: hidden.id))

        let (persistence, store, _) = try stores()
        try persistence.performAtomically {
            try store.writeAll(kind: NutritionStore.entryKind, [(oats.id.uuidString, entry)])
            #expect(store.entries.isEmpty, "Not shown while the caller's transaction is open")
        }
        #expect(store.entries.map(\.id) == [oats.id], "Shown once it commits")
        try store.writeAll(kind: NutritionStore.hiddenKind, [(hidden.id, suggestion)])
        #expect(store.hiddenSuggestions.map(\.id) == [hidden.id])

        struct Abandoned: Error {}
        #expect(throws: Abandoned.self) {
            try persistence.performAtomically {
                try store.writeAll(kind: NutritionStore.entryKind, [(oats.id.uuidString, nil)])
                throw Abandoned()
            }
        }
        #expect(store.entries.map(\.id) == [oats.id], "A rolled-back removal isn't shown")
    }

    @Test func skippedRowsUnknownColumnsAndLeftOutSheetsAreReported() throws {
        let report = try read().report
        let foodLog = report.skipped.filter { $0.sheet == "Food Log" }
        #expect(foodLog.map(\.row) == [8, 9, 10])
        #expect(foodLog[0].reason == "No readable date: not a date" && foodLog[1].reason == "No food name")
        #expect(foodLog[2].reason.contains("negative amount of energy"))
        #expect(report.skipped.contains { $0.sheet == "Scale Weight" && $0.row == 5 })
        #expect(report.skipped.contains { $0.sheet == "Custom Foods" && $0.reason.contains("Weightless Snack: no serving weight") })
        #expect(report.unknownColumns == ["Food Log": ["Mystery Column"], "Micronutrients": ["Glitter (sparkles)"]])
        #expect(report.unusedColumns["Calories & Macros"] == ["Target Calories (kcal)"])
        #expect(report.unusedColumns["Nutrition Program Settings"] == ["Expenditure (kcal)", "Daily Average (kcal)", "Weight (kg)",
                                                                       "Expenditure Calculation Mode"])
        #expect(report.unusedColumns["Workouts"] == ["Exercise Base Weight (kg)"])
        let leftOut = Dictionary(uniqueKeysWithValues: report.sheets.filter { !$0.imported }.map { ($0.name, $0.detail) })
        #expect(Set(leftOut.keys) == ["Weight Trend", "Expenditure", "History", "Muscle Groups - Sets", "Mystery Sheet"])
        #expect(leftOut["Mystery Sheet"] == "Not recognised as MacroFactor data.")
        #expect(report.sheets.first { $0.name == "Food Log" }?.detail == "Food log, 6 rows")
    }

    @Test func aCSVForEachSheetImportsLikeTheWorkbook() throws {
        let foodLog = """
        Date,Time,Food Name,Serving Size,Serving Qty,Serving Weight (g),Calories (kcal),Protein (g),Carbs (g),Fat (g)
        13/10/2026,07:30 AM,Synthetic Oats,cup,1,80,300,10,54,5
        14/10/2026,7:38 PM,"Pasta, cooked",cup,2,280,440,16,86,2.6
        """
        let weights = "date;weight (kg);fat percent\n13/10/2026;82,4;18,5\n"
        let export = try MacroFactorExport.read([("Food Log.csv", Data(foodLog.utf8)), ("Scale Weight.csv", Data(weights.utf8))],
                                                timeZone: newYork, unit: .pounds, locale: Locale(identifier: "en_US"), now: Fixture.instant())
        #expect(export.entries.map(\.date.description) == ["2026-10-13", "2026-10-14"], "13/10 can only be day first")
        #expect(export.entries[1].food.name == "Pasta, cooked" && export.entries[1].loggedAt == at("2026-10-14", 19, 38))
        #expect(export.entries[1].serving == Serving("1 cup", grams: 140) && export.entries[1].quantity == 2)
        #expect(export.weights.first?.weight == .kg(82.4) && export.weights.first?.bodyFat == 18.5)
        #expect(export.days.map(\.status) == [.complete, .complete])

        let workbook = try read([("Food Log", [[.s("Date"), .s("Time"), .s("Food Name"), .s("Serving Size"), .s("Serving Qty"),
                                                .s("Serving Weight (g)"), .s("Calories (kcal)"), .s("Protein (g)"), .s("Carbs (g)"), .s("Fat (g)")],
                                               [.date(46308), .time(7.5 / 24), .s("Synthetic Oats"), .s("cup"), .n(1), .n(80), .n(300), .n(10),
                                                .n(54), .n(5)]])])
        #expect(workbook.entries.first?.id == export.entries.first?.id, "The same row in a CSV and a workbook is one entry")
    }

    // MARK: Saving

    @Test func savingPutsEverythingInTheStoresAndAgainChangesNothing() throws {
        let (persistence, nutrition, training) = try stores()
        let export = try read()
        let first = MacroFactorImport(export, nutrition: nutrition, training: training)
        #expect(first.summary[.foods] == .init(new: 4) && first.summary[.entries] == .init(new: 6))
        #expect(first.summary[.dayTotals] == .init(new: 2) && first.summary[.days] == .init(new: 5))
        #expect(first.summary[.weights] == .init(new: 4) && first.summary[.plans] == .init(new: 2) && first.summary[.workouts] == .init(new: 2))
        #expect(first.summary.dateRange == LocalDate("2026-09-28")!...LocalDate("2026-10-04")!)
        #expect(first.steps == MacroFactorImportSummary.Kind.allCases)
        #expect(first.save(nutrition: nutrition, training: training).failures.isEmpty)

        #expect(nutrition.foods.count == 4 && nutrition.entries.count == 8 && nutrition.weights.count == 4 && nutrition.plans.count == 2)
        #expect(nutrition.day(LocalDate("2026-10-03")!).status == .fasting)
        #expect(nutrition.day(LocalDate("2026-10-01")!).notes == "Synthetic note: travel day")
        #expect(close(nutrition.summary(on: LocalDate("2026-10-01")!).totals.energy, 738))
        #expect(training.history.sessions.count == 2)
        #expect(nutrition.recentFoods().map(\.name).contains("Synthetic Oats"))
        #expect(!nutrition.recentFoods().map(\.name).contains(MacroFactorExport.dayTotalName))
        // The trend and expenditure can use the imported days.
        let balance = nutrition.energyBalanceDays(from: LocalDate("2026-09-28")!, through: LocalDate("2026-10-04")!)
        let intake = balance.compactMap(\.intake)
        #expect(intake.count == 4 && zip(intake, [2150, 738, 1150, 0]).allSatisfy { close($0, $1) },
                "Complete and fasting days count; partial and unlogged ones don't")

        let documents = persistence.documents, sessions = persistence.sessions
        let again = MacroFactorImport(try read(), nutrition: nutrition, training: training)
        #expect(again.steps.isEmpty && again.summary.additions == 0)
        #expect(again.summary[.entries] == .init(existing: 6) && again.summary[.workouts] == .init(existing: 2))
        #expect(again.save(nutrition: nutrition, training: training).failures.isEmpty)
        #expect(persistence.documents == documents && persistence.sessions == sessions, "Importing twice changes nothing")

        let reopened = try NutritionStore(persistence: persistence)
        #expect(reopened.entries == nutrition.entries && reopened.weights == nutrition.weights && reopened.plans == nutrition.plans)
    }

    @Test func whatExerlyAlreadyHasIsKept() throws {
        let (_, nutrition, training) = try stores()
        // A weigh-in from Apple Health within 0.1 kg of MacroFactor's on Sep 28.
        try nutrition.importHealthWeights([HealthWeight(id: UUID(), at: at("2026-09-28", 7), kilograms: 82.45)], timeZone: newYork)
        // A day the person marked partial, and food logged in Exerly on Sep 29.
        try nutrition.setStatus(.partial, on: LocalDate("2026-10-02")!)
        let food = Food(name: "Exerly Toast", per100g: NutrientAmounts([.energy: 250]))
        try nutrition.log(food, grams: 60, on: LocalDate("2026-09-29")!, meal: "Breakfast", at: at("2026-09-29", 8))
        // Exerly's own targets from Sep 15.
        try nutrition.importDocument(NutritionPlan(startDate: LocalDate("2026-09-15")!, goal: NutritionGoal(.maintain), mode: .manual,
                                                    targets: Array(repeating: DailyTargets(energy: 2300, protein: 150, fat: 80, carbohydrate: 250), count: 7)))

        let plan = MacroFactorImport(try read(), nutrition: nutrition, training: training)
        #expect(plan.summary[.weights] == .init(new: 3, existing: 1))
        #expect(plan.summary[.dayTotals] == .init(new: 1, existing: 1), "Sep 29 already has food in Exerly")
        #expect(plan.summary[.days] == .init(new: 4, existing: 1), "Oct 2 stays partial")
        #expect(plan.summary[.plans] == .init(new: 1), "Only the version before Exerly's targets")
        #expect(plan.summary.report.skipped.contains { $0.reason.contains("2026-09-21") && $0.reason.contains("2026-09-15") })
        #expect(plan.summary.report.assumptions.contains("1 day already had food in Exerly, so MacroFactor's totals for them were left out."))
        plan.save(nutrition: nutrition, training: training)
        #expect(nutrition.day(LocalDate("2026-10-02")!).status == .partial)
        #expect(nutrition.plan(on: LocalDate("2026-10-05")!)?.targets.first?.energy == 2300, "Exerly's targets stay in force")
        #expect(nutrition.plan(on: LocalDate("2026-09-10")!)?.targets.first?.energy == 2200)
        #expect(nutrition.weights(on: LocalDate("2026-09-28")!).map(\.source) == [.appleHealth])
    }

    @Test func aFoodLogReplacesDayTotalsFromAnEarlierImport() throws {
        let (_, nutrition, training) = try stores()
        let quick = try read([("Calories & Macros", [[.s("Date"), .s("Calories (kcal)"), .s("Protein (g)")],
                                                     [.date(46296), .n(2000), .n(140)]])])
        MacroFactorImport(quick, nutrition: nutrition, training: training).save(nutrition: nutrition, training: training)
        #expect(nutrition.entries(on: LocalDate("2026-10-01")!).map(\.food.name) == [MacroFactorExport.dayTotalName])

        let granular = MacroFactorImport(try read(), nutrition: nutrition, training: training)
        #expect(granular.summary.replacedDayTotals == 1)
        granular.save(nutrition: nutrition, training: training)
        let names = nutrition.entries(on: LocalDate("2026-10-01")!).map(\.food.name)
        #expect(!names.contains(MacroFactorExport.dayTotalName) && names.count == 4, "The detail replaces the total")
        #expect(MacroFactorImport(try read(), nutrition: nutrition, training: training).steps.isEmpty)
    }

    @Test func theWholeImportSavesAsOneUnit() throws {
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        // A library without the bench press: the workouts can't be saved.
        let library = try ExerciseLibrary(exercises: ExerciseLibrary.bundled.exercises.filter { $0.id != "barbell-bench-press" })
        let training = try TrainingStore(persistence: persistence, library: library, now: { Fixture.instant() })
        let result = MacroFactorImport(try read(), nutrition: nutrition, training: training).save(nutrition: nutrition, training: training)
        #expect(Set(result.failures.keys) == Set(MacroFactorImportSummary.Kind.allCases))
        #expect(training.history.sessions.isEmpty && persistence.sessions.isEmpty, "Neither workout was saved")
        #expect(nutrition.entries.isEmpty && nutrition.weights.isEmpty, "Nor anything else: no half-import")
    }

    @Test func yearsOfHistoryImportInOnePass() throws {
        // Three years: four foods a day, a weigh-in most days, totals for the rest.
        let start = LocalDate("2023-10-01")!
        var foodLog: [[TestCell]] = [MacroFactorFixture.header(["Date", "Time", "Food Name", "Serving Weight (g)", "Calories (kcal)",
                                                                "Protein (g)", "Carbs (g)", "Fat (g)", "Sodium (mg)"])]
        var weights: [[TestCell]] = [MacroFactorFixture.header(["Date", "Weight (kg)"])]
        for offset in 0..<1095 {
            let serial = MacroFactorFixture.serial(start.adding(days: offset))
            for meal in 0..<4 {
                foodLog.append([.date(serial), .time(Double(7 + meal * 4) / 24), .s("Synthetic food \(offset % 40)"), .n(150),
                                .n(400), .n(30), .n(40), .n(12), .n(300)])
            }
            if offset % 5 != 0 { weights.append([.date(serial), .n(84 - Double(offset) * 0.004)]) }
        }
        let (_, nutrition, training) = try stores()
        let clock = ContinuousClock()
        let started = clock.now
        let export = try read([("Food Log", foodLog), ("Scale Weight", weights)])
        let plan = MacroFactorImport(export, nutrition: nutrition, training: training)
        #expect(plan.save(nutrition: nutrition, training: training).failures.isEmpty)
        let elapsed = clock.now - started
        #expect(nutrition.entries.count == 4380 && nutrition.weights.count == 876 && nutrition.days.count == 1095)
        #expect(elapsed < .seconds(30), "Took \(elapsed)")
        #expect(MacroFactorImport(try read([("Food Log", foodLog), ("Scale Weight", weights)]), nutrition: nutrition, training: training)
            .steps.isEmpty)
    }

    @Test func anEmptyOrForeignWorkbookImportsNothingAndSaysWhy() throws {
        let export = try read([("Sheet1", [[.s("Colour"), .s("Shape")], [.s("red"), .s("round")]]), ("Food Log", [])])
        #expect(export.isEmpty && export.dateRange == nil)
        #expect(export.report.sheets == [.init(name: "Sheet1", detail: "Not recognised as MacroFactor data.", imported: false),
                                         .init(name: "Food Log", detail: "Food log, empty", imported: false)])
    }
}

extension NutritionStore {
    /// Saves a document as sync would, for setting up a test.
    fileprivate func importDocument(_ plan: NutritionPlan) throws {
        try prepareWrite(kind: Self.planKind, id: plan.id.uuidString, payload: ExerlyJSON.canonical(plan))()
    }
}
