import ExerlyCore
import SwiftUI

struct TrainingProgramEditor: View {
    let workspace: TrainingWorkspace
    private let isNew: Bool
    @StateObject private var draft: TrainingProgramDraft
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var editMode = EditMode.inactive
    @FocusState private var typing: Bool
    @AccessibilityFocusState private var errorFocused: Bool

    init(workspace: TrainingWorkspace, editing: Program? = nil) {
        self.workspace = workspace
        isNew = editing == nil
        _draft = StateObject(wrappedValue: TrainingProgramDraft(store: workspace.programs, editing: editing))
    }

    private var iconName: String {
        guard let icon = draft.program.icon else { return "Default" }
        return ProgramAppearance.icons.first { $0.symbol == icon }?.name ?? "Saved icon"
    }

    private var colorName: String {
        guard let color = draft.program.color else { return "Default" }
        return ProgramAppearance.colors.first { $0.hex == color }?.name ?? "Saved color \(color)"
    }

    private var iconChoices: [(String, String?)] {
        var choices: [(String, String?)] = [("Default", nil)]
        choices += ProgramAppearance.icons.map { ($0.name, Optional($0.symbol)) }
        if let icon = draft.program.icon, !choices.contains(where: { $0.1 == icon }) {
            choices.append(("Saved icon", icon))
        }
        return choices
    }

    private var colorChoices: [(String, String?)] {
        var choices: [(String, String?)] = [("Default", nil)]
        choices += ProgramAppearance.colors.map { ($0.name, Optional($0.hex)) }
        if let color = draft.program.color, !choices.contains(where: { $0.1 == color }) {
            choices.append(("Saved color \(color)", color))
        }
        return choices
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ExForm {
                    Section {
                        ExCard(accent: true) {
                            ExEyebrow(isNew ? "New program" : "Edit program", color: .exPrimaryText)
                            TextField("Program name", text: $draft.program.name, axis: .vertical).font(.exH2)
                                .focused($typing).accessibilityIdentifier("program.name")
                            Text("Build a cycle of training and rest days. Completed sessions advance your plan.")
                                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                    Section("Schedule") {
                        ExQuantityControl(title: "Cycles", text: $draft.cycles, step: 1, presets: [1, 2, 4, 6],
                                          identifier: "program.cycles", integer: true)
                        ProgramChoiceField("Deload", value: TrainingProgramFormat.deload(draft.program.deload),
                                           selection: $draft.program.deload,
                                           choices: DeloadPlacement.allCases.map { (TrainingProgramFormat.deload($0), $0) })
                            .accessibilityIdentifier("program.deload")
                    }
                    Section {
                        if !draft.errors.isEmpty {
                            VStack(alignment: .leading, spacing: ExSpacing.small) {
                                ForEach(draft.errors, id: \.self) { Text($0).foregroundStyle(Color.exError) }
                            }
                            .id("errors").accessibilityIdentifier("program.errors")
                            .accessibilityFocused($errorFocused)
                        }
                        ForEach($draft.program.days) { $day in
                            NavigationLink {
                                TrainingProgramDayEditor(day: $day, store: workspace.store,
                                                         cycles: TrainingInput.reps(draft.cycles), gym: workspace.gyms.active)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(day.name.isEmpty ? "Unnamed day" : day.name)
                                    Text(day.isRest ? "Rest day" : day.slots.count == 1 ? "1 exercise" : "\(day.slots.count) exercises")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                            }.accessibilityIdentifier("program.day.\(day.id)")
                        }
                        .onMove { draft.program.days.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { draft.program.days.remove(atOffsets: $0) }
                        Button("Add training day", systemImage: "plus") {
                            draft.program.days.append(ProgramDay(name: "Day \(draft.program.days.count + 1)"))
                        }.accessibilityIdentifier("program.addDay")
                        Button("Add rest day", systemImage: "moon") {
                            draft.program.days.append(ProgramDay(name: "Rest"))
                        }.accessibilityIdentifier("program.addRest")
                    } header: {
                        HStack {
                            Text("Days in each cycle")
                            Spacer()
                            EditButton().accessibilityLabel("Reorder or remove days")
                                .textCase(nil).font(.exCaption).frame(minHeight: 44)
                        }
                    } footer: {
                        Text("Days without exercises are rest days. Finished workouts advance the plan.")
                    }
                    Section("Appearance") {
                        ProgramChoiceField("Icon", value: iconName, selection: $draft.program.icon, choices: iconChoices)
                        ProgramChoiceField("Color", value: colorName, selection: $draft.program.color, choices: colorChoices)
                    }
                    Section {
                        Text("Saving changes future workouts. Completed workouts and any workout in progress keep their logged values.")
                            .foregroundStyle(.secondary)
                    }
                }
                .exListStyle()
                .environment(\.editMode, $editMode)
                .onChange(of: draft.errors) { _, errors in
                    if !errors.isEmpty {
                        scroll.scrollTo("errors", anchor: .top)
                        errorFocused = true
                    }
                }
            }
            .navigationTitle("Program").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.exBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft.hasChanges { confirmingDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        typing = false
                        if draft.save() {
                            Task { await workspace.synchronize() }
                            dismiss()
                        }
                    }.fontWeight(.semibold).accessibilityIdentifier("program.save")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges)
        .sheet(isPresented: $confirmingDiscard) {
            TrainingProgramConfirmation(title: "Discard program changes?", message: "Your unsaved changes will be discarded. The saved program will stay as it is.",
                                        confirm: "Discard changes", cancelLabel: "Keep editing", destructive: true) {
                confirmingDiscard = false
                dismiss()
            } cancel: {
                confirmingDiscard = false
            }
        }
    }
}

private struct ProgramChoiceField<Value: Hashable>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    let choices: [(String, Value)]
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingChoices = false

