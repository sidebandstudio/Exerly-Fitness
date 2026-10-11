import Foundation
import Testing
@testable import ExerlyCore

@Suite struct FoodSearchTests {
    let names = ["Tomatoes, canned, cooked", "Tomato sauce", "Crème fraîche", "Canned tuna in water", "Diced chicken"]

    func search(_ query: String) -> [String] { FoodSearch.matching(names, query: query) { $0 } }

    @Test func everyWordMatchesInAnyOrderIgnoringCaseAndAccents() {
        #expect(search("canned tomatoes") == ["Tomatoes, canned, cooked"])
        #expect(search("CREME FRAICHE") == ["Crème fraîche"])
        #expect(search("tomato") == ["Tomatoes, canned, cooked", "Tomato sauce"], "In the order given")
        #expect(search("zzqx").isEmpty && search("  ").isEmpty)
    }

    @Test func withoutEveryWordTheFoodsWithMostOfThemComeFirst() {
        // No food says "diced tomatoes canned"; canned tomatoes have two of the
        // words, canned tuna and diced chicken only one, which isn't enough.
        #expect(search("diced tomatoes canned") == ["Tomatoes, canned, cooked"])
        #expect(search("diced canned tuna water") == ["Canned tuna in water"], "Three of four")
        #expect(search("canned water tomatoes zzqx").isEmpty, "Two of four is only half")
        #expect(search("ground tomato").isEmpty, "One of two is only half: another food, not a near match")
    }

    @Test func aFoodTheQueryNamesComesBeforeDishesNamedWithIt() {
        // The person's usual food first, as the picker gives them: neither it
        // nor the dishes name plain toast, so they keep that order.
        let foods = ["Whole wheat toast", "Shrimp toast", "French toast, NFS", "Bread, white, toasted", "Toast, Acme"]
        #expect(FoodSearch.matching(foods, query: "toast") { $0 }
            == ["Bread, white, toasted", "Toast, Acme", "Whole wheat toast", "Shrimp toast", "French toast, NFS"])
        #expect(FoodSearch.matching(["Egg salad", "Eggs, scrambled"], query: "egg") { $0 } == ["Eggs, scrambled", "Egg salad"])
        #expect(FoodSearch.matching(foods, query: "french toast") { $0 } == ["French toast, NFS"])
    }

    @Test func aNameIsTheQueryOrItsFirstPartsOrOnePart() {
        #expect(FoodSearch.names("Eggs, scrambled", query: "egg"))
        #expect(FoodSearch.names("Eggs, scrambled", query: "scrambled eggs"), "Its first parts together, in any order")
        #expect(FoodSearch.names("Fish, salmon, raw", query: "Salmon"), "A later part alone")
        #expect(FoodSearch.names("Bread, toasted", query: "toast") && FoodSearch.names("Potatoes, baked", query: "bake"), "The -ed form")
        #expect(FoodSearch.names("Whole wheat toast", query: "whole wheat toast"))
        #expect(!FoodSearch.names("Whole wheat toast", query: "toast") && !FoodSearch.names("Egg salad", query: "egg"))
        #expect(!FoodSearch.names("Toasted coconut", query: "toast"), "Only a part that is the word alone")
        #expect(!FoodSearch.names("Toast", query: "  "))
    }
}
