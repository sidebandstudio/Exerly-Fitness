import ExerlyCore
import SwiftUI

/// One food's amount, in grams, ounces or any of its servings, for a recipe
/// or a meal being built. It opens when a food arrives without an amount the
/// person has logged before, with the keypad on the amount, and when an
/// ingredient is tapped.
struct FoodPortionStep: View {
    let title: String
    let confirm: String
    let unit: MassUnit
    let asking: Bool
    let identifier: String
    let removeTitle: String?
    let onRemove: () -> Void
    let onCancel: () -> Void
    let onConfirm: (LoggedAmount, FoodSnapshot) -> Void
    private let name: String
    private let origin: String?
    @StateObject private var draft: NutritionEntryDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `food` brings its named servings; `editing` reopens an amount already
    /// chosen, and `start` opens at one, such as a count typed in search.
    init(store: NutritionStore, food: ExerlyCore.Food, editing: FoodEntry? = nil, start: LoggedAmount? = nil, unit: MassUnit,
         title: String, confirm: String,
         asking: Bool = false, identifier: String, removeTitle: String? = nil, onRemove: @escaping () -> Void = {},
         onCancel: @escaping () -> Void = {}, onConfirm: @escaping (LoggedAmount, FoodSnapshot) -> Void) {
        self.title = title
        self.confirm = confirm
        self.unit = unit
        self.asking = asking
        self.identifier = identifier
        self.removeTitle = removeTitle
        self.onRemove = onRemove
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        name = editing?.food.name ?? food.name
        origin = FoodFormat.origin(of: editing?.food ?? food.snapshot)
        let date = editing?.date ?? LocalDate(Date(timeIntervalSince1970: 0), in: .gmt)
        _draft = StateObject(wrappedValue: NutritionEntryDraft(store: store, food: food, date: date, meal: editing?.meal ?? "Recipe",
            editing: editing, repeating: start.map { FoodEntry(starting: $0, of: food, on: date, meal: "Recipe") }, preferredUnit: unit))
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                    if let origin { Text(origin).font(.exCaption).foregroundStyle(Color.exTextSecondary) }
                }
                FoodPortionSummary(amounts: (try? draft.preview())?.nutrients)
                NutritionMeasureChips(draft: draft, unit: unit)
                ExQuantityControl(title: draft.measure.amountTitle, text: $draft.amount.text, step: draft.measure.step,
                                  presets: draft.measure.presets, unit: draft.measure.symbol, identifier: "\(identifier)Amount",
                                  focusOnAppear: asking)
                ForEach(draft.errors, id: \.self) { Text($0).foregroundStyle(Color.exError) }
                if let removeTitle {
                    Button(removeTitle, systemImage: "trash", role: .destructive) { onRemove(); dismiss() }
                        .font(.exLabel).frame(minHeight: 44).accessibilityIdentifier("\(identifier)Remove")
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }.accessibilityIdentifier("\(identifier)Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
                        if draft.reviewNutrition() != nil, let amount = try? draft.preview() {
                            onConfirm(amount, draft.snapshot)
                            dismiss()
                        }
                    }.fontWeight(.semibold).accessibilityIdentifier("\(identifier)Confirm")
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize || asking ? [.large] : [.custom(FoodSheetDetent.self), .large])
        .presentationDragIndicator(.visible)
    }
}