    init(_ title: String, value: String, selection: Binding<Value>, choices: [(String, Value)]) {
        self.title = title
        self.value = value
        _selection = selection
        self.choices = choices
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Button { showingChoices = true } label: { fieldLabel }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(choices.indices, id: \.self) { index in
                        Button { choose(index) } label: {
                            if choices[index].1 == selection {
                                Label(choices[index].0, systemImage: "checkmark")
                            } else { Text(choices[index].0) }
                        }
                    }
                } label: { fieldLabel }
            }
        }
        .accessibilityLabel("\(title), \(value)")
        .sheet(isPresented: $showingChoices) {
            NavigationStack {
                ExScreen {
                    ForEach(choices.indices, id: \.self) { index in
                        Button { choose(index) } label: {
                            ExCard(accent: choices[index].1 == selection) {
                                HStack(alignment: .firstTextBaseline, spacing: ExSpacing.content) {
                                    Text(choices[index].0).font(.exBodyMedium)
                                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                                    Spacer(minLength: ExSpacing.small)
                                    if choices[index].1 == selection {
                                        Image(systemName: "checkmark").accessibilityHidden(true)
                                    }
                                }.foregroundStyle(choices[index].1 == selection ? Color.exPrimaryText : Color.exTextPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(choices[index].0)
                            .accessibilityAddTraits(choices[index].1 == selection ? .isSelected : [])
                    }
                }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingChoices = false } } }
            }
        }
    }

    private var fieldLabel: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.item))
        return layout {
            Text(title).foregroundStyle(Color.exTextPrimary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                Text(value).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }.foregroundStyle(Color.exPrimaryText)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4).contentShape(Rectangle())
    }

    private func choose(_ index: Int) {
        selection = choices[index].1
        showingChoices = false
    }
}

private enum ProgramAppearance {
    static let icons = [(name: "Strength", symbol: "dumbbell"), (name: "Training", symbol: "figure.strengthtraining.traditional"),
                        (name: "Running", symbol: "figure.run"), (name: "Power", symbol: "bolt"), (name: "Fitness", symbol: "heart")]
    static let colors = [(name: "Purple", hex: "#7C3AFF"), (name: "Pink", hex: "#EC4899"),
                         (name: "Blue", hex: "#3478F6"), (name: "Orange", hex: "#B85C00")]
}

