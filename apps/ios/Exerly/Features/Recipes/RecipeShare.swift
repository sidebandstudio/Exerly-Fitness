import CoreTransferable
import ExerlyCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A recipe shared from Exerly, declared in Info.plist so the file opens in Exerly.
    static let exerlyRecipe = UTType(exportedAs: "com.exerly.fitness.recipe", conformingTo: .json)
}

/// A saved recipe as the share sheet sends it: a `.exerlyrecipe` file
/// another Exerly user can import (see `RecipeFile`), with a plain-text
/// summary for whoever reads the message.
struct RecipeShareItem: Transferable {
    let recipe: ExerlyCore.Food

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .exerlyRecipe) { item in
            let name = item.recipe.name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("\(name).\(RecipeFile.fileExtension)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RecipeFile.data(for: item.recipe).write(to: url)
            return SentTransferredFile(url)
        }
    }

    /// The recipe in words: yield and a serving's numbers, ingredients, steps and source.
    static func summary(_ recipe: ExerlyCore.Food, unit: MassUnit) -> String {
        var lines = [recipe.name]
        let amounts = recipe.perRecipeServing ?? recipe.recipeTotal ?? recipe.per100g
        let basis = recipe.servingCount.map { "Makes \(TrainingFormat.number($0)) \($0 == 1 ? "serving" : "servings"), each" } ?? "The whole recipe:"
        lines.append("\(basis) \(FoodFormat.kcal(amounts[.energy])) kcal, \(grams(amounts[.protein])) protein, "
                     + "\(grams(amounts[.carbohydrate])) carbs, \(grams(amounts[.fat])) fat")
        lines += ["", "Ingredients"]
        for ingredient in recipe.ingredients ?? [] {
            let amount = FoodFormat.amount(grams: ingredient.grams, serving: ingredient.serving, quantity: ingredient.quantity,
                                           food: ingredient.food.foodForLogging(), unit: unit)
            lines.append("• \(ingredient.food.name), \(amount)")
        }
        if let preparation = recipe.preparation { lines += ["", "Preparation", preparation] }
        if let source = recipe.sourceURL { lines += ["", "Source: \(source)"] }
        lines += ["", "Open the attached .\(RecipeFile.fileExtension) file in Exerly to add a copy to your recipes."]
        return lines.joined(separator: "\n")
    }

    private static func grams(_ value: Double?) -> String { value.map { "\(FoodFormat.grams($0)) g" } ?? "–" }

    /// A recipe file someone shared, from the file picker or opened from
    /// another app, ready to review. A copy the system made in the app's
    /// Inbox is removed once read.
    static func read(_ url: URL) throws -> RecipeImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if url.pathComponents.contains("Inbox") { try? FileManager.default.removeItem(at: url) }
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= RecipeFile.maximumSize else { throw RecipeFile.Failure.unreadable }
        return try RecipeFile.read(Data(contentsOf: url))
    }
}
