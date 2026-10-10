import ExerlyCore
import SwiftUI

/// Builds or edits a recipe: ingredients from the same search the diary
/// uses, an optional cooked weight, servings and a note, with live totals.
/// Saving never changes entries already logged; they keep their snapshot.
struct RecipeEditor: View {
    let workspace: TrainingWorkspace
    let api: AccountAPI
    let timeZone: TimeZone
    let onSaved: (ExerlyCore.Food) -> Void
    @StateObject private var draft: RecipeDraft
    @StateObject private var actions: NutritionDiaryActions
    @State private var choosing = false
    @State private var editingRow: RecipeDraft.Row?
    @State private var discarding = false
    @State private var editMode = EditMode.inactive
    @FocusState private var nameFocused: Bool
    @AccessibilityFocusState private var errorsFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(workspace: TrainingWorkspace, api: AccountAPI, timeZone: TimeZone, unit: MassUnit, editing: ExerlyCore.Food? = nil,
         start: ExerlyCore.Food? = nil, onSaved: @escaping (ExerlyCore.Food) -> Void = { _ in }) {
        self.workspace = workspace
        self.api = api
        self.timeZone = timeZone
        self.onSaved = onSaved
        _draft = StateObject(wrappedValue: RecipeDraft(store: workspace.nutrition, unit: unit, editing: editing, start: start))
        _actions = StateObject(wrappedValue: NutritionDiaryActions(store: workspace.nutrition))
    }