private struct TrainingProgramDayEditor: View {
    @Binding var day: ProgramDay
    let store: TrainingStore
    let cycles: Int?
    var gym: GymProfile?
    @State private var adding = false
    @FocusState private var typing: Bool

    var body: some View {
        ExForm {
            Section {
                ExCard(accent: true) {
                    ExEyebrow(day.isRest ? "Rest day" : "Training day", color: .exPrimaryText)
                    TextField("Day name", text: $day.name, axis: .vertical).font(.exH2).focused($typing).accessibilityIdentifier("program.dayName")
                    Text(day.slots.count == 1 ? "1 exercise" : "\(day.slots.count) exercises").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section {
                ForEach($day.slots) { $slot in
                    NavigationLink {
                        TrainingProgramSlotEditor(slot: $slot, exercise: store.library.exercise(slot.exerciseID), cycles: cycles)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.library.exercise(slot.exerciseID)?.name ?? slot.exerciseID.rawValue)
                            Text(TrainingProgramFormat.target(slot.target, exercise: store.library.exercise(slot.exerciseID)))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    }.accessibilityIdentifier("program.slot.\(slot.id)")
                }
                .onMove { day.slots.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { day.slots.remove(atOffsets: $0) }
                Button("Add exercise", systemImage: "plus") { typing = false; adding = true }
                    .accessibilityIdentifier("program.addExercise")
            } header: { Text(day.isRest ? "Rest day" : "Exercises in order") } footer: {
                if day.isRest { Text("This day is a rest day until you add an exercise.") }
            }
        }
        .exListStyle()
        .navigationTitle(day.name.isEmpty ? "Program day" : day.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton().accessibilityLabel("Reorder or remove exercises") }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
        }
        .sheet(isPresented: $adding) {
            ExercisePickerView(store: store, onSelect: { exercise in
                day.slots.append(ProgramSlot(exerciseID: exercise.id, target: SlotTarget(sets: 3, minReps: 6, maxReps: 10, rir: 2)))
            }, gym: gym)
        }
    }
}

private struct TrainingProgramSlotEditor: View {
    @Binding var slot: ProgramSlot
    let exercise: ExerlyCore.Exercise?
    let cycles: Int?
    @State private var selectedCycle = 0
    @FocusState private var typing: Bool

    private var availableCycles: [Int] {
        guard let cycles, (1...Program.maximumCycles).contains(cycles) else { return [] }
        return Array(0..<cycles).filter { slot.cycleTargets[$0] == nil }
    }

