import ExerlyCore
import SwiftUI

struct NutritionDayNotesView: View {
    let workspace: TrainingWorkspace
    let date: LocalDate
    let timeZone: TimeZone
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var draft: NutritionDayNotesDraft
    @State private var discarding = false
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    init(workspace: TrainingWorkspace, date: LocalDate, timeZone: TimeZone) {
        self.workspace = workspace
        self.date = date
        self.timeZone = timeZone
        _draft = StateObject(wrappedValue: NutritionDayNotesDraft(store: workspace.nutrition, date: date))
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard {
                    ExEyebrow(NutritionFormat.day(date, timeZone: timeZone), color: .exPrimaryText)
                    TextField("Food log note", text: $draft.text, axis: .vertical)
                        .lineLimit(5...20).focused($typing).accessibilityIdentifier("nutrition.dayNote")
                }
                if let error = draft.error {
                    Text(error).foregroundStyle(Color.exError).accessibilityIdentifier("nutrition.noteError")
                }
            }
            .scrollContentBackground(.hidden).background(Color.exBackground)
            .navigationTitle("Day note").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { typing = false; if draft.hasChanges { discarding = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        typing = false
                        if draft.save() { Task { await workspace.synchronize() }; dismiss() }
                    }.accessibilityIdentifier("nutrition.saveNote")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.hasChanges)
        .sheet(isPresented: $discarding) {
            NutritionConfirmation(title: "Discard this note?", message: "Your unsaved note changes will be discarded.",
                                  confirm: "Discard changes", cancelLabel: "Keep editing", destructive: true) {
                discarding = false
                dismiss()
            } cancel: { discarding = false }
        }
    }
}

struct NutritionCopyView: View {
    let workspace: TrainingWorkspace
    let timeZone: TimeZone
    @StateObject private var draft: NutritionCopyDraft
    @Environment(\.dismiss) private var dismiss

    init(workspace: TrainingWorkspace, source: LocalDate, meal: String?, timeZone: TimeZone) {
        self.workspace = workspace
        self.timeZone = timeZone
        _draft = StateObject(wrappedValue: NutritionCopyDraft(store: workspace.nutrition, source: source,
                                                             meal: meal, target: source.adding(days: 1)))
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard {
                    ExEyebrow("Copy from", color: .exPrimaryText)
                    Text("\(draft.sourceMeal ?? "All meals") · \(NutritionFormat.day(draft.source, timeZone: timeZone))").font(.exH3)
                    ForEach(draft.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.food.name).font(.headline)
                            Text("\(TrainingFormat.number(entry.grams)) g · \(entry.meal)").foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
                ExCard {
                    ExSectionHeading("Destination")
                    DatePicker("Copy to date", selection: Binding(
                        get: { NutritionFormat.pickerDate(draft.target, timeZone: timeZone) },
                        set: { draft.target = LocalDate($0, in: timeZone) }), displayedComponents: .date)
                    NutritionChoice(title: "Meal", value: draft.targetMeal ?? "Keep original meals") {
                        Picker("Meal", selection: $draft.targetMeal) {
                            Text("Keep original meals").tag(String?.none)
                            ForEach(meals, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }.accessibilityIdentifier("nutrition.copyMeal")
                    Text("Add \(draft.entries.count) new food \(draft.entries.count == 1 ? "entry" : "entries"). Existing entries stay unchanged. The copies keep the original food nutrition.")
                        .foregroundStyle(.secondary)
                }
                if let error = draft.error {
                    Text(error).foregroundStyle(Color.exError).accessibilityIdentifier("nutrition.copyError")
                }
                Group {
                    Button("Copy \(draft.entries.count) \(draft.entries.count == 1 ? "entry" : "entries")") {
                        if draft.copy() != nil { Task { await workspace.synchronize() }; dismiss() }
                    }.buttonStyle(ExActionStyle()).disabled(draft.entries.isEmpty || draft.completed)
                    .accessibilityIdentifier("nutrition.copyConfirm")
                }
            }
            .scrollContentBackground(.hidden).background(Color.exBackground)
            .navigationTitle("Copy food log").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .environment(\.timeZone, timeZone)
    }

    private var meals: [String] {
        let defaults = NutritionStore.defaultMeals
        guard let source = draft.sourceMeal, !defaults.contains(source) else { return defaults }
        return defaults + [source]
    }
}