    var body: some View {
        NavigationStack {
            ExList {
                Section {
                    TextField("Recipe name", text: $draft.name, prompt: Text("Name this recipe").foregroundColor(.exTextSecondary), axis: .vertical)
                        .font(.exH2).focused($nameFocused).submitLabel(.done)
                        .accessibilityIdentifier("recipe.name")
                }
                if let recipe = draft.preview, !draft.rows.isEmpty {
                    Section { RecipeTotals(recipe: recipe, unit: draft.unit).listRowBackground(Color.exPrimary.opacity(0.07)) }
                }
                ingredients
                Section {
                    ExQuantityControl(title: "Servings it makes", text: $draft.servings.text, step: 1, presets: [1, 2, 4, 6],
                                      identifier: "recipe.servings")
                    NutritionNumberInput(title: "Cooked weight (\(draft.unit == .pounds ? "oz" : "g"))", text: $draft.cookedWeight.text,
                                         identifier: "recipe.cookedWeight", placeholder: "Optional")
                } header: { Text("Yield") } footer: { Text(yieldNote) }
                Section("Preparation") {
                    TextField("Preparation", text: $draft.preparation, prompt: Text("Steps, pan size, cooking time").foregroundColor(.exTextSecondary),
                              axis: .vertical)
                        .lineLimit(3...10).accessibilityIdentifier("recipe.preparation")
                }
                if !draft.isNew {
                    Text("Changes apply from now on. Entries already logged keep their nutrition.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).listRowBackground(Color.clear)
                }
                if !draft.errors.isEmpty {
                    Section {
                        ForEach(draft.errors, id: \.self) {
                            Text($0).foregroundStyle(Color.exError).accessibilityFocused($errorsFocused).accessibilityIdentifier("recipe.error")
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.isNew ? "New recipe" : "Edit recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft.hasChanges { discarding = true } else { dismiss() } }
                        .accessibilityIdentifier("recipe.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        nameFocused = false
                        if let food = draft.save() {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onSaved(food)
                            Task { await workspace.synchronize() }
                            dismiss()
                        } else if let row = draft.unchecked { editingRow = row }
                    }.fontWeight(.semibold).disabled(!draft.canSave).accessibilityIdentifier("recipe.save")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { nameFocused = false; hideKeyboard() } }
            }
            .onChange(of: draft.errors) { _, errors in errorsFocused = !errors.isEmpty }
            .task {
                guard draft.isNew, draft.name.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(450))
                nameFocused = true
            }
            .sheet(isPresented: $choosing) {
                NutritionFoodPicker(workspace: workspace, api: api, date: LocalDate(.now, in: timeZone), meal: "Recipe",
                                    timeZone: timeZone, unit: draft.unit, actions: actions, onLogged: {},
                                    pickedCount: draft.rows.count, pickedFoodIDs: Set(draft.rows.map(\.ingredient.food.foodID)),
                                    onPick: { draft.add($0, amount: $1) ? draft.rows.count : nil }, pickError: { draft.errors.first },
                                    pickingInto: "recipe", confirmsAmounts: true)
            }
            .sheet(item: $editingRow) { row in
                FoodPortionStep(store: workspace.nutrition, food: row.food ?? workspace.nutrition.food(row.ingredient.food.foodID)
                                    ?? row.entry.food.foodForLogging(serving: row.ingredient.serving),
                                editing: row.entry, unit: draft.unit, title: "Ingredient", confirm: "Done", identifier: "recipe.ingredient",
                                removeTitle: "Remove from recipe", onRemove: { draft.remove(row.id) },
                                onConfirm: { amount, food in draft.update(row.id, to: amount, food: food) })
            }
            .sheet(isPresented: $discarding) {
                NutritionConfirmation(title: draft.isNew ? "Discard this recipe?" : "Discard recipe changes?",
                                      message: "Nothing you logged changes either way.", confirm: "Discard",
                                      cancelLabel: "Keep editing", destructive: true) { dismiss() } cancel: { discarding = false }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges)
    }

    private var ingredients: some View {
        Section {
            ForEach(draft.rows) { row in
                Button { hideKeyboard(); editingRow = row } label: {
                    RecipeIngredientRow(ingredient: row.ingredient, unit: draft.unit, unchecked: !row.checked)
                }
                    .buttonStyle(.plain).accessibilityIdentifier("recipe.ingredient.\(row.ingredient.food.foodID)")
                    .accessibilityAction(named: "Remove") { draft.remove(row.id) }
            }
            .onDelete { offsets in offsets.map { draft.rows[$0].id }.forEach(draft.remove) }
            .onMove(perform: draft.move)
            Button { hideKeyboard(); choosing = true } label: {
                Label(draft.rows.isEmpty ? "Add ingredients" : "Add more", systemImage: "plus.circle.fill")
                    .font(.exBodyMedium).foregroundStyle(Color.exPrimaryText).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("recipe.addIngredients")
        } header: {
            HStack {
                Text(draft.rows.isEmpty ? "Ingredients" : "Ingredients · \(draft.rows.count)")
                Spacer()
                if draft.rows.count > 1 {
                    Button(editMode.isEditing ? "Done" : "Reorder") { withAnimation { editMode = editMode.isEditing ? .inactive : .active } }
                        .font(.exCaption.weight(.semibold)).textCase(nil).accessibilityIdentifier("recipe.reorder")
                }
            }
        } footer: {
            if draft.rows.isEmpty {
                Text("Search, scan or pick foods you've logged. Each asks for its amount, or type it with the food, as in 80 g oats.")
            }
        }
    }

    private var yieldNote: String {
        var note = "Weigh the pot after cooking to log by weight."
        guard !draft.rows.isEmpty else { return note }
        let raw = draft.rows.reduce(0) { $0 + $1.ingredient.grams }
        note += " Blank uses the ingredients' \(FoodFormat.weight(raw, unit: draft.unit))."
        if let recipe = draft.preview, let serving = recipe.recipeServing {
            note += " Each serving is \(FoodFormat.weight(serving.grams, unit: draft.unit)), \(FoodFormat.kcal(recipe.perRecipeServing?[.energy])) kcal."
        }
        return note
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// A recipe's numbers: a serving as the hero, then 100 g and the whole pot,
/// and which nutrients only some ingredients report.
struct RecipeTotals: View {
    let recipe: ExerlyCore.Food
    let unit: MassUnit

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            if let serving = recipe.recipeServing {
                ExEyebrow("Per serving · \(FoodFormat.weight(serving.grams, unit: unit))", color: .exPrimaryText)
            } else {
                ExEyebrow("Whole recipe", color: .exPrimaryText)
            }
            FoodPortionSummary(amounts: recipe.perRecipeServing ?? recipe.recipeTotal)
            Divider().overlay(Color.exBorder.opacity(0.4))
            line("Per 100 g", recipe.per100g).accessibilityIdentifier("recipe.per100g")
            if let count = recipe.servingCount, count != 1, let total = recipe.recipeTotal, let grams = recipe.recipeGrams {
                line("Whole · \(FoodFormat.weight(grams, unit: unit))", total)
            }
            if let gap = gapNote {
                Label(gap, systemImage: "info.circle").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }.padding(.vertical, ExSpacing.small)
    }

    private func line(_ title: String, _ amounts: NutrientAmounts) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ExSpacing.small) {
                Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary).lineLimit(1)
                Spacer(minLength: ExSpacing.small)
                // Unwrapped, so a narrow phone takes the stacked layout instead of splitting "20 P".
                Text("\(FoodFormat.kcal(amounts[.energy])) kcal").font(.exLabel.weight(.semibold)).monospacedDigit().fixedSize()
                FoodMacroLine(amounts: amounts, font: .exSmall).fixedSize()
            }
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                Text("\(title): \(FoodFormat.kcal(amounts[.energy])) kcal").font(.exLabel.weight(.semibold))
                FoodMacroLine(amounts: amounts)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(FoodFormat.kcal(amounts[.energy])) kilocalories, \(FoodMacroLine.spoken(amounts))")
    }

    /// Calories and macros some ingredients leave out, so their totals may be low.
    private var gapNote: String? {
        let gaps = recipe.recipeGaps
        let named = [(Nutrient.energy, "calories"), (.protein, "protein"), (.carbohydrate, "carbs"), (.fat, "fat")]
            .filter { gaps[$0.0] != nil }
        guard !named.isEmpty else { return nil }
        let foods = Set(named.flatMap { gaps[$0.0] ?? [] }).sorted()
        return "\(foods.formatted(.list(type: .and))) \(foods.count == 1 ? "doesn't" : "don't") report \(named.map(\.1).formatted(.list(type: .and))), so those totals may be low."
    }
}

struct RecipeIngredientRow: View {
    let ingredient: RecipeIngredient
    let unit: MassUnit
    /// At a default amount no one has looked at yet.
    var unchecked = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let amount = FoodFormat.amount(grams: ingredient.grams, serving: ingredient.serving, quantity: ingredient.quantity,
                                       food: ingredient.food.foodForLogging(), unit: unit)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient.food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(amount).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if unchecked {
                    Label("Check the amount", systemImage: "exclamationmark.circle.fill")
                        .font(.exCaption.weight(.semibold)).foregroundStyle(Color.exWarning)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text("\(FoodFormat.kcal(ingredient.nutrients[.energy])) kcal").font(.exLabel).monospacedDigit()
                .foregroundStyle(Color.exTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ingredient.food.name), \(amount), \(FoodFormat.kcal(ingredient.nutrients[.energy])) kilocalories"
                            + (unchecked ? ", amount not checked yet" : ""))
    }
}

/// A saved recipe's ingredients, yield and preparation, for its page in the food library.
struct RecipeDetails: View {
    let recipe: ExerlyCore.Food
    let unit: MassUnit

    var body: some View {
        ExCard {
            ExSectionHeading("Ingredients", detail: recipe.recipeGrams.map { FoodFormat.weight($0, unit: unit) })
            ForEach(Array((recipe.ingredients ?? []).enumerated()), id: \.offset) { index, ingredient in
                if index > 0 { Divider().overlay(Color.exBorder.opacity(0.3)) }
                RecipeIngredientRow(ingredient: ingredient, unit: unit)
            }
            Text(yield).font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("recipe.details")
        if let preparation = recipe.preparation {
            ExCard {
                ExSectionHeading("Preparation")
                Text(preparation).font(.exBody).foregroundStyle(Color.exTextPrimary)
            }
        }
    }

    private var yield: String {
        let servings = recipe.servingCount.map { "Makes \(TrainingFormat.number($0)) \($0 == 1 ? "serving" : "servings")" }
        let cooked = recipe.yieldGrams.map { "\(FoodFormat.weight($0, unit: unit)) cooked" } ?? "weighed raw"
        return [servings, cooked].compactMap { $0 }.joined(separator: " · ")
    }
}
