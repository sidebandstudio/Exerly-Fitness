import SwiftUI

struct LogActivityView: View {
    let editing: ActivityDTO?
    let onDeleted: (String) -> Void
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sync: SyncEngine
    @State private var name: String
    @State private var duration: String
    @State private var calories: String
    @State private var intensity: String
    @State private var selectedDate: CalendarDay
    @State private var isSaving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(initialDate: CalendarDay, editing: ActivityDTO? = nil, onDeleted: @escaping (String) -> Void = { _ in }, onSaved: @escaping () -> Void = {}) {
        self.editing = editing; self.onDeleted = onDeleted; self.onSaved = onSaved
        _name = State(initialValue: editing?.type ?? "")
        _duration = State(initialValue: editing.map { $0.duration.formatted(.number.grouping(.never)) } ?? "")
        _calories = State(initialValue: editing?.calories.map { $0.formatted(.number.grouping(.never)) } ?? "")
        _intensity = State(initialValue: editing?.intensity ?? "")
        _selectedDate = State(initialValue: editing?.date.flatMap { CalendarDay(rawValue: $0) } ?? initialDate)
    }
    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    ExEyebrow("Movement", color: .exPrimaryText)
                    TextField("Activity name", text: $name, prompt: Text("Activity name").foregroundColor(.exTextSecondary)).font(.exH2).accessibilityIdentifier("activity.name")
                    ExQuantityControl(title: "Minutes", text: $duration, step: 5, presets: [15, 30, 60], unit: "min", identifier: "activity.minutes")
                }
                ExCard {
                    ExSectionHeading("Effort")
                    ExChoiceChips(values: intensityChoices, selection: $intensity) { $0.isEmpty ? "Not recorded" : $0.capitalized }
                    NutritionNumberInput(title: "Calories, optional", text: $calories, identifier: "activity.calories")
                    Text("Leave calories blank if you did not record them.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                ExCard {
                    CalendarDayPicker("Activity date", selection: $selectedDate, today: sync.today, timeZoneIdentifier: sync.calendar.timeZoneIdentifier)
                }
                if editing?.syncState == "pending" { Text("Saved on this device. Waiting to sync.").font(.exCaption) }
                if editing?.syncState == "attention" { NavigationLink("Review activity changes") { SavedChangesReviewView() } }
                if editing != nil {
                    Button("Delete activity", role: .destructive) { confirmingDelete = true }.frame(minHeight: 44)
                }
                if let error { Text(error).foregroundStyle(Color.exError) }
            }
            .exFieldOrder(["activity.minutes", "activity.calories"])
            .navigationTitle(editing == nil ? "Log activity" : "Edit activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save activity") { save() }.disabled(isSaving) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .alert("Delete this activity?", isPresented: $confirmingDelete) {
                Button("Delete activity", role: .destructive) {
                    guard let editing else { return }
                    do { onDeleted(try sync.deleteActivity(editing)); onSaved(); dismiss() } catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("You can undo this after closing the form.") }
        }
    }
    private var intensityChoices: [String] {
        let choices = ["", "light", "moderate", "intense"]
        return choices.contains(intensity) ? choices : choices + [intensity]
    }

    private func save() {
        guard !isSaving else { return }
        guard let minutes = UserEnteredNumber.parse(duration) else {
            error = "Enter the activity duration in minutes."; return
        }
        let energy = calories.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = UserEnteredNumber.parse(energy)
        guard energy.isEmpty || number != nil else { error = "Enter calories as a number, or leave the field blank."; return }
        isSaving = true; error = nil
        let request = ActivityRequest(type: name, duration: minutes, calories: number, intensity: intensity.isEmpty ? nil : intensity,
            entryDate: selectedDate.rawValue, category: editing?.category)
        do { try sync.saveActivity(request, editing: editing); onSaved(); dismiss() } catch { self.error = error.localizedDescription; isSaving = false }
    }
}
