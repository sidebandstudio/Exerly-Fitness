import ExerlyCore
import SwiftUI

struct NutritionPlateView: View {
    let workspace: TrainingWorkspace
    let api: AccountAPI
    let timeZone: TimeZone
    @ObservedObject var actions: NutritionDiaryActions
    let onLogged: () -> Void
    let onLoggedEntries: (([FoodEntry]) -> Void)?
    @StateObject private var draft: NutritionPlateDraft
    /// Offline scans picked into this meal, consumed when it logs.
    @StateObject private var staging: BarcodeStaging
    @State private var choosingFood = false
    @State private var editing: NutritionPlateDraft.Row?
    @State private var discarding = false
    @AccessibilityFocusState private var errorFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, api: AccountAPI, date: LocalDate, meal: String,
         timeZone: TimeZone, unit: MassUnit, actions: NutritionDiaryActions, onLogged: @escaping () -> Void,
         onLoggedEntries: (([FoodEntry]) -> Void)? = nil) {
        self.workspace = workspace
        self.api = api
        self.timeZone = timeZone
        self.actions = actions
        self.onLogged = onLogged
        self.onLoggedEntries = onLoggedEntries
        _draft = StateObject(wrappedValue: NutritionPlateDraft(store: workspace.nutrition, date: date, meal: meal, unit: unit,
                                                               timeZone: timeZone))
        _staging = StateObject(wrappedValue: BarcodeStaging(library: workspace.barcodes))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ExScreen {
                    if draft.rows.isEmpty {
                        ExEmptyState(icon: "fork.knife", title: "Build your meal",
                                     message: "Choose a few foods, adjust their portions, then log the meal together.",
                                     action: "Choose foods") { choosingFood = true }
                    } else {
                        ExCard(accent: true) {
                            ExEyebrow("Your meal · \(draft.rows.count) \(draft.rows.count == 1 ? "food" : "foods")", color: .exPrimaryText)
                                .accessibilityIdentifier("nutrition.plateSummary")
                            if let summary = draft.summary {
                                NutritionDailySummary(amounts: summary.totals, targets: nil, progress: draft.progress,
                                                      showHeading: false)
                            }
                        }
                        VStack(alignment: .leading, spacing: ExSpacing.item) {
                            ExSectionHeading("Foods")
                            ExCard {
                                ForEach(draft.rows) { row in
                                    foodRow(row)
                                    if row.id != draft.rows.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: ExSpacing.item) {
                        ExSectionHeading("Log to")
                        ExChoiceChips(values: meals, selection: $draft.meal) { $0 }
                            .accessibilityIdentifier("nutrition.plateMeal")
                    }
                    ExCard {
                        // One day and time, as on a food's portion sheet.
                        if typeSize.isAccessibilitySize {
                            Text("Eaten").font(.exLabel).foregroundStyle(Color.exTextSecondary)
                            DatePicker("Eaten", selection: $draft.eatenAt, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                        } else {
                            DatePicker("Eaten", selection: $draft.eatenAt, displayedComponents: [.date, .hourAndMinute])
                        }
                        Text("Nothing is added to your diary until you log this meal.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                    if let error = draft.error {
                        ExCard { Text(error).foregroundStyle(Color.exError).accessibilityFocused($errorFocused) }
                            .id("plate-error").accessibilityIdentifier("nutrition.plateError")
                    }
                }
                .onChange(of: draft.error) { _, error in
                    if error != nil { scroll.scrollTo("plate-error", anchor: .bottom); errorFocused = true }
                }
            }
            .exFooter {
                if !draft.rows.isEmpty {
                    Button("Add foods", systemImage: "plus") { choosingFood = true }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("nutrition.plateAddFoods")
                        .padding(ExSpacing.page).background(Color.exBackground)
                }
            }
            .navigationTitle("Log a meal").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft.rows.isEmpty { dismiss() } else { discarding = true } }
                        .accessibilityIdentifier("nutrition.cancelPlate")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log meal") {
                        if let entries = draft.save(consuming: staging.library, scope: staging.scope) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onLogged()
                            onLoggedEntries?(entries)
                            Task { await workspace.synchronize() }
                            dismiss()
                        } else if let row = draft.unchecked { editing = row }
                    }.fontWeight(.semibold).disabled(draft.rows.isEmpty).accessibilityIdentifier("nutrition.savePlate")
                }
            }
            .sheet(isPresented: $choosingFood) {
                NutritionFoodPicker(workspace: workspace, api: api, date: draft.date, meal: draft.meal,
                                    timeZone: timeZone, unit: draft.unit, actions: actions, onLogged: {},
                                    pickedCount: draft.rows.count, pickedFoodIDs: Set(draft.rows.map { $0.food.id }), onPick: { food, amount in
                                        draft.add(food, amount: amount) ? draft.rows.count : nil
                                    }, pickError: { draft.error })
                    .environment(\.barcodeStagingScope, staging.scope)
            }
            .sheet(item: $editing) { row in
                NutritionPlatePortionEditor(workspace: workspace, plate: draft, row: row)
            }
            .sheet(isPresented: $discarding) {
                NutritionConfirmation(title: "Discard this meal?", message: "These foods have not been logged. Your existing diary will stay unchanged.",
                                      confirm: "Discard meal", cancelLabel: "Keep building", destructive: true) { dismiss() }
                    cancel: { discarding = false }
            }
        }
        .environment(\.timeZone, timeZone)
        .interactiveDismissDisabled(!draft.rows.isEmpty)
    }

    private var meals: [String] {
        NutritionStore.defaultMeals.contains(draft.meal) ? NutritionStore.defaultMeals : NutritionStore.defaultMeals + [draft.meal]
    }

    private func foodRow(_ row: NutritionPlateDraft.Row) -> some View {
        HStack(alignment: .center, spacing: ExSpacing.small) {
            Button { editing = row } label: {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    Text(row.food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(NutritionFormat.portion(row.entry(on: draft.date, meal: draft.meal, at: draft.loggedAt), unit: draft.unit))
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    if row.checked {
                        Text("Edit portion").font(.exCaption).foregroundStyle(Color.exPrimaryText)
                    } else {
                        Label("Check the amount", systemImage: "exclamationmark.circle.fill")
                            .font(.exCaption.weight(.semibold)).foregroundStyle(Color.exWarning)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("nutrition.plateRow.\(row.food.id).\(row.id)")
            Button("Remove \(row.food.name)", systemImage: "minus.circle") { draft.remove(row) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).foregroundStyle(Color.exPrimaryText)
                .accessibilityIdentifier("nutrition.plateRemove.\(row.id)")
        }
    }
}

private struct NutritionPlatePortionEditor: View {
    @ObservedObject var plate: NutritionPlateDraft
    let row: NutritionPlateDraft.Row
    @StateObject private var draft: NutritionEntryDraft
    @State private var discarding = false
    @AccessibilityFocusState private var errorsFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(workspace: TrainingWorkspace, plate: NutritionPlateDraft, row: NutritionPlateDraft.Row) {
        self.plate = plate
        self.row = row
        _draft = StateObject(wrappedValue: NutritionEntryDraft(store: workspace.nutrition, food: row.food,
            date: plate.date, meal: plate.meal, editing: row.entry(on: plate.date, meal: plate.meal, at: plate.loggedAt), preferredUnit: plate.unit))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ExScreen {
                    ExEyebrow("Meal portion", color: .exPrimaryText)
                    Text(row.food.name).font(.exH2)
                    ExCard {
                        NutritionMeasureChips(draft: draft, unit: plate.unit)
                        ExQuantityControl(title: draft.measure.amountTitle, text: $draft.amount.text, step: draft.measure.step,
                                          presets: draft.measure.presets, unit: draft.measure.symbol)
                            .accessibilityIdentifier("nutrition.plateAmount")
                        if draft.measure == .milliliters || draft.measure == .fluidOunces, draft.food.volume?.assumed == true {
                            Text("Estimated weight from volume").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }
                    }
                    if let amount = try? draft.preview() {
                        ExCard(accent: true) {
                            ExEyebrow("This portion", color: .exPrimaryText)
                            NutritionDailySummary(amounts: amount.nutrients, targets: nil, showHeading: false)
                        }
                    }
                    if !errors.isEmpty {
                        ExCard {
                            ForEach(errors, id: \.self) { Text($0).foregroundStyle(Color.exError) }
                        }.id("plate-portion-errors").accessibilityElement(children: .combine)
                            .accessibilityFocused($errorsFocused).accessibilityIdentifier("nutrition.platePortionError")
                    }
                }
                .onChange(of: errors) { _, values in
                    guard !values.isEmpty else { return }
                    scroll.scrollTo("plate-portion-errors", anchor: .bottom)
                    errorsFocused = true
                }
            }
            .navigationTitle("Edit portion").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { hideKeyboard(); if draft.hasChanges { discarding = true } else { dismiss() } }
                        .accessibilityIdentifier("nutrition.cancelPlatePortion")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        hideKeyboard()
                        if draft.reviewNutrition() != nil, let amount = try? draft.preview(),
                           plate.stage(row.food, amount: amount, replacing: row) { dismiss() }
                    }.fontWeight(.semibold).accessibilityIdentifier("nutrition.applyPlatePortion")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { hideKeyboard() } }
            }
            .sheet(isPresented: $discarding) {
                NutritionConfirmation(title: "Discard portion changes?", message: "Your meal will keep the previous portion.",
                                      confirm: "Discard changes", cancelLabel: "Keep editing", destructive: true) { dismiss() }
                    cancel: { discarding = false }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges)
    }

    private var errors: [String] {
        let portionErrors: [String]
        if draft.errors.contains("the quantity must be more than 0") {
            // Core reports the invalid quantity and its resulting weight.
            // They refer to the same field, so give one instruction here.
            portionErrors = ["Enter a portion greater than zero."]
        } else { portionErrors = draft.errors }
        return portionErrors + [plate.error].compactMap { $0 }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