    var body: some View {
        ExForm {
            Section {
                ExCard(accent: true) {
                    ExEyebrow("Exercise prescription", color: .exPrimaryText)
                    Text(exercise?.name ?? "Exercise targets").font(.exH2)
                    Text(TrainingProgramFormat.target(slot.target, exercise: exercise)).font(.exBody).foregroundStyle(Color.exTextSecondary)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section("Default targets") {
                NavigationLink {
                    ProgramTargetEditor(target: slot.target, exercise: exercise) { slot.target = $0 }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Edit targets")
                        Text(TrainingProgramFormat.target(slot.target, exercise: exercise))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("program.editTargets")
                if exercise?.metric.tracksReps == true {
                    Toggle("Expand rep range", isOn: $slot.expandRepRange)
                    Text("Allow up to two reps outside your range when equipment increments make the requested load unavailable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField("Exercise notes", text: $slot.notes, axis: .vertical).focused($typing)
                    .accessibilityIdentifier("program.slotNotes")
            }
            Section {
                ForEach(slot.cycleTargets.keys.sorted(), id: \.self) { cycle in
                    if let target = slot.cycleTargets[cycle] {
                        NavigationLink {
                            ProgramTargetEditor(target: target, exercise: exercise, title: "Cycle \(cycle + 1)") {
                                slot.cycleTargets[cycle] = $0
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Cycle \(cycle + 1)")
                                Text(TrainingProgramFormat.target(target, exercise: exercise))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("program.override.\(cycle)")
                        .swipeActions {
                            Button("Remove", role: .destructive) { slot.cycleTargets.removeValue(forKey: cycle) }
                        }
                    }
                }
                if !availableCycles.isEmpty {
                    ProgramChoiceField("Cycle to customize", value: "Cycle \(selectedCycle + 1)",
                                       selection: $selectedCycle, choices: availableCycles.map { ("Cycle \($0 + 1)", $0) })
                    Button("Add cycle targets") {
                        guard let cycle = availableCycles.contains(selectedCycle) ? selectedCycle : availableCycles.first else { return }
                        slot.cycleTargets[cycle] = slot.target
                    }.accessibilityIdentifier("program.addOverride")
                } else if cycles == nil {
                    Text("Enter a valid cycle count in the program to add cycle targets.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Cycle targets") } footer: {
                Text("These targets replace the defaults for that cycle, including its deload adjustment. Remove an override to use the defaults again.")
            }
        }
        .exListStyle()
        .navigationTitle(exercise?.name ?? "Exercise targets").navigationBarTitleDisplayMode(.inline)
        .onChange(of: availableCycles, initial: true) { _, available in
            if !available.contains(selectedCycle), let first = available.first { selectedCycle = first }
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } } }
    }
}

private struct ProgramTargetEditor: View {
    let exercise: ExerlyCore.Exercise?
    let title: String
    let apply: (SlotTarget) -> Void
    @State private var fields: ProgramTargetFields
    @State private var error: String?
    @FocusState private var typing: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss

    init(target: SlotTarget, exercise: ExerlyCore.Exercise?, title: String = "Set targets", apply: @escaping (SlotTarget) -> Void) {
        self.exercise = exercise
        self.title = title
        self.apply = apply
        _fields = State(initialValue: ProgramTargetFields(target))
    }

    var body: some View {
        ExScreen {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ExEyebrow(title, color: .exPrimaryText)
                Text(exercise?.name ?? "Your prescription").font(.exH2)
            }
            ExCard(accent: true) {
                ExQuantityControl(title: "Sets", text: $fields.sets, step: 1, presets: [2, 3, 4, 5],
                                  identifier: "program.targetSets", integer: true)
            }
            if exercise?.metric.tracksReps == true {
                ExCard {
                    ExSectionHeading("Rep range")
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.content))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.content))
                    layout { repBounds }
                    ExQuantityControl(title: "Reps in reserve", text: $fields.rir, step: 1, presets: [0, 1, 2, 3],
                                      identifier: "program.targetRIR")
                }
            } else {
                Text("Enter time, distance and any load while logging. Later workouts can repeat your last entry.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            ExCard {
                ExQuantityControl(title: "Rest in seconds, optional", text: $fields.rest, step: 15, presets: [60, 90, 120], unit: "s",
                                  identifier: "program.rest")
                Button("Use my usual timer") { fields.rest = "" }.font(.exLabel).frame(minHeight: 44)
                ProgramChoiceField("Set type", value: TrainingFormat.kind(fields.kind), selection: $fields.kind,
                                   choices: SetKind.allCases.filter { $0 != .warmUp }.map { (TrainingFormat.kind($0), $0) })
            }
            if let error { Text(error).foregroundStyle(Color.exError) }
        }
        .exFieldOrder(["program.targetSets", "program.minReps", "program.maxReps", "program.targetRIR", "program.rest"])
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    do { apply(try fields.value()); dismiss() } catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("program.applyTargets")
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
        }
    }
    @ViewBuilder
    private var repBounds: some View {
        NutritionNumberInput(title: "Minimum reps", text: $fields.minReps, identifier: "program.minReps", integer: true)
        NutritionNumberInput(title: "Maximum reps", text: $fields.maxReps, identifier: "program.maxReps", integer: true)
    }

}
