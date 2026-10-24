import Combine
import ExerlyCore
import SwiftUI

@MainActor
final class NutritionEntryNutrientsDraft: ObservableObject {
    @Published var fields: [Nutrient: NutritionNumberField]
    @Published var errors: [String] = []
    let original: FoodEntry
    private let initialFields: [Nutrient: NutritionNumberField]

    init(entry: FoodEntry) {
        original = entry
        let values = Dictionary(uniqueKeysWithValues: Nutrient.allCases.map { ($0, NutritionNumberField(entry.nutrients[$0])) })
        fields = values
        initialFields = values
    }

    var hasChanges: Bool { fields != initialFields }

    func correctedEntry(locale: Locale = .current) throws -> FoodEntry {
        guard hasChanges else { return original }
        var amounts = NutrientAmounts()
        for nutrient in Nutrient.allCases {
            amounts[nutrient] = try fields[nutrient]?.value(named: nutrient.name, locale: locale)
        }
        let corrected = original.editingNutrients(amounts)
        _ = try NutritionStore.preview(corrected.food.foodForLogging(), grams: corrected.grams)
        return corrected
    }
}

struct NutritionEntryNutrientsEditor: View {
    let unit: MassUnit
    let onApply: (FoodEntry) throws -> Void
    @StateObject private var draft: NutritionEntryNutrientsDraft
    @State private var discarding = false
    @AccessibilityFocusState private var errorsFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(entry: FoodEntry, unit: MassUnit, onApply: @escaping (FoodEntry) throws -> Void) {
        self.unit = unit
        self.onApply = onApply
        _draft = StateObject(wrappedValue: NutritionEntryNutrientsDraft(entry: entry))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ExScreen {
                    ExCard(accent: true) {
                        ExEyebrow("This entry only", color: .exPrimaryText)
                        Text(draft.original.food.name).font(.exH2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(NutritionFormat.portion(draft.original, unit: unit)).font(.exBody)
                        Text(draft.original.food.unweighed == true
                             ? "Enter nutrients for this whole portion. Other entries stay unchanged."
                             : "Enter nutrients for this whole portion. Your saved food and other entries stay unchanged.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                    VStack(alignment: .leading, spacing: ExSpacing.item) {
                        ExSectionHeading("Calories & macros")
                        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] :
                                    [GridItem(.flexible()), GridItem(.flexible())],
                                  alignment: .leading, spacing: ExSpacing.content) {
                            ForEach([Nutrient.energy, .protein, .carbohydrate, .fat], id: \.self) { field($0) }
                        }
                        Text("Blank means unknown. Enter 0 only for a known zero.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                    ExCard {
                        ExSectionHeading("More nutrients")
                        ForEach(Nutrient.Group.allCases.filter { $0 != .energy && $0 != .macros }, id: \.self) { group in
                            DisclosureGroup(NutritionFormat.group(group)) {
                                ForEach(Nutrient.allCases.filter { $0.group == group }, id: \.self) { field($0) }
                            }.accessibilityIdentifier("nutrition.correction.group.\(group.rawValue)")
                        }
                    }
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
            .exFieldOrder(([Nutrient.energy, .protein, .carbohydrate, .fat]
                + Nutrient.Group.allCases.filter { $0 != .energy && $0 != .macros }.flatMap { group in Nutrient.allCases.filter { $0.group == group } })
                .map { "nutrition.correction.\($0.rawValue)" })
            .navigationTitle("Entry nutrition").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { hideKeyboard(); if draft.hasChanges { discarding = true } else { dismiss() } }
                        .accessibilityIdentifier("nutrition.cancelEntryNutrients")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        hideKeyboard()
                        do {
                            try onApply(draft.correctedEntry())
                            dismiss()
                        } catch { draft.errors = NutritionDraftError.messages(error) }
                    }.fontWeight(.semibold).accessibilityIdentifier("nutrition.applyEntryNutrients")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { hideKeyboard() } }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges)
        .sheet(isPresented: $discarding) {
            NutritionConfirmation(title: "Discard nutrition changes?", message: "The entry will keep its current nutrients.",
                                  confirm: "Discard changes", cancelLabel: "Keep editing", destructive: true) {
                discarding = false
                dismiss()
            } cancel: { discarding = false }
        }
    }

    private func field(_ nutrient: Nutrient) -> some View {
        NutritionNumberInput(title: "\(nutrient == .energy ? "Calories" : nutrient.name) (\(nutrient.unit.rawValue))", text: Binding(
            get: { draft.fields[nutrient]?.text ?? "" },
            set: { draft.fields[nutrient]?.text = $0 }
        ), identifier: "nutrition.correction.\(nutrient.rawValue)")
        .accessibilityIdentifier("nutrition.correction.\(nutrient.rawValue)")
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
