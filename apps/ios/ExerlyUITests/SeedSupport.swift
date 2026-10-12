import XCTest

/// A synthetic week of logging for realistic screens and usability runs.
extension ExerlyUITestCase {
    struct SeedFood {
        let id = UUID().uuidString
        let name: String
        let per100g: [String: Double]
    }

    /// A week of synthetic logging: breakfast at this time of day on four
    /// days (a habit), plus lunches and dinners on earlier days. Foods get
    /// fresh IDs for every account.
    func seedWeek(token: String) async throws {
        let yogurt = SeedFood(name: "Greek yogurt, plain", per100g: ["energy": 73, "protein": 10, "carbohydrate": 3.9, "fat": 1.9])
        let berries = SeedFood(name: "Blueberries", per100g: ["energy": 57, "protein": 0.7, "carbohydrate": 14.5, "fat": 0.3])
        let oats = SeedFood(name: "Rolled oats", per100g: ["energy": 380, "protein": 13, "carbohydrate": 67, "fat": 7])
        let chicken = SeedFood(name: "Chicken breast, grilled", per100g: ["energy": 165, "protein": 31, "carbohydrate": 0, "fat": 3.6])
        let rice = SeedFood(name: "Jasmine rice, cooked", per100g: ["energy": 130, "protein": 2.7, "carbohydrate": 28, "fat": 0.3])
        let salmon = SeedFood(name: "Salmon fillet", per100g: ["energy": 208, "protein": 20, "carbohydrate": 0, "fat": 13])
        let potato = SeedFood(name: "Roasted potatoes", per100g: ["energy": 149, "protein": 2.5, "carbohydrate": 24, "fat": 4.8])
        for food in [yogurt, berries, oats, chicken, rice, salmon, potato] {
            let payload: [String: Any] = ["id": food.id, "name": food.name, "source": "custom", "per100g": food.per100g,
                                          "servings": [], "favorite": false, "createdAt": "2026-10-01T12:00:00.000Z"]
            _ = try await request("PUT", "/v1/documents/saved_food/\(food.id)", body: ["base_revision": 0, "payload": payload], token: token)
        }
        for day in 1...4 {
            try await seedEntry(yogurt, grams: 170, daysAgo: day, meal: "Breakfast", token: token)
            try await seedEntry(berries, grams: 80, daysAgo: day, meal: "Breakfast", token: token)
            if day % 2 == 0 { try await seedEntry(oats, grams: 50, daysAgo: day, meal: "Breakfast", token: token) }
        }
        try await seedEntry(chicken, grams: 180, daysAgo: 1, meal: "Lunch", minutes: 240, token: token)
        try await seedEntry(rice, grams: 200, daysAgo: 1, meal: "Lunch", minutes: 240, token: token)
        try await seedEntry(salmon, grams: 150, daysAgo: 1, meal: "Dinner", minutes: 480, token: token)
        try await seedEntry(potato, grams: 220, daysAgo: 1, meal: "Dinner", minutes: 480, token: token)
        try await seedEntry(chicken, grams: 150, daysAgo: 3, meal: "Dinner", minutes: 480, token: token)
    }

    /// Logs an entry `daysAgo` days back, `minutes` before now's time of day.
    func seedEntry(_ food: SeedFood, grams: Double, daysAgo: Int, meal: String, minutes: Int = 15, token: String) async throws {
        let id = UUID().uuidString
        let at = Date().addingTimeInterval(Double(-daysAgo * 86_400 - minutes * 60))
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = TimeZone(identifier: "America/New_York")!
        day.dateFormat = "yyyy-MM-dd"
        let instant = ISO8601DateFormatter()
        instant.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry: [String: Any] = ["id": id, "date": day.string(from: at), "meal": meal, "loggedAt": instant.string(from: at),
                                    "food": ["foodID": food.id, "name": food.name, "source": "custom", "per100g": food.per100g],
                                    "grams": grams]
        _ = try await request("PUT", "/v1/documents/food_entry/\(id)", body: ["base_revision": 0, "payload": entry], token: token)
    }

