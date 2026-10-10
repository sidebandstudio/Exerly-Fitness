import Foundation
import Testing
@testable import ExerlyCore

/// The Foods the API maps from Open Food Facts, in docs/api/golden/foods-v1.json,
/// which apps/api/tests/foods.golden.test.js asserts on the server side. If
/// these decode, the phone can read what the server sends.
@Suite struct FoodsGoldenTests {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/api/golden/foods-v1.json")

    struct Golden: Decodable {
        /// The server's mapping targets, as [name, factor from grams].
        var nutrients: [[JSONValue]]
        var foods: [Food?]
        var generic: Generic
    }

    /// Generic foods from the server's bundled USDA table, and its units.
    struct Generic: Decodable {
        var units: [String: String]
        var foods: [Food]
    }

    @Test func bundledUSDAFoodsDecodeInExerlyCoreUnitsWithTheirPortions() throws {
        let generic = try ExerlyJSON.decoder.decode(Golden.self, from: Data(contentsOf: Self.url)).generic
        for (name, unit) in generic.units {
            let nutrient = try #require(Nutrient(rawValue: name), "\(name) isn't a nutrient the phone knows")
            #expect(nutrient.unit.rawValue == unit, "\(name) is in \(nutrient.unit.rawValue)")
        }
        #expect(generic.foods.map(\.name) == ["Banana, raw", "Fish, salmon, raw", "Peanut butter"])
        #expect(generic.foods.allSatisfy { $0.source == .usda && $0.id.hasPrefix("usda:") && $0.problems.isEmpty })
        let banana = generic.foods[0]
        #expect(banana.per100g[.energy] == 97 && banana.per100g[.leucine] == nil)
        let one = try #require(banana.servings.first { $0.name == "1 banana" })
        #expect(one.grams == 126)
        #expect(try NutritionStore.preview(banana, serving: one).nutrients.energy == 97 * 1.26)
    }

    @Test func everyMappedFoodDecodesWithItsNutrientsInExerlyCoreUnits() throws {
        let golden = try ExerlyJSON.decoder.decode(Golden.self, from: Data(contentsOf: Self.url))
        let foods = golden.foods.compactMap { $0 }
        for pair in golden.nutrients {
            guard case .string(let name) = pair.first, case .number(let factor) = pair.last,
                  let nutrient = Nutrient(rawValue: name) else {
                Issue.record("\(pair) isn't a nutrient the phone knows")
                continue
            }
            let expected: Double = switch nutrient.unit {
            case .grams, .kilocalories: 1
            case .milligrams: 1e3
            case .micrograms: 1e6
            }
            #expect(factor == expected, "\(name) is in \(nutrient.unit.rawValue)")
        }
        #expect(golden.foods.count == 10 && foods.count == 8)
        #expect(foods.allSatisfy { $0.problems.isEmpty && $0.source == .openFoodFacts && $0.id.hasPrefix("off:") })
        let bar = try #require(foods.first)
        #expect(bar.per100g[.energy] == 412)
        #expect(bar.per100g[.sodium] == 240 && Nutrient.sodium.unit == .milligrams)
        #expect(bar.per100g[.vitaminD] == 2.5 && Nutrient.vitaminD.unit == .micrograms)
        #expect(bar.per100g[.alcohol] == nil)
        #expect(bar.servings == [Serving("1 bar (40 g)", grams: 40)])
        #expect(foods[1].per100g[.energy] == 43.021)
        #expect(bar.volume == nil && foods[1].volume?.density == 1 && foods[1].volume?.assumed == true)
        // A label per 100 ml, for a liquid lighter than water: the label comes back.
        let oil = try #require(foods.first { $0.name == "Synthetic olive oil" })
        #expect(oil.volume == VolumeBasis(density: 0.92, assumed: true, note: "Typical for oils"))
        #expect(oil.per100g[.fat] == 100 && abs((oil.per100ml?[.energy] ?? 0) - 828) < 1e-9)
        #expect(oil.servings == [Serving("1 tbsp (15 ml)", grams: 13.8)] && oil.grams(milliliters: 15) == 13.8)
        // A package size is a serving, so "1 can" logs the can.
        let beans = try #require(foods.first { $0.name == "Synthetic red kidney beans" })
        #expect(beans.servings.last == Serving("1 can", grams: 425))
        #expect(beans.portion(TypedAmount(1, .serving("can")))?.amount.grams == 425)
        // The canonical form round-trips, so a saved database food syncs unchanged.
        for food in foods {
            #expect(try ExerlyJSON.decoder.decode(Food.self, from: ExerlyJSON.canonical(food)) == food)
        }
    }

