import ExerlyCore
import SwiftUI

/// The portion sheet: one food's amount, meal and nutrition, logged in one
/// tap with its defaults. Dates, nutrient corrections and the food's source
/// sit below the fold.
struct NutritionEntryEditor: View {
    @ObservedObject var workspace: TrainingWorkspace
    let timeZone: TimeZone
    let unit: MassUnit
    let editing: FoodEntry?
    let onSaved: (FoodEntry) -> Void
    @ObservedObject var actions: NutritionDiaryActions
    @StateObject private var draft: NutritionEntryDraft
    @StateObject private var libraryActions: NutritionLibraryActions
    @State private var confirmation: Confirmation?
    @State private var nutritionEditing: FoodEntry?
    @State private var asIngredients = false
    @FocusState private var typing: Bool
    @AccessibilityFocusState private var errorsFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Confirmation: String, Identifiable {
        case discard, delete
        var id: String { rawValue }
    }

    init(workspace: TrainingWorkspace, food: ExerlyCore.Food, date: LocalDate, meal: String,
         timeZone: TimeZone, unit: MassUnit, actions: NutritionDiaryActions, editing: FoodEntry? = nil,
         onSaved: @escaping (FoodEntry) -> Void) {
        self.workspace = workspace
        self.timeZone = timeZone
        self.unit = unit
        self.actions = actions
        self.editing = editing
        self.onSaved = onSaved
        _libraryActions = StateObject(wrappedValue: NutritionLibraryActions(store: workspace.nutrition))
        _draft = StateObject(wrappedValue: NutritionEntryDraft(store: workspace.nutrition, food: food,
            date: date, meal: meal, editing: editing, repeating: workspace.nutrition.entries.last { $0.food.foodID == food.id && $0.amountChanged != true },
            preferredUnit: unit, timeZone: timeZone))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ExScreen {
                    header
                    FoodPortionSummary(amounts: preview?.nutrients)
                    if draft.snapshot.edited == true {
                        Label("Edited nutrition", systemImage: "pencil").font(.exCaption).foregroundStyle(Color.exPrimaryText)
                    }
                    if draft.snapshot.unweighed == true {
                        ExCard {
                            ExEyebrow("Whole portion", color: .exPrimaryText)
                            Text("Logged as totals, without a weight. Change its Calories and nutrients directly.")
                                .font(.exBody).foregroundStyle(Color.exTextSecondary)
                            editNutritionButton
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.unweighedEntry")
                    } else {
                        amount
                    }
                    ExChoiceChips(values: meals, selection: $draft.meal) { $0 }
                        .accessibilityIdentifier("nutrition.meal")
                    details
                    if let amount = preview {
                        ExCard {
                            ExSectionHeading("Nutrients in this portion")
                            NutritionAmountsView(amounts: amount.nutrients)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("nutrition.portionNutrients")
                    }
                    if !draft.errors.isEmpty || actions.error != nil || libraryActions.error != nil {
                        ExCard {
                            ForEach(draft.errors, id: \.self) { Text($0).foregroundStyle(Color.exError) }
                            if let error = actions.error { Text(error).foregroundStyle(Color.exError) }
                            if let error = libraryActions.error { Text(error).foregroundStyle(Color.exError) }
                        }.id("errors").accessibilityFocused($errorsFocused)
                    }
                    if editing != nil {
                        Button("Delete entry", role: .destructive) { typing = false; confirmation = .delete }
                            .font(.exLabel).frame(minHeight: 44).accessibilityIdentifier("nutrition.deleteEntry")
                    }
                }
                .onChange(of: draft.errors) { _, errors in
                    guard !errors.isEmpty else { return }
                    scroll.scrollTo("errors", anchor: .bottom)
                    errorsFocused = true
                }
                .onChange(of: actions.error) { _, error in
                    guard error != nil else { return }
                    scroll.scrollTo("errors", anchor: .bottom)
                    errorsFocused = true
                }
            }
            .safeAreaInset(edge: .bottom) { logButton }
            .navigationTitle(editing == nil ? "Log food" : "Food entry").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        typing = false
                        if draft.hasChanges { confirmation = .discard } else { dismiss() }
                    }.accessibilityIdentifier("nutrition.cancelEntry")
                }
                ToolbarItem(placement: .primaryAction) { favoriteButton }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
            }
        }
        .environment(\.timeZone, timeZone)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.custom(FoodSheetDetent.self), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.hasChanges)
        .sheet(item: $confirmation) { kind in
            if kind == .delete, let editing {
                NutritionConfirmation(title: "Delete this entry?",
                                      message: "Remove \(editing.food.name) from \(editing.meal) on \(editing.date)? You can undo this from the diary.",
                                      confirm: "Delete entry", destructive: true) {
                    confirmation = nil
                    if actions.delete(editing) {
                        Task { await workspace.synchronize() }
                        dismiss()
                    }
                } cancel: { confirmation = nil }
            } else {
                NutritionConfirmation(title: "Discard entry changes?", message: "Your unsaved portion, nutrition, date and meal changes will be discarded.",
                                      confirm: "Discard changes", cancelLabel: "Keep editing", destructive: true) {
                    confirmation = nil
                    dismiss()
                } cancel: { confirmation = nil }
            }
        }
        .sheet(item: $nutritionEditing) { reviewed in
            NutritionEntryNutrientsEditor(entry: reviewed, unit: unit) { corrected in
                try draft.applyNutrition(corrected, reviewed: reviewed)
            }
        }
    }

    private var preview: LoggedAmount? { try? draft.preview() }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(draft.food.name).font(.exH3).foregroundStyle(Color.exTextPrimary)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if let origin = FoodFormat.origin(of: draft.snapshot) {
                Text(origin).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
    }

    @ViewBuilder private var amount: some View {
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            NutritionMeasureChips(draft: draft, unit: unit)
            ExQuantityControl(title: draft.measure.amountTitle, text: $draft.amount.text, step: draft.measure.step,
                              presets: draft.measure.presets, unit: draft.measure.symbol)
                .focused($typing).accessibilityIdentifier("nutrition.amount")
            if draft.measure == .milliliters || draft.measure == .fluidOunces, draft.food.volume?.assumed == true {
                Label("Estimated weight from volume", systemImage: "info.circle")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            if recipe != nil {
                Toggle(isOn: $asIngredients) {
                    Text("Log ingredients separately").font(.exLabel)
                    Text("Each one scaled to this portion, to change one later").font(.exCaption)
                }.tint(Color.exActionFill).accessibilityIdentifier("nutrition.logIngredients")
            }
        }
    }

    /// The saved recipe this sheet logs, when it can be logged as its ingredients.
    private var recipe: ExerlyCore.Food? {
        guard editing == nil, let food = workspace.nutrition.food(draft.food.id), food.recipeGrams != nil else { return nil }
        return food
    }

    private var details: some View {
        ExCard {
            // One day and time: the day it was eaten is the diary day its totals count on.
            if typeSize.isAccessibilitySize {
                Text("Eaten").font(.exLabel).foregroundStyle(Color.exTextSecondary)
                DatePicker("Eaten", selection: $draft.eatenAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().accessibilityIdentifier("nutrition.eatenAt")
            } else {
                DatePicker("Eaten", selection: $draft.eatenAt, displayedComponents: [.date, .hourAndMinute])
                    .font(.exLabel).accessibilityIdentifier("nutrition.eatenAt")
            }
            Divider().overlay(Color.exBorder.opacity(0.3))
            if draft.snapshot.unweighed != true { editNutritionButton }
            DisclosureGroup("About this food") {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    Text(NutritionFormat.source(draft.food.source))
                    if let volume = draft.food.volume {
                        if volume.assumed {
                            Text("Gram amounts use an estimated density of \(TrainingFormat.number(volume.density)) g/ml.")
                        }
                        if let note = volume.note { Text(note).foregroundStyle(Color.exTextSecondary) }
                    }
                    if draft.food.source == .openFoodFacts {
                        Link("Open Food Facts · Open Database License", destination: URL(string: "https://world.openfoodfacts.org/data")!)
                    } else if draft.food.source == .usda {
                        Link("USDA FoodData Central · Public domain", destination: URL(string: "https://fdc.nal.usda.gov/")!)
                    }
                    if editing != nil {
                        Text("This entry keeps the food name and nutrition saved when you logged it.")
                            .foregroundStyle(Color.exTextSecondary)
                    }
                    Text("Dates and times use \(timeZone.identifier). The day it was eaten decides which day's totals include it.")
                        .foregroundStyle(Color.exTextSecondary)
                }.font(.exCaption).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.exLabel)
        }
    }

    private var editNutritionButton: some View {
        Button("Edit entry nutrition", systemImage: "pencil") {
            typing = false
            nutritionEditing = draft.reviewNutrition()
        }.font(.exLabel).frame(minHeight: 44).contentShape(Rectangle())
            .accessibilityIdentifier("nutrition.editEntryNutrients")
    }

    @ViewBuilder private var favoriteButton: some View {
        let saved = workspace.nutrition.food(draft.food.id)
        if draft.snapshot.unweighed != true, saved?.archivedAt == nil {
            let favorite = saved?.favorite == true
            Button(favorite ? "Remove from favorites" : "Add to favorites", systemImage: favorite ? "star.fill" : "star") {
                let changed = favorite ? saved.map { libraryActions.setFavorite(false, reviewed: $0) } ?? false
                    : libraryActions.keepFavorite(draft.food, reviewed: saved)
                if changed { Task { await workspace.synchronize() } }
            }.tint(favorite ? Color.exAccent : Color.exPrimaryText)
                .sensoryFeedback(.selection, trigger: favorite)
                .accessibilityIdentifier(favorite ? "nutrition.entryFavoriteSaved" : "nutrition.entryFavorite")
        }
    }

    private var logButton: some View {
        Button {
            typing = false
            hideKeyboard()
            let saved = if asIngredients, let recipe { draft.saveIngredients(of: recipe) } else { draft.save().map { [$0] } }
            if let saved {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                saved.forEach(onSaved)
                Task { await workspace.synchronize() }
                dismiss()
            }
        } label: {
            Text(editing == nil ? "Log to \(draft.meal)\(otherDay.map { " · \($0.short)" } ?? "")" : "Save changes")
        }
        .accessibilityLabel(editing == nil ? "Log to \(draft.meal)\(otherDay.map { " on \($0.spoken)" } ?? "")" : "Save changes")
        .buttonStyle(ExActionStyle())
        .accessibilityIdentifier("nutrition.saveEntry")
        .padding(.horizontal, ExSpacing.page).padding(.top, ExSpacing.small).padding(.bottom, ExSpacing.small)
        .background(Color.exBackground)
    }

    private var meals: [String] {
        let defaults = NutritionStore.defaultMeals
        return defaults.contains(draft.meal) ? defaults : defaults + [draft.meal]
    }

    /// The diary day when it isn't today: "Sun" within a week, else "Oct 3".
    private var otherDay: (short: String, spoken: String)? {
        let today = LocalDate(Date(), in: timeZone)
        guard draft.date != today else { return nil }
        var short = abs(today.days(until: draft.date)) < 7 ? Date.FormatStyle().weekday(.abbreviated)
            : Date.FormatStyle().month(.abbreviated).day()
        var spoken = Date.FormatStyle().weekday(.wide).month(.wide).day()
        short.timeZone = BodyDates.utc
        spoken.timeZone = BodyDates.utc
        return (BodyDates.anchor(draft.date).formatted(short), BodyDates.anchor(draft.date).formatted(spoken))
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
