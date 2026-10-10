import ExerlyCore
import SwiftUI

struct NutritionFoodEditor: View {
    let workspace: TrainingWorkspace
    let onSaved: (ExerlyCore.Food) -> Void
    let scan: NutritionLabelScan?
    @StateObject private var draft: NutritionFoodDraft
    @State private var discarding = false
    @AccessibilityFocusState private var errorsFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss

    /// `start` opens a new food filled in from another, such as a duplicate.
    init(workspace: TrainingWorkspace, editing: ExerlyCore.Food? = nil, start: ExerlyCore.Food? = nil, scan: NutritionLabelScan? = nil,
         onSaved: @escaping (ExerlyCore.Food) -> Void) {
        self.workspace = workspace
        self.onSaved = onSaved
        self.scan = scan
        _draft = StateObject(wrappedValue: scan.map { NutritionFoodDraft(store: workspace.nutrition, label: $0.reading) }
            ?? NutritionFoodDraft(store: workspace.nutrition, editing: editing, start: start))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ExScreen {
                    if let scan { NutritionLabelReviewHeader(scan: scan) }
                    ExCard {
                        ExEyebrow("Food label", color: .exPrimaryText)
                        TextField("Food name", text: $draft.name, prompt: Text("Food name").foregroundColor(.exTextSecondary), axis: .vertical).font(.exH2)
                            .accessibilityIdentifier("nutrition.foodName")
                        TextField("Brand", text: $draft.brand, prompt: Text("Brand").foregroundColor(.exTextSecondary), axis: .vertical)
                            .accessibilityLabel("Brand, optional")
                        Toggle("Favorite", isOn: $draft.favorite)
                    }
                    VStack(alignment: .leading, spacing: ExSpacing.item) {
                        ExChoiceChips(values: NutritionFoodDraft.Basis.allCases, selection: $draft.basis) { $0.rawValue }
                            .accessibilityIdentifier("nutrition.labelBasis")
                        if draft.basis == .perServing {
                            NutritionNumberInput(title: scan?.reading.basis == .per100ml ? "Weight of 100 ml (g)" : "Label serving weight (g)", text: $draft.labelGrams.text)
                                .accessibilityIdentifier("nutrition.labelGrams")
                        }
                        Text("Blank means unknown. Use 0 only when the label says zero.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: ExSpacing.item) {
                        ExSectionHeading("Calories & macros")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 320 : 145), alignment: .top)], alignment: .leading, spacing: ExSpacing.content) {
                            ForEach([Nutrient.energy, .protein, .carbohydrate, .fat], id: \.self) { nutrientField($0) }
                        }
                    }
                    ExCard {
                        ExSectionHeading("More nutrients")
                        ForEach(Nutrient.Group.allCases.filter { $0 != .energy && $0 != .macros }, id: \.self) { group in
                            DisclosureGroup(NutritionFormat.group(group)) {
                                ForEach(Nutrient.allCases.filter { $0.group == group }, id: \.self) { nutrientField($0) }
                            }.accessibilityIdentifier("nutrition.group.\(group.rawValue)")
                        }
                    }
                    ExCard {
                        ExSectionHeading("Named servings")
                        ForEach($draft.servings) { $serving in
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Serving name", text: $serving.name, prompt: Text("Serving name").foregroundColor(.exTextSecondary), axis: .vertical)
                                NutritionNumberInput(title: "Serving weight (g)", text: $serving.grams.text)
                                Button("Remove serving", role: .destructive) { draft.servings.removeAll { $0.id == serving.id } }
                            }
                        }
                        Button("Add named serving", systemImage: "plus") { draft.servings.append(NutritionServingFields()) }
                            .accessibilityIdentifier("nutrition.addServing")

                        Text("For example, a cup weighing 80 g. You can always log by grams without a named serving.")
                    }
                    Text("Label edits apply to future entries. Previously logged food stays unchanged.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    if !draft.errors.isEmpty {
                        ExCard {
                            ForEach(draft.errors, id: \.self) { Text($0).foregroundStyle(Color.exError) }
                        }.id("errors").accessibilityFocused($errorsFocused)
                    }
                }
                .onChange(of: draft.errors) { _, errors in
                    guard !errors.isEmpty else { return }
                    scroll.scrollTo("errors", anchor: .bottom)
                    errorsFocused = true
                }
            }
            .scrollContentBackground(.hidden).background(Color.exBackground)
            .navigationTitle("Food label").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { hideKeyboard(); if draft.hasChanges { discarding = true } else { dismiss() } }
                        .accessibilityIdentifier("nutrition.cancelFood")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        hideKeyboard()
                        if let food = draft.save() {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onSaved(food)
                            Task { await workspace.synchronize() }
                            dismiss()
                        }
                    }.fontWeight(.semibold).accessibilityIdentifier("nutrition.saveFood")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { hideKeyboard() } }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges)
        .sheet(isPresented: $discarding) {
            NutritionConfirmation(title: "Discard food changes?", message: "Your unsaved label and serving changes will be discarded.",
                                  confirm: "Discard changes", cancelLabel: "Keep editing", destructive: true) {
                discarding = false
                dismiss()
            } cancel: { discarding = false }
        }
    }

    private func nutrientField(_ nutrient: Nutrient) -> some View {
        NutritionNumberInput(title: "\(nutrient == .energy ? "Calories" : nutrient.name) (\(nutrient.unit.rawValue))", text: Binding(
            get: { draft.nutrients[nutrient]?.text ?? "" },
            set: { draft.nutrients[nutrient]?.text = $0 }
        ))
        .accessibilityIdentifier("nutrition.nutrient.\(nutrient.rawValue)")
    }
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

}