    @MainActor
    @Test func aLoggedOilKeepsItsVolumeBasisAfterReopeningInRecipesAndInTheExport() throws {
        let golden = try ExerlyJSON.decoder.decode(Golden.self, from: Data(contentsOf: Self.url))
        let oil = try #require(golden.foods.compactMap { $0 }.first { $0.name == "Synthetic olive oil" })
        let persistence = InMemoryTrainingPersistence()
        let nutrition = try NutritionStore(persistence: persistence, now: { Fixture.instant() })
        // Logged straight from search, with no saved food to look up later.
        let entry = try nutrition.log(oil, serving: oil.servings[0], on: LocalDate("2026-10-05")!, meal: "Dinner")
        #expect(entry.food.volume == oil.volume && entry.grams == 13.8)
        // The editor reopens the amount in the millilitres it was entered in.
        #expect(abs((entry.food.volume?.milliliters(grams: entry.grams) ?? 0) - 15) < 1e-12)
        #expect(oil.milliliters(grams: 13.8) == entry.food.volume?.milliliters(grams: 13.8))
        #expect(Food(name: "Rice", per100g: NutrientAmounts()).milliliters(grams: 100) == nil)
        let dressing = Food.recipe(name: "Dressing", ingredients: [RecipeIngredient(food: oil.snapshot, grams: 30)])
        try nutrition.saveFood(dressing)
        var thick = entry
        thick.food.volume?.density = 11
        #expect(throws: NutritionStore.StoreError.invalid(["the density must be between 0.3 and 3 g/ml"])) {
            try nutrition.saveEntry(thick)
        }

        let reopened = try NutritionStore(persistence: persistence)
        #expect(reopened.entries.map(\.food.volume) == [oil.volume])
        #expect(reopened.food(dressing.id)?.ingredients?.first?.food.volume == oil.volume)
        let export = try AccountExport.merging(server: nil, hosts: [reopened], state: persistence, now: Fixture.instant())
        let json = try #require(try JSONSerialization.jsonObject(with: export) as? [String: Any])
        let documents = try #require(json["documents"] as? [[String: Any]])
        let logged = try #require(documents.first { $0["kind"] as? String == "food_entry" }?["payload"] as? [String: Any])
        let volume = (logged["food"] as? [String: Any])?["volume"] as? [String: Any]
        #expect(volume?["density"] as? Double == 0.92 && volume?["note"] as? String == "Typical for oils")
    }
}

@Suite struct FoodDatabaseAPITests {
    let start = Date.milliseconds(1_791_223_200_000)

    func account(_ transport: FakeTransport) async throws -> AccountAPI {
        let store = InMemoryCredentialStore()
        try store.save(Credentials(accessToken: "t", refreshToken: "r", accessExpiresAt: start.addingTimeInterval(600),
                                   sessionID: "s", accountID: "a"))
        return try await ExerlyAPI(baseURL: URL(string: "https://api.exerly.test")!, transport: transport, credentials: store,
                                   now: { start }).account()
    }

    @Test func searchAndBarcodeReturnDatabaseFoodsOrNil() async throws {
        let golden = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: FoodsGoldenTests.url)) as? [String: Any])
        let foods = try #require(golden["foods"] as? [Any]).filter { !($0 is NSNull) }
        let attribution = "Data from Open Food Facts"
        let transport = FakeTransport { request in
            if request.path.hasPrefix("/v1/foods/search") { return (200, ["foods": foods, "attribution": attribution]) }
            if request.path == "/v1/foods/barcode/0012345678905" { return (200, ["food": foods[0], "attribution": attribution]) }
            if request.path == "/v1/foods/barcode/4000000000016" { return (404, ["error": "No food has that barcode"]) }
            if ["/v1/foods/barcode/01234565?symbology=upce", "/v1/foods/barcode/96385074?symbology=ean8"].contains(request.path) {
                return (200, ["food": foods[1], "attribution": attribution])
            }
            if request.path == "/v1/foods/barcode/01234565" {
                return (400, ["error": "Choose EAN-8 or UPC-E for an eight-digit code."])
            }
            return (503, ["error": "The food database is unavailable right now. Try again shortly."])
        }
        let api = try await account(transport)
        let found = try await api.searchFoods("oat bar + nuts", limit: 5)
        #expect(found.foods.map(\.id) == ["off:0012345678905", "off:5000000000017", "off:76543210", "off:3000000000013",
                                          "off:0041000000016", "off:0041000000023", "off:0049000000443", "off:0049000000450"])
        #expect(found.attribution == attribution)
        #expect(transport.requests.first?.path == "/v1/foods/search?q=oat%20bar%20%2B%20nuts&limit=5")

        #expect(try await api.food(barcode: "0012345678905")?.foods.first?.name == "Synthetic oat bar")
        #expect(try await api.food(barcode: "4000000000016") == nil)
        await #expect(throws: APIError.self) { try await api.food(barcode: "5000000000017") }
        // Eight digits need the camera's format.
        #expect(try await api.food(barcode: "01234565", symbology: .upcE)?.foods.first?.id == "off:5000000000017")
        #expect(try await api.food(barcode: "96385074", symbology: .ean8) != nil)
        await #expect(throws: APIError.self) { try await api.food(barcode: "01234565") }
    }
}
