import ExerlyCore
import SwiftUI

extension EnvironmentValues {
    /// What is typed in food search, so a portion step opened from it can
    /// offer the serving it names ("1 slice toast": 1 slice).
    @Entry var foodSearchQuery = ""
}

/// A chip after a food's measures that names a serving of the person's own
/// food, such as "1 slice = 28 g", when it has none to count it by. The
/// serving is saved with the food and chosen at the count typed, so the
/// next "1 slice toast" logs in one tap. An alert asks, to keep the sheet
/// as short as it is.
struct NutritionAddServing: View {
    @ObservedObject var draft: NutritionEntryDraft
    @Environment(\.foodSearchQuery) private var query
    @State private var adding = false
    @State private var name = ""
    @State private var grams = ""

    /// The serving the search names, and how many of it were typed.
    private var typed: (name: String, count: Double)? {
        let search = FoodSearch.amount(in: query)
        guard let amount = search.amount, let name = amount.servingName(for: search.food) else { return nil }
        return (name, amount.quantity)
    }

    var body: some View {
        Button {
            name = typed?.name ?? ""
            grams = ""
            adding = true
        } label: {
            Label(typed?.name ?? "Serving", systemImage: "plus").font(.exLabel.weight(.medium))
                .padding(.horizontal, 14).frame(minHeight: 34)
                .foregroundStyle(Color.exPrimaryText)
                .background(Color.exSurface2, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a serving\(typed.map { ", \($0.name)" } ?? "")")
        .accessibilityHint("Saves its weight with this food, to log it by count")
        .accessibilityIdentifier("nutrition.addServing")
        .alert("Add a serving", isPresented: $adding) {
            TextField("Name, as in 1 slice", text: $name)
            TextField("Weight in grams", text: $grams).keyboardType(.decimalPad)
            Button("Add") { draft.addServing(named: name, grams: grams, count: typed?.count ?? 1) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its weight from the label or a scale. It stays with \(draft.food.name), so typing the amount with it logs it in one tap.")
        }
    }
}
