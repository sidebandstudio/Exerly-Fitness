import ExerlyCore
import SwiftUI

/// Builds or edits a recipe: ingredients from the same search the diary
/// uses, an optional cooked weight, servings and a note, with live totals.
/// A recipe imported from a web page or a shared file opens here to review.
/// Saving never changes entries already logged; they keep their snapshot.
struct RecipeEditor: View {
    let workspace: TrainingWorkspace
    let api: AccountAPI
    let timeZone: TimeZone
    let onSaved: (ExerlyCore.Food) -> Void
    private let editingID: String?
    private let startsImporting: Bool
    @StateObject private var draft: RecipeDraft
    @StateObject private var actions: NutritionDiaryActions
    @State private var choosing = false
    @State private var importing = false
    /// An imported line no food matched, being searched for.
    @State private var resolving: UnmatchedLine?
    /// Counts Saves refused for lines not matched yet.
    @State private var showingUnmatched = 0
    @State private var editingRow: RecipeDraft.Row?
    @State private var discarding = false
    @State private var editMode = EditMode.inactive
    @FocusState private var nameFocused: Bool
    @AccessibilityFocusState private var errorsFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct UnmatchedLine: Identifiable {
        let id = UUID()
        let text: String
    }

    /// `startsImporting` opens the import sheet over a new recipe; cancelling
    /// it leaves the recipe to build by hand.
    init(workspace: TrainingWorkspace, api: AccountAPI, timeZone: TimeZone, unit: MassUnit, editing: ExerlyCore.Food? = nil,
         start: ExerlyCore.Food? = nil, imported: RecipeImport? = nil, startsImporting: Bool = false,
         onSaved: @escaping (ExerlyCore.Food) -> Void = { _ in }) {
        self.workspace = workspace
        self.api = api
        self.timeZone = timeZone
        self.onSaved = onSaved
        editingID = editing?.id
        self.startsImporting = startsImporting
        _draft = StateObject(wrappedValue: RecipeDraft(store: workspace.nutrition, unit: unit, editing: editing, start: start,
                                                       imported: imported))
        _actions = StateObject(wrappedValue: NutritionDiaryActions(store: workspace.nutrition))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ExList {
                    Section {
                        TextField("Recipe name", text: $draft.name, prompt: Text("Name this recipe").foregroundColor(.exTextSecondary), axis: .vertical)
                            .font(.exH2).focused($nameFocused).submitLabel(.done)
                            // A field that grows reads only its text once filled, without this.
                            .accessibilityLabel("Recipe name")
                            .accessibilityIdentifier("recipe.name")
                    }
                    if !draft.unmatched.isEmpty { unmatchedLines }
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
                    .exFieldOrder(["recipe.servings", "recipe.cookedWeight"])
                    Section {
                        TextField("Preparation", text: $draft.preparation, prompt: Text("Steps, pan size, cooking time").foregroundColor(.exTextSecondary),
                                  axis: .vertical)
                            .lineLimit(3...10).accessibilityIdentifier("recipe.preparation")
                    } header: { Text("Preparation") } footer: {
                        if let source = draft.sourceURL.flatMap(URL.init(string:)) { RecipeSourceLink(url: source) }
                    }
                    if let id = editingID, let saved = workspace.nutrition.food(id) {
                        Section {
                            RecipeShareLink(recipe: saved, unit: draft.unit)
                        } footer: { Text("Sends the saved recipe as a file another Exerly user can import, with a summary to read.") }
                    }
                    if !draft.isNew {
                        Text("Changes apply from now on. Entries already logged keep their nutrition.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary).listRowBackground(Color.clear)
                    }
                    if !draft.errors.isEmpty && draft.unmatched.isEmpty {
                        Section {
                            ForEach(draft.errors, id: \.self) {
                                Text($0).foregroundStyle(Color.exError).accessibilityFocused($errorsFocused).accessibilityIdentifier("recipe.error")
                            }
                        }
                    }
                }
                // A refused Save shows the lines still to settle, at the top.
                .onChange(of: showingUnmatched) { withAnimation { proxy.scrollTo("unmatched", anchor: .top) } }
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
                        } else if !draft.unmatched.isEmpty {
                            showingUnmatched += 1
                        } else if let row = draft.unchecked { editingRow = row }
                    }.fontWeight(.semibold).disabled(!draft.canSave).accessibilityIdentifier("recipe.save")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { nameFocused = false; hideKeyboard() } }
            }
            .onChange(of: draft.errors) { _, errors in errorsFocused = !errors.isEmpty }
            .task {
                guard draft.isNew, draft.name.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(450))
                if startsImporting { importing = true } else { nameFocused = true }
            }
            .sheet(isPresented: $choosing) { picker { draft.add($0, amount: $1) } }
            .sheet(item: $resolving) { line in
                // The line as typed search reads it, so the food comes in at the line's amount.
                picker(query: IngredientLine(line.text).query, closesAfterPick: true) { food, amount in
                    guard draft.add(food, amount: amount) else { return false }
                    draft.settle(line.text)
                    return true
                }
            }
            .sheet(isPresented: $importing) {
                RecipeImportView(store: workspace.nutrition, api: api, unit: draft.unit) { draft.apply($0) }
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

    private func picker(query: String = "", closesAfterPick: Bool = false, add: @escaping (ExerlyCore.Food, FoodPickAmount) -> Bool) -> some View {
        NutritionFoodPicker(workspace: workspace, api: api, date: LocalDate(.now, in: timeZone), meal: "Recipe",
                            timeZone: timeZone, unit: draft.unit, actions: actions, onLogged: {},
                            pickedCount: draft.rows.count, pickedFoodIDs: Set(draft.rows.map(\.ingredient.food.foodID)),
                            onPick: { add($0, $1) ? draft.rows.count : nil }, pickError: { draft.errors.first },
                            pickingInto: "recipe", confirmsAmounts: true, closesAfterPick: closesAfterPick, initialQuery: query)
    }

    /// An imported recipe's lines no food matched, first, each to search for or skip.
    private var unmatchedLines: some View {
        Section {
            ForEach(Array(draft.unmatched.enumerated()), id: \.offset) { index, line in
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    Text(line).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small))
                        : AnyLayout(HStackLayout(spacing: ExSpacing.small))
                    layout {
                        Button("Search", systemImage: "magnifyingglass") { hideKeyboard(); resolving = UnmatchedLine(text: line) }
                            .buttonStyle(ExActionStyle(secondary: true)).accessibilityLabel("Search for \(line)")
                            .accessibilityIdentifier("recipe.unmatchedSearch.\(index)")
                        Button("Skip") { withAnimation { draft.settle(line) } }
                            .buttonStyle(ExActionStyle(secondary: true)).accessibilityLabel("Skip \(line)")
                            .accessibilityIdentifier("recipe.unmatchedSkip.\(index)")
                    }
                }.padding(.vertical, ExSpacing.tight).accessibilityElement(children: .contain)
            }
        } header: {
            Label("Not matched · \(draft.unmatched.count)", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Color.exWarning).textCase(nil)
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isHeader)
                .accessibilityLabel("\(draft.unmatched.count) \(draft.unmatched.count == 1 ? "line" : "lines") not matched")
                .accessibilityIdentifier("recipe.unmatched")
        } footer: {
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                ForEach(draft.errors, id: \.self) {
                    Text($0).foregroundStyle(Color.exError).accessibilityFocused($errorsFocused).accessibilityIdentifier("recipe.error")
                }
                Text("No food matched these lines. Search for each, or skip it. Nothing is saved until you tap Save.")
            }
        }
        .id("unmatched")
    }

    private var ingredients: some View {
        Section {
            ForEach(draft.rows) { row in
                Button { hideKeyboard(); editingRow = row } label: {
                    RecipeIngredientRow(ingredient: row.ingredient, unit: draft.unit, unchecked: !row.checked, needsWeight: row.needsWeight,
                                        line: row.line)
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
            if draft.isNew && draft.rows.isEmpty && draft.unmatched.isEmpty {
                Button { hideKeyboard(); importing = true } label: {
                    Label("Import from a link", systemImage: "link")
                        .font(.exBodyMedium).foregroundStyle(Color.exPrimaryText).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("recipe.import")
            }
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
        let raw = draft.rows.filter { !$0.needsWeight }.reduce(0) { $0 + $1.ingredient.grams }
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
    /// A volume with no weight yet: the amount is only a placeholder.
    var needsWeight = false
    /// The imported line it came from, to compare with the match.
    var line: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let amount = needsWeight ? "No weight yet"
            : FoodFormat.amount(grams: ingredient.grams, serving: ingredient.serving, quantity: ingredient.quantity,
                                food: ingredient.food.foodForLogging(), unit: unit)
        let energy = needsWeight ? "–" : FoodFormat.kcal(ingredient.nutrients[.energy])
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient.food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(amount).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if let line {
                    Text("\u{201C}\(line)\u{201D}").font(.exCaption).foregroundStyle(Color.exTextMuted).lineLimit(2)
                }
                if unchecked {
                    Label(needsWeight ? "Enter its weight" : "Check the amount", systemImage: "exclamationmark.circle.fill")
                        .font(.exCaption.weight(.semibold)).foregroundStyle(Color.exWarning)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text("\(energy) kcal").font(.exLabel).monospacedDigit()
                .foregroundStyle(Color.exTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ingredient.food.name), \(amount)" + (needsWeight ? ", weight needed, left out of the totals"
                            : ", \(energy) kilocalories" + (unchecked ? ", amount not checked yet" : "")) + (line.map { ", from \($0)" } ?? ""))
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
        if let source = recipe.sourceURL.flatMap(URL.init(string:)) { RecipeSourceLink(url: source) }
    }

    private var yield: String {
        let servings = recipe.servingCount.map { "Makes \(TrainingFormat.number($0)) \($0 == 1 ? "serving" : "servings")" }
        let cooked = recipe.yieldGrams.map { "\(FoodFormat.weight($0, unit: unit)) cooked" } ?? "weighed raw"
        return [servings, cooked].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The page an imported recipe came from, credited by its site.
struct RecipeSourceLink: View {
    let url: URL

    var body: some View {
        let site = (url.host() ?? url.absoluteString).replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        Link(destination: url) { Label("From \(site)", systemImage: "link") }
            .font(.exCaption).accessibilityHint("Opens the recipe's page").accessibilityIdentifier("recipe.source")
    }
}

/// Share for a saved recipe: its file and a summary, through the share sheet.
struct RecipeShareLink: View {
    let recipe: ExerlyCore.Food
    let unit: MassUnit

    var body: some View {
        ShareLink(item: RecipeShareItem(recipe: recipe), subject: Text(recipe.name),
                  message: Text(RecipeShareItem.summary(recipe, unit: unit)),
                  preview: SharePreview(recipe.name, image: Image(systemName: "frying.pan"))) {
            Label("Share recipe", systemImage: "square.and.arrow.up")
                .font(.exBodyMedium).foregroundStyle(Color.exPrimaryText).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }.accessibilityIdentifier("recipe.share")
    }
}
