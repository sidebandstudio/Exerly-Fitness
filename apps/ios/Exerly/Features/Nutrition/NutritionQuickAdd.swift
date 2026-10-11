import Combine
import ExerlyCore
import SwiftUI

@MainActor
final class NutritionQuickAddDraft: ObservableObject {
    static let nutrients: [Nutrient] = [.energy, .protein, .carbohydrate, .fat]
    @Published var fields = Dictionary(uniqueKeysWithValues: NutritionQuickAddDraft.nutrients.map { ($0, NutritionNumberField()) })
    @Published var name = ""
    @Published var meal: String
    @Published private(set) var errors: [String] = []
    @Published private(set) var loggedEntry: FoodEntry?
    let date: LocalDate
    private let store: NutritionStore
    private let initialMeal: String

    init(store: NutritionStore, date: LocalDate, meal: String) {
        self.store = store
        self.date = date
        self.meal = meal
        initialMeal = meal
    }

    var hasChanges: Bool {
        !name.isEmpty || meal != initialMeal || fields.values.contains { !$0.text.isEmpty }
    }

    @discardableResult
    func save(ownerIsActive: Bool, locale: Locale = .current) -> FoodEntry? {
        guard loggedEntry == nil else { return nil }
        guard ownerIsActive else {
            errors = ["Sign in again before logging this entry. Your draft is still here."]
            return nil
        }
        do {
            var amounts = NutrientAmounts()
            for nutrient in Self.nutrients {
                amounts[nutrient] = try fields[nutrient]?.value(named: nutrient == .energy ? "Calories" : nutrient.name, locale: locale)
            }
            let entry = try store.quickAdd(amounts, name: name, on: date, meal: meal)
            loggedEntry = entry
            errors = []
            return entry
        } catch { errors = NutritionDraftError.messages(error).map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        return nil
    }
}

struct NutritionQuickAddView: View {
    let workspace: TrainingWorkspace
    let timeZone: TimeZone
    let onLogged: () -> Void
    let onLoggedEntry: ((FoodEntry) -> Void)?
    @StateObject private var draft: NutritionQuickAddDraft
    @State private var discarding = false
    @State private var openedSession: UUID?
    @FocusState private var naming: Bool
    @AccessibilityFocusState private var errorFocused: Bool
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, date: LocalDate, meal: String, timeZone: TimeZone, onLogged: @escaping () -> Void,
         onLoggedEntry: ((FoodEntry) -> Void)? = nil) {
        self.workspace = workspace
        self.timeZone = timeZone
        self.onLogged = onLogged
        self.onLoggedEntry = onLoggedEntry
        _draft = StateObject(wrappedValue: NutritionQuickAddDraft(store: workspace.nutrition, date: date, meal: meal))
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    if draft.date != LocalDate(.now, in: timeZone) {
                        Label("Logging to \(NutritionFormat.day(draft.date, timeZone: timeZone))", systemImage: "calendar")
                            .font(.exCaption.weight(.medium)).foregroundStyle(Color.exPrimaryText)
                    }
                    ExChoiceChips(values: meals, selection: $draft.meal) { $0 }
                }
                ExCard(accent: true) {
                    HStack(alignment: .lastTextBaseline, spacing: ExSpacing.small) {
                        ExNumericTextField(title: "Calories (kcal)", text: field(.energy), placeholder: "–", centered: true,
                                           identifier: "nutrition.quick.energy")
                            .frame(minHeight: 56)
                            .background(FirstResponderOnAppear(identifier: "nutrition.quick.energy"))
                        Text("kcal").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary).accessibilityHidden(true)
                    }
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.item))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.small))
                    layout {
                        NutritionNumberInput(title: "Protein (g)", text: field(.protein), identifier: "nutrition.quick.protein", placeholder: "–")
                        NutritionNumberInput(title: "Carbs (g)", text: field(.carbohydrate), identifier: "nutrition.quick.carbohydrate", placeholder: "–")
                        NutritionNumberInput(title: "Fat (g)", text: field(.fat), identifier: "nutrition.quick.fat", placeholder: "–")
                    }
                    Text("Calories, macros, or both. Leave a value blank if you don't know it; 0 means none.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                TextField("Name (optional)", text: $draft.name, prompt: Text("Name, e.g. Restaurant lunch").foregroundColor(.exTextSecondary))
                    .font(.exBody).focused($naming).submitLabel(.done).onSubmit { naming = false }
                    .padding(ExSpacing.content).background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
                    .accessibilityLabel("Entry name, optional").accessibilityIdentifier("nutrition.quick.name")
            }
            .scrollDismissesKeyboard(.interactively)
            .exFooter {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    if !draft.errors.isEmpty {
                        Text(draft.errors.joined(separator: ". ")).font(.exCaption).foregroundStyle(Color.exError)
                            .accessibilityIdentifier("nutrition.quick.error").accessibilityFocused($errorFocused)
                    }
                    Button("Log to \(draft.meal)") {
                        hideKeyboard()
                        let ownerIsActive = auth.currentUser?.id == workspace.accountID && auth.sessionID == openedSession
                        if let entry = draft.save(ownerIsActive: ownerIsActive) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onLogged()
                            onLoggedEntry?(entry)
                            Task { await workspace.synchronize() }
                            dismiss()
                        } else { errorFocused = true }
                    }.buttonStyle(ExActionStyle()).disabled(draft.loggedEntry != nil)
                        .accessibilityIdentifier("nutrition.quick.save")
                }.padding(ExSpacing.page).background(Color.exBackground)
            }
            .navigationTitle("Quick add").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        hideKeyboard()
                        if draft.hasChanges { discarding = true } else { dismiss() }
                    }.accessibilityIdentifier("nutrition.quick.cancel")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide keyboard") { hideKeyboard() } }
            }
        }
        .onAppear { if openedSession == nil { openedSession = auth.sessionID } }
        .interactiveDismissDisabled(draft.hasChanges)
        .sheet(isPresented: $discarding) {
            NutritionConfirmation(title: "Discard this entry?", message: "These totals have not been logged.",
                                  confirm: "Discard entry", cancelLabel: "Keep editing", destructive: true) {
                discarding = false
                dismiss()
            } cancel: { discarding = false }
        }
    }

    private func field(_ nutrient: Nutrient) -> Binding<String> {
        Binding(get: { draft.fields[nutrient]?.text ?? "" }, set: { draft.fields[nutrient]?.text = $0 })
    }

    private var meals: [String] {
        NutritionStore.defaultMeals.contains(draft.meal) ? NutritionStore.defaultMeals : NutritionStore.defaultMeals + [draft.meal]
    }

    private func hideKeyboard() {
        naming = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