    func signedInWithWeek(prefix: String) async throws -> XCUIApplication {
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "imperial")
        try await seedWeek(token: person.token)
        try await deleteSetupWeight(token: person.token)
        for reading in syntheticReadings(days: 28) {
            let pounds = (reading.kilograms / 0.453_592_37 * 10).rounded() / 10
            try await seedWeighIn(token: person.token, date: reading.date, at: reading.at, value: pounds, unit: "lb")
        }
        _ = try await seedProgram(name: "Strength foundations", activated: "2026-10-01T12:00:00.000Z", token: person.token)
        _ = try await seedTrainingWorkout(name: "Full body", loads: [60, 65, 65], daysAgo: 2,
                                           exercises: ["deadlift", "barbell-bench-press"], token: person.token)
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        return app
    }

    // MARK: Weigh-ins

    /// Setup records its weight for today through the older API; captures want a clean history.
    func deleteSetupWeight(token: String) async throws {
        let row = try await request("GET", "/api/weight/day", token: token)
        guard let id = row["id"] as? String, let revision = row["revision"] as? Int else { return }
        _ = try await request("DELETE", "/api/weight/\(id)?base_revision=\(revision)", token: token)
    }

    func seedWeighIn(token: String, date: String, at: Date, value: Double, unit: String) async throws {
        let id = UUID().uuidString
        let payload: [String: Any] = ["id": id, "at": Self.iso(at), "date": date, "weight": ["unit": unit, "value": value]]
        _ = try await request("PUT", "/v1/documents/weight_entry/\(id)", body: ["base_revision": 0, "payload": payload], token: token)
    }

    /// Eight weeks of a steady cut, weighed most mornings, with food fully logged on most days.
    func seedHistory(token: String) async throws {
        for reading in syntheticReadings(days: 56) {
            let pounds = (reading.kilograms / 0.453_592_37 * 10).rounded() / 10
            try await seedWeighIn(token: token, date: reading.date, at: reading.at, value: pounds, unit: "lb")
        }
        for back in 1...56 where back % 7 != 3 {
            let day = Self.day(-back)
            let id = UUID().uuidString
            let energy = 2150 + 180 * sin(Double(back) * 2.3)
            let food: [String: Any] = ["foodID": "quick:\(id)", "name": "Logged day", "source": "custom", "unweighed": true,
                                       "per100g": ["energy": energy, "protein": 165, "carbohydrate": 210, "fat": 70]]
            let entry: [String: Any] = ["id": id, "date": day.date, "meal": "Dinner", "loggedAt": Self.iso(day.at), "food": food, "grams": 100]
            _ = try await request("PUT", "/v1/documents/food_entry/\(id)", body: ["base_revision": 0, "payload": entry], token: token)
            let status: [String: Any] = ["id": day.date, "date": day.date, "status": "complete", "notes": "", "tags": [String]()]
            _ = try await request("PUT", "/v1/documents/nutrition_day/\(day.date)", body: ["base_revision": 0, "payload": status], token: token)
        }
    }

    /// The account's live documents of a kind, from the change feed.
    func documents(_ kind: String, token: String) async throws -> [[String: Any]] {
        var latest: [String: [String: Any]?] = [:]
        var cursor = 0
        while true {
            let page = try await request("GET", "/v1/changes?after=\(cursor)&limit=1000", token: token)
            for change in page["changes"] as? [[String: Any]] ?? [] where change["kind"] as? String == kind {
                guard let id = change["id"] as? String else { continue }
                latest[id] = change["payload"] as? [String: Any]
            }
            cursor = page["cursor"] as? Int ?? cursor
            guard page["has_more"] as? Bool == true else { break }
        }
        return Array(latest.compactMapValues { $0 }.values)
    }

    func waitForDocuments(_ kind: String, token: String, timeout: Int = 40,
                          _ matches: @escaping ([[String: Any]]) -> Bool) async throws -> [[String: Any]] {
        for _ in 0..<timeout {
            let found = try await documents(kind, token: token)
            if matches(found) { return found }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("The server's \(kind) documents never matched")
        return []
    }

    /// The account's live weigh-in documents by ID, from the change feed.
    func weighIns(token: String) async throws -> [String: [String: Any]] {
        var latest: [String: [String: Any]?] = [:]
        var cursor = 0
        while true {
            let page = try await request("GET", "/v1/changes?after=\(cursor)&limit=1000", token: token)
            for change in page["changes"] as? [[String: Any]] ?? [] where change["kind"] as? String == "weight_entry" {
                guard let id = change["id"] as? String else { continue }
                latest[id] = change["payload"] as? [String: Any]
            }
            cursor = page["cursor"] as? Int ?? cursor
            guard page["has_more"] as? Bool == true else { break }
        }
        return latest.compactMapValues { $0 }
    }

    func waitForWeighIn(token: String, timeout: Int = 40, _ matches: @escaping ([String: Any]) -> Bool) async throws -> [String: Any]? {
        for _ in 0..<timeout {
            if let found = try await weighIns(token: token).values.first(where: matches) { return found }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("No matching weigh-in reached the server")
        return nil
    }

    struct Reading {
        let date: String
        let kilograms: Double
        let at: Date
    }

    static let newYork = TimeZone(identifier: "America/New_York")!

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A local date in New York `offset` days from today, and 07:10 that morning.
    static func day(_ offset: Int) -> (date: String, at: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = newYork
        formatter.dateFormat = "yyyy-MM-dd"
        let at = offset == 0 ? min(Date(), calendar.date(bySettingHour: 7, minute: 10, second: 0, of: date)!)
            : calendar.date(bySettingHour: 7, minute: 10, second: 0, of: date)!
        return (formatter.string(from: date), at)
    }

    /// A steady cut of about 0.45 kg a week with water swings, weighed on most mornings.
    func syntheticReadings(days: Int) -> [Reading] {
        (1...days).reversed().compactMap { back -> Reading? in
            guard back % 9 != 4, back % 13 != 6 else { return nil }
            let day = Double(days - back)
            let water = 0.42 * sin(day * 1.7) + 0.22 * sin(day * 0.53 + 1) + 0.12 * cos(day * 3.1)
            let kilograms = ((84.2 - 0.064 * day + water) * 10).rounded() / 10
            let local = Self.day(-back)
            return Reading(date: local.date, kilograms: kilograms, at: local.at.addingTimeInterval(Double(back % 20) * 60))
        }
    }
}

/// Four weeks of an imperial account's life, for usability runs and the
/// remote-control driver: meals at their usual New York times with full
/// labels, most days marked complete, a coached plan from four weeks ago, a
/// four-day split progressing in round pounds, and weigh-ins drifting down.
/// Separate from `seedWeek`, which the tap-budget tests count on.
extension ExerlyUITestCase {
    func signedInWithRealisticHistory(prefix: String) async throws -> XCUIApplication {
        let started = Date()
        try await control([:])
        let person = try await createAccount(prefix: prefix, units: "imperial")
        try await deleteSetupWeight(token: person.token)
        let count = try await seedRealisticHistory(token: person.token)
        print("Seeded \(count) documents of realistic history in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        return app
    }

    /// Writes the history and returns how many documents it wrote.
    @discardableResult
    func seedRealisticHistory(token: String, days: Int = 28) async throws -> Int {
        var documents: [(kind: String, id: String, payload: [String: Any])] = []
        let foods = RealisticFood.all
        for food in foods.values {
            documents.append(("saved_food", food.id, ["id": food.id, "name": food.name, "source": "custom", "per100g": food.per100g,
                                                       "servings": [], "favorite": food.favorite, "createdAt": Self.iso(Self.local(-days - 2, 9, 0))]))
        }
        documents += realisticMeals(foods: foods, days: days)
        documents += realisticWeighIns(days: days)
        documents.append(realisticPlan(days: days))
        let program = realisticProgram(days: days)
        documents.append(("program", program.id, program.payload))
        documents += realisticWorkouts(program: program, days: days)
        try await Self.putAll(documents, fixture: fixtureURL, token: token)
        return documents.count
    }

    // MARK: Food

    struct RealisticFood {
        let id = UUID().uuidString
        let name: String
        let per100g: [String: Double]
        var favorite = false

        /// Synthetic per-100 g values in the range USDA reports for these foods.
        static var all: [String: RealisticFood] {
            func food(_ name: String, _ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double, fiber: Double, sugars: Double,
                      saturated: Double, sodium: Double, potassium: Double, calcium: Double, iron: Double, vitaminC: Double,
                      favorite: Bool = false) -> RealisticFood {
                RealisticFood(name: name, per100g: ["energy": kcal, "protein": protein, "carbohydrate": carbs, "fat": fat, "fiber": fiber,
                                                    "sugars": sugars, "saturatedFat": saturated, "sodium": sodium, "potassium": potassium,
                                                    "calcium": calcium, "iron": iron, "vitaminC": vitaminC], favorite: favorite)
            }
            let list = [
                food("Greek yogurt, plain nonfat", 59, 10.2, 3.6, 0.4, fiber: 0, sugars: 3.2, saturated: 0.1, sodium: 36, potassium: 141,
                     calcium: 110, iron: 0.1, vitaminC: 0, favorite: true),
                food("Blueberries", 57, 0.7, 14.5, 0.3, fiber: 2.4, sugars: 10, saturated: 0, sodium: 1, potassium: 77, calcium: 6,
                     iron: 0.3, vitaminC: 9.7),
                food("Rolled oats", 379, 13.2, 67.7, 6.5, fiber: 10.1, sugars: 1, saturated: 1.1, sodium: 6, potassium: 362, calcium: 52,
                     iron: 4.3, vitaminC: 0),
                food("Banana", 89, 1.1, 22.8, 0.3, fiber: 2.6, sugars: 12.2, saturated: 0.1, sodium: 1, potassium: 358, calcium: 5,
                     iron: 0.3, vitaminC: 8.7),
                food("Eggs, scrambled", 149, 10, 1.6, 11, fiber: 0, sugars: 1.4, saturated: 3.3, sodium: 145, potassium: 132, calcium: 66,
                     iron: 1.3, vitaminC: 0),
                food("Whole wheat toast", 252, 12.4, 42.7, 3.5, fiber: 6, sugars: 4.4, saturated: 0.7, sodium: 450, potassium: 250,
                     calcium: 160, iron: 2.5, vitaminC: 0),
                food("Chicken breast, grilled", 165, 31, 0, 3.6, fiber: 0, sugars: 0, saturated: 1, sodium: 74, potassium: 256, calcium: 15,
                     iron: 1, vitaminC: 0, favorite: true),
                food("Jasmine rice, cooked", 129, 2.7, 28, 0.3, fiber: 0.4, sugars: 0.1, saturated: 0.1, sodium: 1, potassium: 35,
                     calcium: 10, iron: 1.2, vitaminC: 0),
                food("Broccoli, steamed", 35, 2.4, 7.2, 0.4, fiber: 3.3, sugars: 1.4, saturated: 0.1, sodium: 41, potassium: 293,
                     calcium: 40, iron: 0.7, vitaminC: 64.9),
                food("Turkey breast, sliced", 104, 17, 4, 1.7, fiber: 0.5, sugars: 3.5, saturated: 0.5, sodium: 1015, potassium: 300,
                     calcium: 10, iron: 0.6, vitaminC: 0),
                food("Mixed green salad", 17, 1.2, 3.3, 0.2, fiber: 2, sugars: 1.2, saturated: 0, sodium: 28, potassium: 250, calcium: 36,
                     iron: 1, vitaminC: 15),
                food("Apple", 52, 0.3, 13.8, 0.2, fiber: 2.4, sugars: 10.4, saturated: 0, sodium: 1, potassium: 107, calcium: 6,
                     iron: 0.1, vitaminC: 4.6),
                food("Black beans, cooked", 132, 8.9, 23.7, 0.5, fiber: 8.7, sugars: 0.3, saturated: 0.1, sodium: 1, potassium: 355,
                     calcium: 27, iron: 2.1, vitaminC: 0),
                food("Flour tortilla", 304, 8.4, 50, 7.6, fiber: 3.5, sugars: 2.6, saturated: 2.9, sodium: 630, potassium: 140,
                     calcium: 150, iron: 3.5, vitaminC: 0),
                food("Cheddar cheese", 403, 22.9, 3.1, 33.1, fiber: 0, sugars: 0.5, saturated: 18.9, sodium: 653, potassium: 76,
                     calcium: 721, iron: 0.1, vitaminC: 0),
                food("Salmon fillet, baked", 206, 22.1, 0, 12.4, fiber: 0, sugars: 0, saturated: 2.5, sodium: 61, potassium: 384,
                     calcium: 15, iron: 0.3, vitaminC: 3.7),
                food("Roasted potatoes", 149, 2.5, 24, 4.8, fiber: 2.2, sugars: 1.2, saturated: 0.7, sodium: 290, potassium: 420,
                     calcium: 10, iron: 0.6, vitaminC: 11),
                food("Whole wheat pasta, cooked", 149, 6, 30, 1.7, fiber: 3.9, sugars: 0.8, saturated: 0.3, sodium: 4, potassium: 96,
                     calcium: 15, iron: 1.7, vitaminC: 0),
                food("Marinara sauce", 50, 1.5, 8, 1.5, fiber: 2, sugars: 5.5, saturated: 0.2, sodium: 430, potassium: 320, calcium: 30,
                     iron: 0.8, vitaminC: 8),
                food("Ground turkey, 93% lean, cooked", 176, 23.5, 0, 9, fiber: 0, sugars: 0, saturated: 2.3, sodium: 80, potassium: 300,
                     calcium: 25, iron: 1.4, vitaminC: 0),
                food("Olive oil", 884, 0, 0, 100, fiber: 0, sugars: 0, saturated: 13.8, sodium: 2, potassium: 1, calcium: 1, iron: 0.6,
                     vitaminC: 0),
                food("Almonds", 579, 21.2, 21.6, 49.9, fiber: 12.5, sugars: 4.4, saturated: 3.8, sodium: 1, potassium: 733, calcium: 269,
                     iron: 3.7, vitaminC: 0),
                food("Whey protein powder", 400, 78, 10, 6, fiber: 1, sugars: 6, saturated: 3, sodium: 300, potassium: 500, calcium: 450,
                     iron: 1, vitaminC: 0, favorite: true),
            ]
            return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        }
    }

    /// Breakfast about 7:30, lunch about 12:30, dinner about 19:00 and an
    /// evening snack, rotating through a few usual meals. Today keeps only the
    /// meals already past. Most past days are marked complete; a few are left
    /// partial or unlogged.
    private func realisticMeals(foods: [String: RealisticFood], days: Int) -> [(kind: String, id: String, payload: [String: Any])] {
        typealias Item = (String, Double)
        let breakfasts: [[Item]] = [
            [("Greek yogurt, plain nonfat", 200), ("Blueberries", 80), ("Rolled oats", 40)],
            [("Eggs, scrambled", 120), ("Whole wheat toast", 60), ("Banana", 118)],
            [("Rolled oats", 60), ("Banana", 100), ("Whey protein powder", 30)],
        ]
        let lunches: [[Item]] = [
            [("Chicken breast, grilled", 150), ("Jasmine rice, cooked", 180), ("Broccoli, steamed", 120)],
            [("Turkey breast, sliced", 90), ("Whole wheat toast", 70), ("Mixed green salad", 100), ("Apple", 180)],
            [("Black beans, cooked", 130), ("Jasmine rice, cooked", 150), ("Flour tortilla", 50), ("Cheddar cheese", 28)],
        ]
        let dinners: [[Item]] = [
            [("Salmon fillet, baked", 150), ("Roasted potatoes", 200), ("Mixed green salad", 100), ("Olive oil", 10)],
            [("Whole wheat pasta, cooked", 200), ("Marinara sauce", 125), ("Ground turkey, 93% lean, cooked", 110)],
            [("Chicken breast, grilled", 160), ("Jasmine rice, cooked", 160), ("Broccoli, steamed", 150), ("Olive oil", 8)],
            [("Black beans, cooked", 120), ("Flour tortilla", 70), ("Cheddar cheese", 30), ("Mixed green salad", 80)],
        ]
        let snacks: [[Item]] = [
            [("Greek yogurt, plain nonfat", 150), ("Blueberries", 50)],
            [("Almonds", 28), ("Apple", 150)],
            [("Whey protein powder", 30), ("Banana", 100)],
        ]
        let now = Date()
        var documents: [(kind: String, id: String, payload: [String: Any])] = []
        for back in 0...days {
            let date = Self.day(-back).date
            let unlogged = back > 0 && back % 13 == 6
            let partial = back > 0 && back % 9 == 4
            guard !unlogged else { continue }
            // A few minutes' drift each day, so times look logged by hand.
            let drift = (back * 7) % 25 - 12
            var meals: [(String, [Item], Int, Int)] = [
                ("Breakfast", breakfasts[back % breakfasts.count], 7, 30 + drift / 2),
                ("Lunch", lunches[(back / 2) % lunches.count], 12, 30 + drift),
            ]
            // A partial day is one where dinner never got logged.
            if !partial { meals.append(("Dinner", dinners[back % dinners.count], 19, drift)) }
            if back % 3 != 1 { meals.append(("Snacks", snacks[back % snacks.count], 21, 15 + drift / 2)) }
            for (meal, items, hour, minute) in meals {
                let at = Self.local(-back, hour, minute)
                guard at < now else { continue }
                for (offset, (name, grams)) in items.enumerated() {
                    guard let food = foods[name] else { continue }
                    let id = UUID().uuidString
                    let logged = at.addingTimeInterval(Double(offset * 40))
                    documents.append(("food_entry", id, ["id": id, "date": date, "meal": meal, "loggedAt": Self.iso(logged), "grams": grams,
                                                         "food": ["foodID": food.id, "name": food.name, "source": "custom", "per100g": food.per100g]]))
                }
            }
            if back > 0 {
                documents.append(("nutrition_day", date, ["id": date, "date": date, "status": partial ? "partial" : "complete",
                                                          "notes": "", "tags": [String]()]))
            }
        }
        return documents
    }

    // MARK: Weight and plan

    /// Weighed on most mornings, about 0.2 kg a week down with water swings, in pounds.
    private func realisticWeighIns(days: Int) -> [(kind: String, id: String, payload: [String: Any])] {
        (1...days).reversed().compactMap { back -> (kind: String, id: String, payload: [String: Any])? in
            guard back % 9 != 4, back % 11 != 7 else { return nil }
            let day = Double(days - back)
            let water = 0.35 * sin(day * 1.7) + 0.2 * sin(day * 0.53 + 1) + 0.1 * cos(day * 3.1)
            let kilograms = 73.3 - 0.028 * day + water
            let pounds = (kilograms / 0.453_592_37 * 10).rounded() / 10
            let id = UUID().uuidString
            let at = Self.local(-back, 6, 55 + back % 20)
            return ("weight_entry", id, ["id": id, "at": Self.iso(at), "date": Self.day(-back).date, "weight": ["unit": "lb", "value": pounds]])
        }
    }

    /// A coached plan losing 0.25 % a week, started four weeks ago from
    /// setup's formula, with check-ins on Mondays. Targets as ExerlyCore works them out.
    private func realisticPlan(days: Int) -> (kind: String, id: String, payload: [String: Any]) {
        let id = UUID().uuidString
        let expenditure = 1978.0, trend = 73.3, rate = 0.0025
        let energy = (expenditure - rate * trend * 7700 / 7).rounded()
        let protein = (1.8 * trend).rounded()
        let fat = max(0.3 * energy / 9, 0.6 * trend).rounded()
        let carbohydrate = ((energy - protein * 4 - fat * 9) / 4).rounded(.down)
        let day: [String: Any] = ["energy": energy, "protein": protein, "fat": fat, "carbohydrate": carbohydrate]
        let start = Self.day(-days)
        return ("nutrition_plan", id, [
            "id": id, "startDate": start.date, "createdAt": Self.iso(start.at), "goal": ["direction": "lose", "weeklyRate": rate],
            "mode": "coached", "diet": "balanced", "protein": "moderate", "weekdayWeights": Array(repeating: 1.0, count: 7),
            "checkInDay": 2, "allowBelowFloor": false, "targets": Array(repeating: day, count: 7),
            "basis": ["expenditure": expenditure, "expenditureError": 300, "trendWeight": trend],
        ])
    }

    // MARK: Training

    struct RealisticSlot {
        let slotID = UUID().uuidString
        let exercise: String
        let sets: Int
        let reps: ClosedRange<Int>
        /// Starting load in pounds and the step added every `every` cycles.
        let start: Double
        let step: Double
        var every = 1
    }

    struct RealisticProgram {
        let id: String
        let days: [(id: String, name: String, slots: [RealisticSlot])]
        let payload: [String: Any]
    }

    /// Push, Pull, Legs and Upper, with rows, pulldowns and curls on Pull.
    private func realisticProgram(days: Int) -> RealisticProgram {
        let split: [(String, [RealisticSlot])] = [
            ("Push", [RealisticSlot(exercise: "barbell-bench-press", sets: 3, reps: 5...8, start: 95, step: 5),
                      RealisticSlot(exercise: "overhead-press", sets: 3, reps: 6...10, start: 60, step: 5, every: 2),
                      RealisticSlot(exercise: "incline-dumbbell-bench-press", sets: 3, reps: 8...12, start: 30, step: 5, every: 2),
                      RealisticSlot(exercise: "dumbbell-lateral-raise", sets: 3, reps: 12...20, start: 10, step: 5, every: 3),
                      RealisticSlot(exercise: "triceps-pushdown", sets: 3, reps: 10...15, start: 35, step: 5, every: 2)]),
            ("Pull", [RealisticSlot(exercise: "barbell-row", sets: 3, reps: 6...10, start: 85, step: 5),
                      RealisticSlot(exercise: "lat-pulldown", sets: 3, reps: 8...12, start: 80, step: 5),
                      RealisticSlot(exercise: "seated-cable-row", sets: 3, reps: 10...12, start: 70, step: 5, every: 2),
                      RealisticSlot(exercise: "face-pull", sets: 2, reps: 12...20, start: 25, step: 5, every: 2),
                      RealisticSlot(exercise: "dumbbell-curl", sets: 3, reps: 8...12, start: 15, step: 5, every: 2),
                      RealisticSlot(exercise: "hammer-curl", sets: 2, reps: 10...15, start: 15, step: 5, every: 3)]),
            ("Legs", [RealisticSlot(exercise: "back-squat", sets: 3, reps: 5...8, start: 135, step: 10),
                      RealisticSlot(exercise: "romanian-deadlift", sets: 3, reps: 6...10, start: 115, step: 10),
                      RealisticSlot(exercise: "leg-press", sets: 3, reps: 10...15, start: 180, step: 10),
                      RealisticSlot(exercise: "lying-leg-curl", sets: 3, reps: 10...15, start: 60, step: 5, every: 2),
                      RealisticSlot(exercise: "standing-calf-raise", sets: 3, reps: 10...15, start: 90, step: 10, every: 2)]),
            ("Upper", [RealisticSlot(exercise: "dumbbell-bench-press", sets: 3, reps: 8...12, start: 35, step: 5, every: 2),
                       RealisticSlot(exercise: "chest-supported-dumbbell-row", sets: 3, reps: 8...12, start: 30, step: 5, every: 2),
                       RealisticSlot(exercise: "seated-dumbbell-shoulder-press", sets: 3, reps: 8...12, start: 25, step: 5, every: 2),
                       RealisticSlot(exercise: "close-grip-lat-pulldown", sets: 3, reps: 10...12, start: 70, step: 5, every: 2),
                       RealisticSlot(exercise: "ez-bar-curl", sets: 2, reps: 10...12, start: 40, step: 5, every: 2),
                       RealisticSlot(exercise: "overhead-cable-triceps-extension", sets: 2, reps: 10...15, start: 30, step: 5, every: 2)]),
        ]
        let id = UUID().uuidString
        let programDays = split.map { (id: UUID().uuidString, name: $0.0, slots: $0.1) }
        let payload: [String: Any] = [
            "id": id, "name": "Push, pull, legs, upper", "cycles": 8, "deload": "none",
            "createdAt": Self.iso(Self.local(-days - 1, 20, 0)), "activatedAt": Self.iso(Self.local(-days - 1, 20, 1)),
            "days": programDays.map { day -> [String: Any] in
                ["id": day.id, "name": day.name, "slots": day.slots.map { slot -> [String: Any] in
                    ["id": slot.slotID, "exerciseID": slot.exercise, "notes": "", "cycleTargets": [String: Any](),
                     "expandRepRange": false, "weightMatch": true,
                     "target": ["sets": slot.sets, "minReps": slot.reps.lowerBound, "maxReps": slot.reps.upperBound, "rir": 2,
                                "kind": "standard"]]
                }]
            },
        ]
        return RealisticProgram(id: id, days: programDays, payload: payload)
    }

    /// About three sessions a week through the split at 17:30: three full
    /// cycles, then Push two days ago, so Pull is next. Loads are whole pounds
    /// in kilograms at full precision (135 lb is 61.235 kg), so imperial shows
    /// round numbers and an equal load is never a record. Reps climb through
    /// each range and the load steps up between cycles.
    private func realisticWorkouts(program: RealisticProgram, days: Int) -> [(kind: String, id: String, payload: [String: Any])] {
        let schedule = [26, 24, 22, 20, 19, 17, 15, 13, 12, 10, 8, 5, 2].filter { $0 < days }
        return schedule.enumerated().map { index, back in
            let day = program.days[index % program.days.count]
            let cycle = index / program.days.count
            let start = Self.local(-back, 17, 30)
            var minute = 3.0
            let exercises = day.slots.map { slot -> [String: Any] in
                let pounds = slot.start + slot.step * Double(cycle / slot.every)
                let spread = slot.reps.upperBound - slot.reps.lowerBound
                let top = slot.reps.lowerBound + min(spread, 2 + (cycle % slot.every) * 2)
                let sets = (0..<slot.sets).map { set -> [String: Any] in
                    minute += 2.5
                    let reps = max(slot.reps.lowerBound, top - set)
                    return ["id": UUID().uuidString, "kind": "standard", "rir": set == slot.sets - 1 ? 1 : 2,
                            "completedAt": Self.iso(start.addingTimeInterval(minute * 60)),
                            "efforts": [["reps": reps, "load": ["unit": "kg", "value": pounds * 0.453_592_37]]]]
                }
                return ["id": UUID().uuidString, "exerciseID": slot.exercise, "notes": "", "sets": sets, "slotID": slot.slotID]
            }
            let id = UUID().uuidString
            return ("workout_session", id, [
                "id": id, "name": day.name, "notes": "", "startedAt": Self.iso(start), "timeZoneID": "America/New_York",
                "endedAt": Self.iso(start.addingTimeInterval((minute + 4) * 60)), "exercises": exercises,
                "program": ["programID": program.id, "dayID": day.id, "cycle": cycle],
            ])
        }
    }

    // MARK: Writing

    /// `offset` days from today in New York, at a local time; minutes past
    /// 59 or below 0 roll into the next or previous hour.
    static func local(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
        return calendar.date(byAdding: .minute, value: minute, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!)!
    }

    /// PUTs every document, a dozen at a time, so a month of history seeds in
    /// seconds. Parallel writes can collide in the server's database, which
    /// rolls one back with a 500; that one is sent again.
    static func putAll(_ documents: [(kind: String, id: String, payload: [String: Any])], fixture: String, token: String) async throws {
        let requests = try documents.map { document -> (URL, Data) in
            (URL(string: "\(fixture)/v1/documents/\(document.kind)/\(document.id)")!,
             try JSONSerialization.data(withJSONObject: ["base_revision": 0, "payload": document.payload]))
        }
        let zone = TimeZone.current.identifier
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = requests.makeIterator()
            func start() -> Bool {
                guard let (url, body) = next.next() else { return false }
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "PUT"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("isolated-simulator", forHTTPHeaderField: "X-Test-Fixture")
                    request.setValue(zone, forHTTPHeaderField: "X-Timezone")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    for attempt in 1...5 {
                        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if (200..<300).contains(status) { return }
                        guard status >= 500, attempt < 5 else {
                            throw NSError(domain: "Seed", code: status, userInfo: [NSLocalizedDescriptionKey:
                                "\(url.path): \(String(data: data, encoding: .utf8) ?? "")"])
                        }
                        try await Task.sleep(for: .milliseconds(100 * attempt))
                    }
                }
                return true
            }
            for _ in 0..<12 where start() {}
            while try await group.next() != nil { _ = start() }
        }
    }
}
